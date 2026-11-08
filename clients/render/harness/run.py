"""One pass of the fidelity harness over a corpus: the oracle (TeXpresso's MuPDF render, cached), ours (the backend's
display list drawn by taudot-raster, fresh), the floor (one PDF drawn by MuPDF and by Core Graphics, cached), and a
score per page, per paper and per feature group.

    harness/run [smoke|full|PAPER...] [--compare RUN] [--name NAME] [--jobs N] [--ours backend|cg-pdf]

Writes harness/results/<run>/report.md and summary.json (ignored by git; with --keep, results/kept/<run>/, tracked:
milestones and baselines); images, heatmaps and lists go to
~/code/lab/taudot-ref/corpus-results/runs/<run>/ (outside the repo).

Ours: `backend` (the default): clients/render/swift's taudot-raster draws each page's display list. `cg-pdf`: a
stand-in that draws Tectonic's PDF with Core Graphics (ours ≈ floor; it checks the harness, and with a fixed "ours"
a --compare between two oracles shows what changed in TeXpresso)."""

import argparse
import datetime as dt
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
import traceback
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import corpus  # noqa: E402
import measure  # noqa: E402
import raster  # noqa: E402

RENDER = HERE.parent
REPO = RENDER.parent.parent
RESULTS = raster.RESULTS
SCALE = 2.0
SWIFT = RENDER / "swift"
NULLFONT_MIN = 10   # distinct characters missing from nullfont that mark an oracle invalid
MATCH_OK = 50   # bad px: an oracle page and a Tectonic page this close show the same content, so the floor applies


# ---- keys ------------------------------------------------------------------------------------------------------------

def texpresso_dir() -> Path:
    v = REPO / "vendor/texpresso"
    return Path(os.environ.get("TEXPRESSO_DIR", v if v.is_dir() else Path.home() / "code/lab/taudot-ref/texpresso"))


def hash_files(paths, h=None):
    h = h or hashlib.sha256()
    for p in sorted(paths):
        p = Path(p)
        if p.is_file():
            h.update(str(p.name).encode())
            h.update(p.read_bytes())
    return h


def mupdf_lib() -> list[Path]:
    try:
        pre = subprocess.run(["brew", "--prefix", "mupdf"], capture_output=True, text=True).stdout.strip()
        return [Path(pre) / "lib" / f for f in os.listdir(Path(pre) / "lib") if f.startswith("libmupdf")]
    except Exception:
        return []


def texpresso_key() -> str:
    """The TeXpresso build in TEXPRESSO_DIR: its HEAD (upstream pin + our patch series) and built files."""
    tx = texpresso_dir()
    files = [tx / "build/texpresso-xetex", tx / "build/frontend/libmydvi.a", tx / "build/common/libcommon.a",
             *(tx / "build/frontend").glob("*.o")]
    h = hash_files(files)
    h.update(texpresso_head().encode())
    return h.hexdigest()[:16]


def oracle_key() -> str:
    """What draws the oracle: txp-oracle's recipe (harness/oracle/: txp-render at a pinned revision, the last that drew
    with MuPDF), the TeXpresso build and MuPDF. Nothing in today's clients/render: the oracle stays on MuPDF."""
    h = hash_files([*(HERE / "oracle").glob("*"), *mupdf_lib()])
    h.update(texpresso_key().encode())
    return h.hexdigest()[:16]


def texpresso_head() -> str:
    return subprocess.run(["git", "-C", str(texpresso_dir()), "rev-parse", "HEAD"], capture_output=True,
                          text=True).stdout.strip()


def source_key(pid: str) -> str:
    """The paper's files and its source fixes."""
    d = corpus.folder(pid)
    h = hash_files([p for p in d.rglob("*") if p.is_file()])
    h.update(json.dumps(corpus.load().get(pid, {}).get("fix", [])).encode())
    return h.hexdigest()[:16]


def floor_key(pid: str) -> str:
    """What makes the floor: the PDF's build (the code of this process's corpus module, not the file, so an edit
    mid-run can't mix keys), the two rasterisers, and the sources."""
    import inspect
    h = hash_files([HERE / "cgraster.swift", HERE / "raster.py"])
    for f in (corpus.check_tectonic, corpus.use_shipped_bbl, corpus.copy_sources):
        h.update(inspect.getsource(f).encode())
    h.update(json.dumps(corpus.TECTONIC).encode())
    h.update(subprocess.run(["mutool", "-v"], capture_output=True, text=True).stderr.encode())
    h.update(source_key(pid).encode())
    return h.hexdigest()[:16]


# ---- builds ----------------------------------------------------------------------------------------------------------

def txp_sources() -> list[Path]:
    """txp-render's sources: clients/render's C files and headers (driver, dvi/ in Phase B), not the harness'."""
    skip = {"harness", "swift", "cursor", "texpresso"}
    return [p for p in RENDER.rglob("*") if p.suffix in (".c", ".h") and not skip & set(p.relative_to(RENDER).parts)] + \
        [*(RENDER / "swift/Sources").rglob("*.swift"), RENDER / "build.sh"]


def build_txp() -> None:
    """txp-render, rebuilt when its sources change or the TeXpresso it links changes (path or build)."""
    b = RENDER / "txp-render"
    stamp = RENDER / ".txp-render.texpresso"
    t = f"{texpresso_dir()} {texpresso_key()}"
    if (not b.exists() or any(s.stat().st_mtime > b.stat().st_mtime for s in txp_sources())
            or not stamp.exists() or stamp.read_text() != t):
        subprocess.run([str(RENDER / "build.sh")], check=True, capture_output=True,
                       env={**os.environ, "TEXPRESSO_DIR": str(texpresso_dir())})
        stamp.write_text(t)


def oracle_bin() -> Path:
    """txp-oracle for this oracle key, built once into the results folder (outside the tree)."""
    b = RESULTS / "bin" / f"txp-oracle-{oracle_key()}"
    if not b.exists():
        b.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["sh", str(HERE / "oracle/build.sh"), str(b)], check=True, capture_output=True,
                       env={**os.environ, "TEXPRESSO_DIR": str(texpresso_dir())})
    return b


def raster_bin() -> Path | None:
    env = os.environ.get("TAUDOT_RASTER")
    if env:
        return Path(env)
    if not (SWIFT / "Package.swift").exists():
        return None
    r = subprocess.run(["swift", "build", "-c", "release", "--package-path", str(SWIFT), "--product", "taudot-raster"],
                       capture_output=True, text=True)
    b = SWIFT / ".build/release/taudot-raster"
    if r.returncode != 0 or not b.exists():
        print("taudot-raster doesn't build:\n" + r.stderr[-2000:], file=sys.stderr)
        return None
    return b


# ---- per paper -------------------------------------------------------------------------------------------------------

def floor_for(pid: str, main: str) -> dict:
    """{ok, pages, floor: [bad per Tectonic page], dir} (cached by source, cgraster and mutool)."""
    d = RESULTS / "floor" / pid / floor_key(pid)
    meta = d / "floor.json"
    if meta.exists():
        return {**json.loads(meta.read_text()), "dir": str(d)}
    ok, pdf = corpus.check_tectonic(pid, main, RESULTS / "floor-build")
    res = {"ok": ok, "pages": 0, "floor": []}
    if ok:
        raster.mupdf(pdf, d / "mu", SCALE)
        raster.coregraphics(pdf, d / "cg", SCALE)
        shutil.copy(pdf, d / "tectonic.pdf")
        n = raster.pdf_pages(pdf)
        res["pages"] = n
        res["floor"] = [measure.compare(d / f"mu/p{j}.png", d / f"cg/p{j}.png")["bad"] for j in range(n)]
    d.mkdir(parents=True, exist_ok=True)
    meta.write_text(json.dumps(res))
    return {**res, "dir": str(d)}


def match_page(oracle_png: Path, fl: dict, i: int, n: int) -> tuple[int | None, int | None]:
    """The Tectonic page showing what oracle page i of n shows, and its bad px. The two often differ in page count
    (TeXpresso's typesetting isn't Tectonic's), so look around the proportional position."""
    if not fl["ok"] or not fl["pages"]:
        return None, None
    c = round(i * (fl["pages"] - 1) / max(1, n - 1))
    best = (None, None)
    for j in sorted(range(max(0, c - 2), min(fl["pages"], c + 3)), key=lambda j: abs(j - c)):
        b = measure.compare(oracle_png, Path(fl["dir"]) / f"mu/p{j}.png")["bad"]
        if best[1] is None or b < best[1]:
            best = (j, b)
        if b <= MATCH_OK:
            break
    return best


def bench(rbin: str, out: Path, pages: list[dict]) -> None:
    """Like-for-like speed: `taudot-raster --bench` draws all the paper's lists in one process, in page order, then
    again, as an app would. first_us: a page's first draw (process warm, page cold); again_us: drawn again (warm, as
    MuPDF's second render). Per page: ours_first_us = dlist + read + first, ours_us = again. Skipped if unsupported."""
    lists = [(i, out / f"p{i}.dlist") for i, pg in enumerate(pages) if (pg.get("dlist") or {}).get("ok")]
    if not lists:
        return
    r = subprocess.run([rbin, "--bench", "--scale", str(SCALE), *[str(p) for _, p in lists]], capture_output=True,
                       text=True, timeout=600)
    try:
        b = json.loads(r.stdout.strip().splitlines()[-1])
        first, again = b["first_us"], b["again_us"]
    except (ValueError, IndexError, KeyError):
        return
    for (i, _), f, g in zip(lists, first, again):
        pg = pages[i]
        pg["bench"] = {"first_us": f, "again_us": g}
        pg["ours_us"] = g
        pg["ours_first_us"] = (pg["dlist"].get("us") or 0) + ((pg.get("raster") or {}).get("read_us") or 0) + f


def paper(pid: str, p: dict, run_dir: Path, ours_mode: str, rbin: str | None) -> dict:
    from txp import Txp, TxpError
    t0 = time.monotonic()
    out = run_dir / pid
    out.mkdir(parents=True, exist_ok=True)
    res = {"paper": pid, "tags": p.get("tags", []), "pages": []}
    fl = floor_for(pid, p["main"])
    res["tectonic"] = fl["ok"]
    od = RESULTS / "oracle" / pid / f"{oracle_key()}-{source_key(pid)}"
    ometa = od / "meta.json"
    need_oracle = not ometa.exists()
    def session(binary: Path, log: Path, work) -> int:
        """One txp process on a fresh copy of the sources: typeset, then work(x, ev, typeset_s). TeXpresso may start
        another .aux pass after typeset() returned (pages roll back: "no page N"; or a new report arrives during the
        work): wait again and redo, up to 3 times. Returns the attempts."""
        b = corpus.copy_sources(pid, out / "src")
        try:
            with Txp(b / p["main"], log, binary=binary) as x:
                ts = time.monotonic()
                ev = x.typeset(timeout=900)
                typeset_s = time.monotonic() - ts
                for attempt in range(4):
                    gen = x.pages["gen"]
                    try:
                        work(x, ev, typeset_s)
                    except TxpError as e:
                        if "no page" not in str(e) or attempt == 3:
                            raise
                        ev = x.typeset(timeout=900)
                        continue
                    if x.pages["gen"] == gen:
                        return attempt + 1
                    if attempt == 3:
                        raise TxpError("the document kept changing while it was rendered")
                    ev = x.typeset(timeout=900)
        finally:
            shutil.rmtree(b, ignore_errors=True)

    timing = {}

    def oracle_work(x, ev, typeset_s):
        n = ev["n"]
        timing.clear()
        scratch = out / "_timing.png"
        for i in range(n):
            if need_oracle:
                x.render(i, SCALE, od / f"p{i}.png")
            if ours_mode == "backend":
                # MuPDF's speed, from the page's cached display list: first render (cold) and again (warm)
                mu0 = x.render(i, SCALE, scratch)
                mu = x.render(i, SCALE, scratch)
                timing[i] = {"mupdf_first_us": mu0.get("cpu_us"), "mupdf_us": mu.get("cpu_us")}
        scratch.unlink(missing_ok=True)
        if need_oracle:
            nf = x.nullfont()
            ometa.write_text(json.dumps({"n": n, "sizes": ev["sizes"], "typeset_s": round(typeset_s, 2),
                                         "errors": x.errors[:20], "nullfont": nf, "texpresso": texpresso_head(),
                                         # a font fontspec can't find loses every character; a few stray
                                         # ones (TikZ code leaking text inside a picture) don't count
                                         "invalid": (f"nullfont: {len(nf)}+ characters, e.g. " + "; ".join(nf[:3]))
                                         if len(nf) >= NULLFONT_MIN else None}))

    def ours_work(x, ev, typeset_s):
        res["pages"] = []
        for i in range(ev["n"]):
            lst = out / f"p{i}.dlist"
            a = x.dlist(i, lst)
            pg = {"dlist": {k: a.get(k) for k in ("ok", "bytes", "ops", "fonts", "us", "error")}, **timing.get(i, {})}
            if a.get("ok"):
                r = subprocess.run([rbin, str(lst), "--scale", str(SCALE), "--out", str(out / f"p{i}.ours.png"),
                                    "--stats"], capture_output=True, text=True, timeout=120)
                if r.returncode != 0:
                    pg["raster_error"] = r.stderr[-300:]
                else:
                    try:
                        st = json.loads(r.stdout.strip().splitlines()[-1])
                        pg["raster"] = {k: st.get(k) for k in ("read_us", "draw_us", "magenta", "unsupported")}
                        if any("shade" in k for k in (st.get("unsupported") or {})):
                            pg["note"] = "ours: shade missing"   # backend has no SHADE op yet
                        pg["ours_us"] = a.get("us", 0) + st.get("read_us", 0) + st.get("draw_us", 0)
                    except (ValueError, IndexError):
                        pass
            res["pages"].append(pg)
        bench(rbin, out, res["pages"])

    if need_oracle or ours_mode == "backend":
        od.mkdir(parents=True, exist_ok=True)
        try:
            res["attempts"] = session(oracle_bin(), out / "oracle.log", oracle_work)
        except Exception as e:
            res["txp_error"] = f"txp-oracle: {type(e).__name__}: {e}"[:300]
            if need_oracle:
                shutil.rmtree(od, ignore_errors=True)
            res["seconds"] = round(time.monotonic() - t0, 1)
            return res
    if ours_mode == "backend":
        try:
            res["attempts"] = max(res.get("attempts", 1), session(RENDER / "txp-render", out / "txp.log", ours_work))
        except Exception as e:
            res["txp_error"] = f"txp-render: {type(e).__name__}: {e}"[:300]
            res["pages"] = []
    if not ometa.exists():
        res["seconds"] = round(time.monotonic() - t0, 1)
        return res
    meta = json.loads(ometa.read_text())
    res["n"] = meta["n"]
    if meta.get("invalid"):   # the oracle itself is wrong (e.g. text in nullfont): excluded from scores, listed
        res["oracle_invalid"] = meta["invalid"]
        res["pages"] = []
        res["seconds"] = round(time.monotonic() - t0, 1)
        return res
    res["typeset_s"] = meta["typeset_s"]
    res["oracle_dir"] = str(od)
    res["floor_dir"] = fl.get("dir")
    while len(res["pages"]) < meta["n"]:
        res["pages"].append({})
    for i in range(meta["n"]):
        pg = res["pages"][i]
        pg["page"] = i
        o = od / f"p{i}.png"
        j, ob = match_page(o, fl, i, meta["n"])
        pg["pdf_page"], pg["oracle_vs_pdf"] = j, ob
        pg["floor"] = fl["floor"][j] if j is not None and ob is not None and ob <= MATCH_OK else None
        wrong = next((w for w in p.get("oracle_wrong", []) if w["page"] == i), None)
        if wrong:
            # MuPDF provably draws this page wrong (corpus.toml, with evidence): judged against Core Graphics' drawing
            # of Tectonic's PDF instead, with a zero floor (both sides are Core Graphics)
            jj = wrong.get("pdf_page", j)
            ref = Path(fl["dir"]) / f"cg/p{jj}.png" if fl["ok"] and jj is not None else None
            if ref and ref.exists():
                pg.update(oracle_wrong=wrong["why"], judge=wrong.get("judge", "cg-pdf"), pdf_page=jj, floor=0)
                o = ref
        if ours_mode == "cg-pdf":
            ours = Path(fl["dir"]) / f"cg/p{j}.png" if j is not None else None
        else:
            ours = out / f"p{i}.ours.png"
        if not ours or not ours.exists():
            pg["missing"] = True
            continue
        masks = None
        lst = out / f"p{i}.dlist"
        if lst.exists() and lst.stat().st_size > 8:
            import tdl
            try:
                im = measure.load(o)
                masks = tdl.masks(lst, SCALE, im.shape[:2])
            except Exception as e:
                pg["dlist_read_error"] = str(e)[:200]
        r = measure.compare(o, ours, masks=masks, heatmap=out / f"p{i}.heat.png")
        pg.update(r)
        pg["ours"] = str(ours)
        pg["within"] = measure.within_floor(r["bad"], pg["floor"])
    res["seconds"] = round(time.monotonic() - t0, 1)
    return res


def paper_safe(*a) -> dict:
    try:
        return paper(*a)
    except Exception:
        return {"paper": a[0], "error": traceback.format_exc()[-1500:], "pages": []}


# ---- report ----------------------------------------------------------------------------------------------------------

def summarise(results: list[dict], meta: dict) -> dict:
    pages = [dict(pg, paper=r["paper"]) for r in results for pg in r["pages"] if "bad" in pg]
    def agg(ps):
        fl = [p for p in ps if p.get("floor") is not None]
        return {"pages": len(ps), "with_floor": len(fl), "within": sum(1 for p in fl if p["within"]),
                "bad": sum(p["bad"] for p in ps), "floor": sum(p["floor"] for p in fl),
                "ssim": round(sum(p["ssim"] for p in ps) / len(ps), 5) if ps else None}
    tags = sorted({t for r in results for t in r.get("tags", [])})
    groups = {}
    for p in pages:
        for g, v in p.get("groups", {}).items():
            groups.setdefault(g, {"pages": 0, "bad": 0})
            groups[g]["pages"] += 1
            groups[g]["bad"] += v
    def dist(v):
        v = sorted(x for x in v if x is not None)
        return {"median": v[len(v) // 2], "p95": v[min(len(v) - 1, int(len(v) * 0.95))], "n": len(v)} if v else None
    speed = {"mupdf_us": dist(p.get("mupdf_us") for p in pages), "ours_us": dist(p.get("ours_us") for p in pages),
             "mupdf_first_us": dist(p.get("mupdf_first_us") for p in pages),
             "ours_first_us": dist(p.get("ours_first_us") for p in pages),
             "bench": any(p.get("bench") for p in pages),
             "dlist_us": dist((p.get("dlist") or {}).get("us") for p in pages),
             "draw_us": dist((p.get("raster") or {}).get("draw_us") for p in pages),
             "read_us": dist((p.get("raster") or {}).get("read_us") for p in pages),
             "dlist_bytes": dist((p.get("dlist") or {}).get("bytes") for p in pages)}
    return {**meta, "total": agg(pages), "speed": speed, "floor_dirs": {r["paper"]: r.get("floor_dir") for r in results},
            "by_tag": {t: agg([p for r in results if t in r.get("tags", []) for p in r["pages"] if "bad" in p])
                       for t in tags},
            "by_group": groups,
            "papers": [{k: v for k, v in r.items() if k != "pages"} | {"score": agg([p for p in r["pages"] if "bad" in p])}
                       for r in results],
            "pages": [{k: p.get(k) for k in ("paper", "page", "bad", "fine", "coarse", "ssim", "floor", "within",
                                             "pdf_page", "oracle_vs_pdf", "groups", "dlist", "raster", "mupdf_us", "ours_us",
                                             "mupdf_first_us", "ours_first_us", "bench", "oracle_wrong", "judge", "note")}
                      for p in pages]}


def pct(a, b):
    return f"{100 * a / b:.0f} %" if b else "–"


def speed_lines(s: dict) -> list[str]:
    sp = s.get("speed") or {}
    if not sp.get("ours_us") or not sp.get("mupdf_us"):
        return []
    f = lambda d: f"{d['median'] / 1000:.1f} / {d['p95'] / 1000:.1f} ms" if d else "–"  # noqa: E731
    if sp.get("bench"):
        return [f"**Speed per page at {SCALE:g}×**, median / p95, from the cached display list. Warm (drawn again): "
                f"MuPDF {f(sp['mupdf_us'])}, ours {f(sp['ours_us'])}. First draw of a page: MuPDF {f(sp['mupdf_first_us'])}, "
                f"ours {f(sp['ours_first_us'])} (= dlist {f(sp['dlist_us'])} + read {f(sp['read_us'])} + first draw, in one "
                f"process as the app would). List size {sp['dlist_bytes']['median'] / 1024:.0f} KB median, "
                f"{sp['dlist_bytes']['p95'] / 1024:.0f} KB p95."]
    return [f"**Speed per page at {SCALE:g}×** (no --bench: ours is a cold process per page, not like for like): MuPDF "
            f"render {f(sp['mupdf_us'])}; ours {f(sp['ours_us'])} = dlist {f(sp['dlist_us'])} + read {f(sp['read_us'])} + "
            f"draw {f(sp['draw_us'])}."]


def report(s: dict, results: list[dict], run_dir: Path, cmp: dict | None) -> str:
    t = s["total"]
    L = [f"# Harness run {s['run']}", "",
         f"{s['when']} · commit `{s['commit']}` · corpus `{s['corpus']}` · ours: **{s['ours']}** · "
         f"{s['seconds']:.0f} s · scale {SCALE:g} · images: `{run_dir}`", "",
         f"**{t['within']} of {t['with_floor']} pages within the floor** ({pct(t['within'], t['with_floor'])}); "
         f"{t['pages']} pages scored; bad px {t['bad']:,} (floor {t['floor']:,}); mean SSIM {t['ssim']}.", "",
         *speed_lines(s), "",
         "A page is within the floor when its bad px ≤ floor + 25 (`measure.py`). The floor is Tectonic's PDF drawn by "
         "MuPDF and by Core Graphics; it applies only where the oracle and that PDF show the same thing "
         f"(≤ {MATCH_OK} bad px apart), so pages without one aren't counted in the rate.", ""]
    if cmp:
        L += ["## Against " + cmp["run"], "", *cmp["lines"], ""]
    left = []
    for r in sorted(s["papers"], key=lambda r: r["paper"]):
        why = ("oracle invalid: " + r["oracle_invalid"] if r.get("oracle_invalid") else
               "txp-render failed: " + r["txp_error"] if r.get("txp_error") else
               "harness error: " + r["error"].strip().splitlines()[-1] if r.get("error") else
               "no Tectonic PDF, so no floor: scored, not counted in the rate" if not r.get("tectonic", True) else None)
        if why:
            left.append(f"- **{r['paper']}**: {why[:160]}")
    if left:
        L += ["## Not scored, or scored without a floor", "", *left, ""]
    wrong = [dict(pg, paper=r["paper"]) for r in results for pg in r["pages"] if pg.get("oracle_wrong") and "bad" in pg]
    if wrong:
        L += ["## Oracle overridden (MuPDF wrong, judged against CG's drawing of Tectonic's PDF)", "",
              "| paper | page | bad vs CG | within | why |", "|---|---|---|---|---|"]
        for p in wrong:
            L.append(f"| {p['paper']} | {p['page']} | {p['bad']:,} | {'yes' if p['within'] else '**no**'} | {p['oracle_wrong']} |")
        L.append("")
    pages = sorted([dict(pg, paper=r["paper"], odir=r.get("oracle_dir")) for r in results for pg in r["pages"] if "bad" in pg],
                   key=lambda p: -(p["bad"] - (p["floor"] or 0)))
    L += ["## Worst pages", "", "| paper | page | bad | floor | within | SSIM | groups | images |", "|---|---|---|---|---|---|---|---|"]
    for p in pages[:25]:
        g = ", ".join(f"{k} {v}" for k, v in sorted(p.get("groups", {}).items(), key=lambda kv: -kv[1]) if v)
        refp = (f"{Path(s.get('floor_dirs', {}).get(p['paper'], ''))}/cg/p{p['pdf_page']}.png" if p.get("oracle_wrong")
                else f"{p['odir']}/p{p['page']}.png")
        imgs = (f"[{'cg-pdf' if p.get('oracle_wrong') else 'oracle'}](file://{refp}) · [ours](file://{p['ours']}) · "
                f"[heatmap](file://{run_dir}/{p['paper']}/p{p['page']}.heat.png)")
        w = {True: "yes", False: "**no**", None: "–"}[p["within"]]
        if p.get("note"):
            g = f"*{p['note']}*" + (", " + g if g else "")
        L.append(f"| {p['paper']} | {p['page']} | {p['bad']:,} | {p['floor'] if p['floor'] is not None else '–'} | {w} | "
                 f"{p['ssim']} | {g} | {imgs} |")
    if s["by_group"]:
        L += ["", "## By feature group (display-list op areas)", "", "| group | pages | bad px |", "|---|---|---|"]
        for g, v in sorted(s["by_group"].items()):
            L.append(f"| {g} | {v['pages']} | {v['bad']:,} |")
    L += ["", "## By paper tag", "", "| tag | pages | within floor | bad px | floor px | SSIM |", "|---|---|---|---|---|---|"]
    for tag, v in s["by_tag"].items():
        L.append(f"| {tag} | {v['pages']} | {v['within']}/{v['with_floor']} | {v['bad']:,} | {v['floor']:,} | {v['ssim']} |")
    L += ["", "## Papers", "", "| paper | pages | within floor | bad px | typeset s | run s | notes |", "|---|---|---|---|---|---|---|"]
    for r in sorted(s["papers"], key=lambda r: r["paper"]):
        sc = r["score"]
        notes = []
        if not r.get("tectonic", True):
            notes.append("no Tectonic PDF: no floor")
        if r.get("oracle_invalid"):
            notes.append("**oracle invalid, not scored**: " + r["oracle_invalid"][:100])
        if r.get("txp_error"):
            notes.append("txp-render: " + r["txp_error"][:80])
        if r.get("error"):
            notes.append("harness error: " + r["error"].strip().splitlines()[-1][:80])
        L.append(f"| {r['paper']} | {r.get('n', '–')} | {sc['within']}/{sc['with_floor']} | {sc['bad']:,} | "
                 f"{r.get('typeset_s', '–')} | {r.get('seconds', '–')} | {'; '.join(notes)} |")
    return "\n".join(L) + "\n"


def compare_runs(new: dict, old_name: str) -> dict:
    p = HERE / "results" / "kept" / old_name / "summary.json"
    old = json.loads((p if p.exists() else HERE / "results" / old_name / "summary.json").read_text())
    key = lambda p: (p["paper"], p["page"])  # noqa: E731
    o = {key(p): p for p in old["pages"]}
    better, worse, noted = [], [], []   # noted: worse on a page with a known gap in ours (e.g. "ours: shade missing")
    for p in new["pages"]:
        q = o.get(key(p))
        if not q:
            continue
        d = p["bad"] - q["bad"]
        if d < -measure.MARGIN:
            better.append((d, p, q))
        elif d > measure.MARGIN:
            (noted if p.get("note") else worse).append((d, p, q))
    tn, to = new["total"], old["total"]
    lines = [f"Within the floor: {to['within']}/{to['with_floor']} → {tn['within']}/{tn['with_floor']}; "
             f"bad px {to['bad']:,} → {tn['bad']:,}; {len(better)} pages better, {len(worse)} worse (by > {measure.MARGIN} px)"
             + (f", and {len(noted)} worse on pages with a known gap in ours (listed apart)" if noted else "") + ".", ""]
    so, sn = old.get("speed") or {}, new.get("speed") or {}
    for k in ("ours_us", "mupdf_us", "ours_first_us", "mupdf_first_us", "dlist_us"):
        if so.get(k) and sn.get(k):
            lines.append(f"Speed {k}: median {so[k]['median'] / 1000:.1f} → {sn[k]['median'] / 1000:.1f} ms, "
                         f"p95 {so[k]['p95'] / 1000:.1f} → {sn[k]['p95'] / 1000:.1f} ms")
    lines.append("")
    for name, rows in (("Worse", sorted(worse, key=lambda r: -r[0])), ("Better", sorted(better, key=lambda r: r[0])),
                       ("Worse, known gap in ours", sorted(noted, key=lambda r: -r[0]))):
        if rows:
            lines.append(f"{name}: " + ", ".join(f"{p['paper']} p{p['page']} {q['bad']}→{p['bad']}"
                                                  + (f" ({p['note']})" if p.get("note") else "") for _, p, q in rows[:15]))
            lines.append("")
    return {"run": old_name, "lines": lines}


# ---- main ------------------------------------------------------------------------------------------------------------

def main() -> None:
    a = argparse.ArgumentParser()
    a.add_argument("what", nargs="*", default=["smoke"])
    a.add_argument("--compare")
    a.add_argument("--name")
    a.add_argument("--keep", action="store_true", help="write to results/kept/<run> (tracked) instead of results/<run> (ignored)")
    a.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) // 4))   # each paper uses ~2 cores
    a.add_argument("--ours", choices=["backend", "cg-pdf"])
    a.add_argument("--texpresso", help="a built TeXpresso clone (default: TEXPRESSO_DIR, else build.sh's)")
    o = a.parse_args()
    if o.texpresso:
        os.environ["TEXPRESSO_DIR"] = str(Path(o.texpresso).expanduser().resolve())
    papers = corpus.load()
    toml = corpus.tomllib.loads(corpus.MANIFEST.read_text())
    if o.what == ["smoke"]:
        ids, cname = toml["smoke"], "smoke"
    elif o.what == ["full"]:
        ids, cname = [k for k, v in papers.items() if v.get("main")], "full"   # failures are listed, not skipped
    else:
        ids, cname = o.what, "papers"
    ids = [i for i in ids if papers.get(i, {}).get("main")]
    build_txp()
    oracle_bin()   # built once here, not by each worker
    rbin = None
    mode = o.ours or "backend"
    if mode == "backend":
        rbin = raster_bin()
        if not rbin:
            sys.exit("taudot-raster doesn't build (see above); --ours cg-pdf runs the stand-in")
    commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True, cwd=REPO).stdout.strip()
    name = o.name or dt.datetime.now().strftime("%Y-%m-%dT%H%M") + f"-{cname}"
    run_dir = RESULTS / "runs" / name
    run_dir.mkdir(parents=True, exist_ok=True)
    t0 = time.monotonic()
    results = []
    with ProcessPoolExecutor(max_workers=o.jobs) as ex:
        futs = {ex.submit(paper_safe, pid, papers[pid], run_dir, mode, str(rbin) if rbin else None): pid for pid in ids}
        for f in as_completed(futs):
            r = f.result()
            results.append(r)
            ok = [p for p in r["pages"] if "bad" in p]
            print(f"{r['paper']:22} {len(ok):3} pages  bad {sum(p['bad'] for p in ok):8,}  "
                  f"{r.get('seconds', '?')} s  {r.get('txp_error') or (r.get('error') or '').strip()[-120:]}", flush=True)
    meta = {"run": name, "when": dt.datetime.now().isoformat(timespec="seconds"), "commit": commit, "corpus": cname,
            "ours": mode if mode == "backend" else "cg-pdf (stand-in: Tectonic's PDF drawn by Core Graphics)",
            "seconds": round(time.monotonic() - t0, 1), "scale": SCALE, "oracle_key": oracle_key(),
            "oracle_bin": str(oracle_bin()),
            "texpresso": str(texpresso_dir()), "texpresso_head": subprocess.run(
                ["git", "-C", str(texpresso_dir()), "log", "--oneline", "-1"], capture_output=True, text=True).stdout.strip()}
    s = summarise(sorted(results, key=lambda r: r["paper"]), meta)
    cmp = compare_runs(s, o.compare) if o.compare else None
    rd = HERE / "results" / ("kept" if o.keep else "") / name
    rd.mkdir(parents=True, exist_ok=True)
    (rd / "summary.json").write_text(json.dumps(s, indent=1))
    (rd / "report.md").write_text(report(s, results, run_dir, cmp))
    t = s["total"]
    print(f"\n{name}: {t['within']}/{t['with_floor']} pages within the floor, {t['pages']} scored, bad {t['bad']:,}, "
          f"{meta['seconds']:.0f} s → {rd / 'report.md'}")
    if cmp:
        print("\n".join(cmp["lines"]))


if __name__ == "__main__":
    main()
