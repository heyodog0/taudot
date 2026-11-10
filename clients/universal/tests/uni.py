# MIT. Checks and measurements for clients/universal (docs/universal.md). Paper content never enters the repo:
# projects are copied into WORK (a scratch directory).
#
#   uv run clients/universal/tests/uni.py exact ENGINE SRC MAIN          step 1: a run under libtau == a stock run
#   uv run clients/universal/tests/uni.py edits ENGINE SRC MAIN [N]      step 2: N random edits through tau-live, each
#                                                                         final output == a fresh stock run
#   uv run clients/universal/tests/uni.py finish ENGINE SRC MAIN [N]     step 3: finished-early outputs == the full
#                                                                         run's pages
# ENGINE: pdflatex | xelatex | lualatex. Environment: clients/universal/env.sh, WORK.
import json
import os
import random
import re
import shutil
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
UBIN = os.environ["UBIN"]  # libtau, tau-live and the engines it runs (stock source, zlib as a dylib)
USTOCK = os.environ.get("USTOCK", UBIN)  # the reference: stock engines as TeX Live builds them
WORK = os.environ.get("WORK") or sys.exit("set WORK (a scratch directory)")
ENGINES = {
    "pdflatex": (["pdflatex"], "pdf"),
    "xelatex": (["xelatex", "-no-pdf"], "xdv"),
    "lualatex": (["lualatex"], "pdf"),
}


def cmd(engine, main, bin=None):
    args, _ = ENGINES[engine]
    return [f"{bin or UBIN}/{args[0]}", *args[1:], "-interaction=batchmode", main]


def stock_env():
    e = dict(os.environ)
    for k in list(e):
        if k.startswith("TAU_") or k == "DYLD_INSERT_LIBRARIES":
            e.pop(k)
    return e


def run_stock(engine, d, main):
    t = time.monotonic()
    subprocess.run(cmd(engine, main, USTOCK), cwd=d, env=stock_env(), stdin=subprocess.DEVNULL,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return (time.monotonic() - t) * 1000


def run_tau(engine, d, main, out, fetch=False):
    e = dict(os.environ, DYLD_INSERT_LIBRARIES=f"{UBIN}/libtau.dylib", TAU_OUT=out, TAU_PROJECT=d)
    if not fetch:
        e.pop("TAU_FETCH", None)
        e.pop("TEXSTORE_URL", None)
    t = time.monotonic()
    subprocess.run(cmd(engine, main), cwd=d, env=e, stdin=subprocess.DEVNULL,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return (time.monotonic() - t) * 1000


def copy(src, dst):
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(src, dst, symlinks=True)


def stem(main):
    return os.path.splitext(main)[0]


def settle(engine, src, main, name):
    """A copy of SRC with its .aux settled by the stock engine (two runs), so edits run on a realistic state."""
    base = f"{WORK}/{name}-{engine}-base"
    if not os.path.exists(base + "/.settled"):
        copy(src, base)
        out = f"{WORK}/{name}-{engine}-warm"
        shutil.rmtree(out, ignore_errors=True)
        os.makedirs(out)
        run_tau(engine, base, main, out, fetch=True)  # fetches TeX Live files the stock engine will need
        stock_rule(engine, base, main)  # settled as latexmk would leave it: BibTeX, reruns
        open(base + "/.settled", "w").close()
    return base


def exact(engine, src, main):
    name = os.path.basename(os.path.abspath(src))
    base = settle(engine, src, main, name)
    # both runs in the same directory: LuaTeX's /ID hashes the output's absolute path
    a, b, out = f"{WORK}/x-ref", f"{WORK}/x-run", f"{WORK}/x-out"
    copy(base, b)
    ts = run_stock(engine, b, main)
    copy(b, a)
    copy(base, b)
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    tt = run_tau(engine, b, main, out)
    (got,) = [f"{out}/{x}" for x in os.listdir(out)]
    ok = True
    for f in sorted(os.listdir(got)):
        same = open(f"{a}/{f}", "rb").read() == open(f"{got}/{f}", "rb").read() if os.path.exists(f"{a}/{f}") else None
        ok &= bool(same) or f.endswith(".log") and engine == "lualatex"
        print(f"  {f}: {'identical' if same else 'DIFFERENT' if same is False else 'missing in stock run'}")
    untouched = all(os.path.getmtime(f"{b}/{f}") <= os.path.getmtime(f"{b}/.settled") + 1
                    for f in os.listdir(b) if os.path.isfile(f"{b}/{f}"))
    print(f"exact {engine} {name}: {'PASS' if ok else 'FAIL'}; stock {ts:.0f} ms, under libtau {tt:.0f} ms; "
          f"project dir untouched: {untouched}")
    return ok


# ------------------------------------------------------------------------------------------------- tau-live

def newer_run(live):
    """The run event of the edit just sent: a newer compile than any seen (reruns of the last one emit runs too)."""
    last = max([e["seq"] for e in live.events if e["ev"] == "run"] or [-1])
    return live.until(lambda e: e["ev"] == "run" and e["seq"] > last)


class Live:
    def __init__(self, engine, d, main, out, *opts, synctex=False):
        env = dict(os.environ)
        env.pop("TAU_FETCH", None)
        env.pop("TEXSTORE_URL", None)
        c = cmd(engine, main)
        if synctex:  # as the app runs it (the paragraph preview finds the old lines with SyncTeX)
            c.insert(-1, "-synctex=-1")
        argv = [f"{UBIN}/tau-live", *opts, d, main, out, "--", *c]
        if os.environ.get("PATCHED"):  # the patched pdfTeX of clients/pdftex, for comparison (same protocol)
            pb = os.path.join(os.environ.get("TAUDOT_REF", os.path.expanduser("~/code/lab/taudot-ref")), "pdftex-build-2026")
            env.update(TEXFORMATS=f".:{pb}/fmt-live", TEXSTORE_URL="https://texlive.taudot.app")
            argv = [f"{pb}/pdftex-live", "--serve", "--engine", f"{pb}/live/texk/web2c/pdflatex", "--max-runs", "1",
                    d, main, out]
        self.p = subprocess.Popen(argv,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
        self.events = []

    def send(self, *c):
        self.p.stdin.write(json.dumps(list(c)) + "\n")
        self.p.stdin.flush()

    def until(self, pred, timeout=120):
        t = time.monotonic()
        while time.monotonic() - t < timeout:
            line = self.p.stdout.readline()
            if not line:
                raise RuntimeError("tau-live exited")
            ev = json.loads(line)
            self.events.append(ev)
            if pred(ev):
                return ev
        raise TimeoutError

    def close(self):
        self.p.stdin.close()
        self.p.wait(10)


WORD = re.compile(rb"[A-Za-z]{3,}")
ID = re.compile(rb"/ID \[ ?<[0-9A-Fa-f]+> ?<[0-9A-Fa-f]+> ?\]")


def same_output(engine, a, b):
    """Byte-identical; for LuaTeX apart from /ID, which hashes the output's absolute path (the live engine runs in
    its own clone, the reference in a copy: different paths)."""
    if engine == "lualatex":
        a, b = ID.sub(b"/ID", a), ID.sub(b"/ID", b)
    return a == b


def random_edit(rng, text, lo):
    """An edit inside running text after byte LO: insert a word, delete a word, or change a letter."""
    ms = [m for m in WORD.finditer(text, lo)]
    m = rng.choice(ms)
    kind = rng.choice(["ins", "del", "chr"])
    if kind == "ins":
        return m.start(), 0, rng.choice(["quick ", "lazy ", "very ", "Taudot "])
    if kind == "del":
        end = m.end() + (1 if text[m.end():m.end() + 1] == b" " else 0)
        return m.start(), end - m.start(), ""
    i = rng.randrange(m.start(), m.end())
    return i, 1, rng.choice([c for c in "aeiou" if c != chr(text[i])])


def edits(engine, src, main, n=30, seed=1):
    name = os.path.basename(os.path.abspath(src))
    base = settle(engine, src, main, name)
    out = f"{WORK}/e-out"
    shutil.rmtree(out, ignore_errors=True)
    rng = random.Random(seed)
    text = open(f"{base}/{main}", "rb").read()
    lo = text.find(b"\\begin{document}")
    live = Live(engine, base, main, out)
    ev = live.until(lambda e: e["ev"] == "done")
    print(f"first run: {ev['edit_us'] / 1000:.0f} ms, {ev['pages']} pages")
    ref = f"{WORK}/e-ref"
    copy(base, ref)
    stock_rule(engine, ref, main)  # (the base is settled: this changes nothing, but starts the reference's BibTeX state)
    ext = ENGINES[engine][1]
    times, fails, fresh = [], 0, 0
    for i in range(n):
        time.sleep(0.15)  # let snapshots accumulate as they would while the user reads
        pos, dl, ins = random_edit(rng, text, lo)
        insb = ins.encode()
        text = text[:pos] + insb + text[pos + dl:]
        live.send("change", main, pos, dl, ins)
        run = newer_run(live)
        done = live.until(lambda e: e["ev"] == "done" and e["seq"] == run["seq"])
        fresh += bool(run.get("fresh"))
        got = open(done["path"], "rb").read()
        # the reference gets the same edits and latexmk's rule (tau-live keeps the rewritten .aux in its clone)
        open(f"{ref}/{main}", "wb").write(text)
        stock_rule(engine, ref, main)
        want = open(f"{ref}/{stem(main)}.{ext}", "rb").read()
        ok = same_output(engine, got, want)
        fails += not ok
        times.append(done["edit_us"] / 1000)
        print(f"  edit {i:2d} @{pos:6d} {'ok' if ok else 'DIFFERENT'} {done['edit_us'] / 1000:6.1f} ms"
              f"{' (fresh)' if run.get('fresh') else ''} snapshots {run.get('snapshots', 0)}")
    live.send("stats")
    st = live.until(lambda e: e["ev"] == "stats")
    live.close()
    q = statistics.quantiles(times, n=20)
    print(f"edits {engine} {name}: {n - fails}/{n} identical; edit -> final output p50 {statistics.median(times):.0f} "
          f"ms, p95 {q[18]:.0f} ms; fresh restarts {fresh}; snapshots {st['snapshots']}, footprint "
          f"{st['footprint'] / 2**20:.0f} MiB total, {st['max_footprint'] / 2**20:.0f} MiB max")
    return fails == 0


def pages_of(path):
    """Each page's decompressed content stream and font resource names (pypdf)."""
    from pypdf import PdfReader
    out = []
    for pg in PdfReader(path).pages:
        fonts = sorted((pg.get("/Resources") or {}).get("/Font", {}).keys())
        c = pg.get_contents()  # (a ContentStream is falsy: test against None)
        out.append((c.get_data() if c is not None else b"", fonts))
    return out


def same_pages(a, b, k):
    """Pages 1..k of A equal those of B (for XDV: the page's bytes between bop and eop)."""
    if a.endswith(".xdv"):
        pa, pb = xdv_pages(a), xdv_pages(b)
    else:
        pa, pb = pages_of(a), pages_of(b)
    assert all(p[0] for p in pa[:k]), "empty page contents: the check would be vacuous"
    return len(pa) >= k and len(pb) >= k and pa[:k] == pb[:k]


def xdv_pages(path):
    import xdv
    return xdv.pages(open(path, "rb").read())


def finish(engine, src, main, n=10, seed=2):
    name = os.path.basename(os.path.abspath(src))
    base = settle(engine, src, main, name)
    out = f"{WORK}/f-out"
    shutil.rmtree(out, ignore_errors=True)
    live = Live(engine, base, main, out, "--hook", "--finish", "every")
    live.send("goal", 0)  # the patched driver: finish at the first page past the edit (tau-live always does)
    pdfs = []
    while True:
        ev = live.until(lambda e: e["ev"] in ("pdf", "done") and not e.get("display"))
        if ev["ev"] == "done":
            break
        if not ev["final"]:
            pdfs.append(ev)
            shutil.copy(ev["path"], f"{out}/fin-{ev['pages']}.{ENGINES[engine][1]}")
    final = ev["path"]
    shutil.copy(final, f"{out}/final.{ENGINES[engine][1]}")
    final = f"{out}/final.{ENGINES[engine][1]}"
    bad = [e["pages"] for e in pdfs if not same_pages(f"{out}/fin-{e['pages']}.{ENGINES[engine][1]}", final, e["pages"])]
    print(f"open: {len(pdfs)} finished-early outputs, {ev['pages']} pages; pages so far identical to the full run's: "
          f"{len(pdfs) - len(bad)}/{len(pdfs)} {'' if not bad else bad}")
    # edits: time to the first finished output after the edit (the edited page), and its pages == a fresh run's;
    # a new session with the app's finish rule (the first page past the edit, then at most every 150 ms)
    live.close()
    live = Live(engine, base, main, f"{out}/rule", "--hook")
    live.send("goal", 0)
    live.until(lambda e: e["ev"] == "done")
    rng = random.Random(seed)
    text = open(f"{base}/{main}", "rb").read()
    lo = text.find(b"\\begin{document}")
    ref = f"{WORK}/f-ref"
    times, fails = [], 0
    ext = ENGINES[engine][1]
    for i in range(n):
        time.sleep(0.15)
        pos, dl, ins = random_edit(rng, text, lo)
        text = text[:pos] + ins.encode() + text[pos + dl:]
        live.send("change", main, pos, dl, ins)
        run = newer_run(live)
        first = live.until(lambda e: e["ev"] in ("pdf", "done") and e.get("seq") == run["seq"] and not e.get("display"))
        if first["ev"] == "done":
            first = [e for e in live.events if e["ev"] == "pdf" and e["seq"] == run["seq"] and not e.get("display")][-1]
        got = f"{out}/edit-{i}.{ext}"
        shutil.copy(first["path"], got)
        live.until(lambda e: e["ev"] == "done" and e["seq"] == run["seq"]) if live.events[-1]["ev"] != "done" else None
        subprocess.run(["sh", "-c", f'rm -rf "{ref}" && cp -c -R "{base}" "{ref}"'], check=True)
        open(f"{ref}/{main}", "wb").write(text)
        run_stock(engine, ref, main)
        ok = same_pages(got, f"{ref}/{stem(main)}.{ext}", first["pages"])
        fails += not ok
        times.append(first["edit_us"] / 1000)
        print(f"  edit {i:2d} @{pos:6d} {'ok' if ok else 'DIFFERENT'} first output {first['edit_us'] / 1000:6.1f} ms "
              f"({first['pages']} pages{', final' if first['final'] else ''}) finish {first.get('finish_us', 0) / 1000:.1f} ms")
    live.close()
    print(f"finish {engine} {name}: {n - fails}/{n} identical; edit -> first exact output p50 "
          f"{statistics.median(times):.0f} ms, max {max(times):.0f} ms")
    return not bad and not fails


def typing(engine, src, main, n=40, seed=3, *opts):
    """Type a sentence at one spot, a key every 120 ms: edit -> first exact output, per key."""
    name = os.path.basename(os.path.abspath(src))
    base = settle(engine, src, main, name)
    out = f"{WORK}/t-out"
    shutil.rmtree(out, ignore_errors=True)
    rng = random.Random(seed)
    text = open(f"{base}/{main}", "rb").read()
    lo = text.find(b"\\begin{document}")
    live = Live(engine, base, main, out, "--hook", *opts)
    live.send("goal", 0)
    live.until(lambda e: e["ev"] == "done")
    pos = [m.end() for m in re.finditer(rb"[a-z]{4,}\. ", text[lo:])]
    times = []
    sentence = "Typing goes here, one key at a time, as a user would. "
    for spot in range(n // 20):
        p = lo + rng.choice(pos)
        for i in range(20):
            time.sleep(0.12)
            live.send("change", main, p + i, 0, sentence[i])
            text = text[:p + i] + sentence[i].encode() + text[p + i:]
            run = newer_run(live)
            first = live.until(lambda e: e["ev"] in ("pdf", "done") and e.get("seq") == run["seq"])
            if first["ev"] == "pdf":
                times.append(first["edit_us"] / 1000)
        done = first if first["ev"] == "done" else live.until(lambda e: e["ev"] == "done" and e["seq"] == run["seq"])
        ref = f"{WORK}/t-ref"
        if spot == 0:
            copy(base, ref)
            stock_rule(engine, ref, main)
        open(f"{ref}/{main}", "wb").write(text)
        stock_rule(engine, ref, main)  # latexmk's rule, as tau-live applies it
        ext = ENGINES[engine][1]
        same = same_output(engine, open(done["path"], "rb").read(), open(f"{ref}/{stem(main)}.{ext}", "rb").read())
        print(f"  spot {spot}: final output after 20 keys {'identical' if same else 'DIFFERENT'} to a stock run")
    live.close()
    paras = [e for e in live.events if e["ev"] == "para"]
    if paras:
        pu = [e["us"] / 1000 for e in paras]
        print(f"  paragraph pass: {len(paras)} of {len(times)} keys, edit -> lines written p50 "
              f"{statistics.median(pu):.1f} ms, p95 {statistics.quantiles(pu, n=20)[18]:.1f} ms")
    q = statistics.quantiles(times, n=20)
    print(f"typing {engine} {name}{' (patched pdfTeX)' if os.environ.get('PATCHED') else ''}: {len(times)} keys, "
          f"key -> first exact output p50 {statistics.median(times):.0f} ms, p95 {q[18]:.0f} ms")


def paragraph(engine, src, main, n=20, seed=4):
    """Step 5: random edits; each paragraph pass's lines == the same lines of the exact page (the run's final
    output, itself checked against stock in step 2)."""
    import para
    name = os.path.basename(os.path.abspath(src))
    base = settle(engine, src, main, name)
    out = f"{WORK}/p-out"
    shutil.rmtree(out, ignore_errors=True)
    live = Live(engine, base, main, out, "--hook", synctex=True)
    live.until(lambda e: e["ev"] == "done")
    rng = random.Random(seed)
    text = open(f"{base}/{main}", "rb").read()
    lo = text.find(b"\\begin{document}")
    pdf = engine != "xelatex"
    stats = {"identical": 0, "different": 0, "provisional": 0, "box": 0, "none": 0}
    pix = []
    tdlstats = []
    times = []
    evs = []
    place = {"exact": 0, "provisional": 0, "none": 0, "px0": 0, "worst": 0}
    for i in range(n):
        time.sleep(0.15)
        pos, dl, ins = random_edit(rng, text, lo)
        text = text[:pos] + ins.encode() + text[pos + dl:]
        live.send("change", main, pos, dl, ins)
        run = newer_run(live)
        live.until(lambda e: e["ev"] == "done" and e["seq"] == run["seq"])  # the runner has passed the spot
        live.send("change", main, pos + len(ins), 0, " ")  # a second key at the same spot: a dense snapshot
        text = text[:pos + len(ins)] + b" " + text[pos + len(ins):]
        run = live.until(lambda e: e["ev"] == "run" and e["seq"] > run["seq"])
        done = live.until(lambda e: e["ev"] == "done" and e["seq"] == run["seq"])
        ev = [e for e in live.events if e["ev"] == "para" and e["seq"] == run["seq"]]
        if not ev:
            stats["none"] += 1
            print(f"  edit {i:2d} @{pos:6d} no pass (snapshot not in the edited file's paragraph)")
            continue
        ev = ev[0]
        times.append(ev["us"] / 1000)
        evs.append(ev)
        placed = ""
        if ev.get("state") in ("exact", "provisional"):  # the event as the app takes it (docs/live-protocol.md)
            place[ev["state"]] += 1
            if ev["state"] == "exact" and pdf:
                import pixels
                nd, tot, fo = pixels.event_check(ev, done["path"])
                place["px0"] += nd == 0
                place["worst"] = max(place["worst"], nd)
                place["foreign"] = place.get("foreign", 0) + (fo > 0)
                placed = (f"; event {ev['state']} page {ev['page']}: {nd} px differ of {tot} in the new lines' rect"
                          + (f" (and {fo} px of other ink in it)" if fo else ""))
            elif ev["state"] == "exact":  # XeTeX: the list's glyph baselines on the exact page's lines
                import tdl as tdlr
                import xdv
                _, rs = tdlr.runs(ev["path"])
                ys = sorted({round(y, 3) for f_, gl in rs for x_, y, t_ in gl})
                pg = xdv.pages(open(done["path"], "rb").read())[ev["page"]]
                base = sorted({(v + 4736286) * 72 / 72.27 / 65536 for v, *_ in para.xdv_runs(pg)})
                off = max((min(abs(y - b) for b in base) for y in ys), default=99)
                place["px0"] += off < 0.01
                place["worst"] = max(place["worst"], off)
                if off >= 0.01 and os.environ.get("EV_DEBUG"):
                    print("    tdl ys", ys[:12], "\n    page bases", [round(b, 3) for b in base if ys and ys[0] - 30 < b < ys[-1] + 30], "\n   ", ev)
                placed = f"; event exact page {ev['page']}: TDL baselines within {off:.4f} pt of the exact page's"
            placed += f", {ev['us'] / 1000:.1f} ms to the event (reader {ev.get('draw_us', 0) / 1000:.1f} ms)"
        else:
            place["none"] += 1
            placed = f"; event none ({ev.get('why')})"
        blob = open(ev["bin"], "rb").read() if ev.get("bin") else b""
        if not blob:
            stats["box"] += 1
            print(f"  edit {i:2d} @{pos:6d} no overlay (no page: a box, a float, a caption) {ev['us'] / 1000:.1f} ms{placed}")
            continue
        if ev.get("state") == "none" and ev.get("why") == "insert":  # the lines weren't the page's last (a float, a
            stats["box"] += 1  # footnote): what the pass shipped is the page so far; the app gets no overlay
            print(f"  edit {i:2d} @{pos:6d} no overlay (the lines weren't the last thing on the page) "
                  f"{ev['us'] / 1000:.1f} ms{placed}")
            continue
        shipped = ev.get("pieces", 1)
        if shipped > 1:  # a page break inside the paragraph: the overlay would be provisional
            stats["provisional"] += 1
            print(f"  edit {i:2d} @{pos:6d} provisional (the paragraph crosses a page or column) {ev['us'] / 1000:.1f} ms{placed}")
            continue
        if pdf:
            ours = para.lines(para.text_runs(para.pdf_runs(b"".join(para.streams(blob)))))
            time.sleep(float(os.environ.get("PARA_SLEEP", "0")))
            pages = [para.lines(para.text_runs(para.pdf_runs(c))) for c in pdf_pages_content(done["path"])]
        else:
            import xdv
            pg = para.xdv_pass_page(blob)
            ours = para.lines(para.xdv_runs(pg) if pg else [], pdf=False)
            pages = [para.lines(para.xdv_runs(pg), pdf=False) for pg in xdv.pages(open(done["path"], "rb").read())]
        flat = [[(y + dy, x, f, s_, o) for y, r in pg for dy, x, f, s_, o in r] for pg in pages]
        tol = 0.05 if pdf else 3  # pt in PDF; sp in XDV
        hit = None
        for pi, pg in enumerate(flat):
            off = para.match_lines(ours, pg, ev["lines"], 0 if not pdf else tol, pdf, strict=not pdf) \
                if ev["lines"] > 0 else None
            if off:
                hit = (pi, off)
                break
        ok = hit is not None
        if ok and pdf:  # and byte for byte: every TJ operand equal, positions within pdfTeX's printed 0.001 pt
            strict = para.match_lines(ours, flat[hit[0]], ev["lines"], 0.0015, pdf, strict=True)
            stats["bytes"] = stats.get("bytes", 0) + bool(strict)
        elif ok:
            stats["bytes"] = stats.get("bytes", 0) + 1  # XDV: already strict (byte-equal runs, integer sp)
        px = ""
        if ok and pdf:  # the independent check: pixels, no tolerance
            import pixels
            n_ = ev["lines"]
            content = b"".join(c for c in para.streams(blob) if b"BT" in c)
            base_ys = [y for y, r in ours[-n_:]]
            x0 = min(x for y, r in ours[-n_:] for dy_, x, f, s_, o in r)
            d, vis, tot, fo = pixels.diff(done["path"], hit[0], content, hit[1][0], hit[1][1], base_ys, x0)
            # where pixels differ: the largest difference in line positions (start x, baseline) as printed
            dx_, dy_ = hit[1]
            delta = 0.0
            for y, r in ours[-n_:]:  # each line's first run against the page's run at the same place, same glyphs
                _, xs_, f0, s0, o0 = min(r, key=lambda t: t[1])
                cands = [abs(py - (y + dy_)) + abs(px_ - (xs_ + dx_)) for py, px_, pf, ps, po in flat[hit[0]]
                         if (pf, ps) == (f0, s0) and para.glyphs(po) == para.glyphs(o0)]
                delta = max(delta, min(cands) if cands else float("inf"))
            pix.append((d, vis, tot, delta))
            if os.environ.get("TDL"):  # the reader: overlay PDF + TDL FIGURE, drawn as the app would
                r = subprocess.run([f"{UBIN}/tau-tdl", "pdf", done["path"], str(hit[0]), ev["bin"],
                                    f"{out}/ov.pdf", f"{out}/ov.tdl"], capture_output=True, text=True)
                info = json.loads(r.stdout.strip().splitlines()[-1]) if r.stdout.strip() else {"ok": False}
                if info.get("ok") and info.get("dy") is not None:
                    top, bot = max(base_ys) + hit[1][1] + 7.5, min(base_ys) + hit[1][1] - 3
                    left = x0 + hit[1][0] - 1
                    ov = open(f"{out}/ov.pdf", "rb").read()
                    a_, w_, h_ = pixels.render(ov, hit[0], (left, bot, left + 600, top))
                    right = left + (pixels.ink_right(a_, w_, h_, 0) + 1) / pixels.SCALE + 2  # the column, not its neighbour
                    a_, w_, h_ = pixels.render(ov, hit[0], (left, bot, right, top))
                    b_, _, _ = pixels.render(open(done["path"], "rb").read(), hit[0], (left, bot, right, top))
                    nd = sum(1 for i in range(0, len(a_), 4) if a_[i:i + 3] != b_[i:i + 3])
                    tdlstats.append((nd, info["us"]))
                    px += f"; reader: dy {info['dy']:.3f}, {nd} px differ, {info['us'] / 1000:.1f} ms"
                else:
                    tdlstats.append((None, 0))
                    px += f"; reader: {info}"
            px = f", {d} px differ ({vis} visibly) of {tot}; positions differ by at most {delta:.4f} pt"
        if os.environ.get("PARA_DEBUG"): print("   ", ev["bin"], done["path"], len(ours), len(pages), len(blob), para.__file__); import pickle; pickle.dump((ours, pages), open(ev["path"] + ".pkl", "wb"))
        k = max([m for m in range(1, min(len(ours), 40) + 1) if any(para.match_lines(ours, pg, m, tol, pdf) for pg in flat)] or [0])
        stats["identical" if ok else "different"] += 1
        print(f"  edit {i:2d} @{pos:6d} {'identical' if ok else 'DIFFERENT'} {ev['lines']} lines (last {k} match) "
              f"{ev['us'] / 1000:.1f} ms{px}{placed}")
    live.close()
    q = statistics.quantiles(times, n=20) if len(times) > 1 else [0] * 19
    ov = stats["identical"] + stats["different"]
    print(f"paragraph {engine} {name}: {stats}; overlay on {ov}/{n} edits ({stats['provisional']} provisional, "
          f"{stats['box'] + stats['none']} none); edit -> lines written p50 {statistics.median(times):.1f} ms, "
          f"p95 {q[18]:.1f} ms")
    ev_us = [e["us"] / 1000 for e in evs if e.get("state") != "none"]
    print(f"  events: exact {place['exact']}, provisional {place['provisional']}, none {place['none']}; exact ones placed "
          f"{'with 0 px differing' if pdf else 'on the exact baselines'}: {place['px0']}/{place['exact']} "
          f"(worst {place['worst']}; {place.get('foreign', 0)} with other ink in the rect); edit -> event p50 "
          f"{statistics.median(ev_us or [0]):.1f} ms")
    if tdlstats:
        ok_ = [d for d, u in tdlstats if d is not None]
        print(f"  reader (overlay PDF + TDL FIGURE): placed {len(ok_)}/{len(tdlstats)}, 0 px differing in "
              f"{sum(1 for d in ok_ if d == 0)}, worst {max(ok_ or [0])} px; p50 "
              f"{statistics.median([u for d, u in tdlstats if d is not None] or [0]) / 1000:.1f} ms")
    if pix:
        print(f"  pixels (CoreGraphics, 288 dpi): {sum(1 for d, v, t, e in pix if d == 0)}/{len(pix)} cases with 0 px "
              f"differing; worst {max(d for d, v, t, e in pix)} px ({max(v for d, v, t, e in pix)} visibly); "
              f"largest position difference where pixels differ {max([e for d, v, t, e in pix if d] or [0]):.4f} pt")


def pdf_pages_content(path):
    from pypdf import PdfReader
    return [c.get_data() if (c := pg.get_contents()) is not None else b"" for pg in PdfReader(path).pages]


def split_xdv_fragment(b):
    """The bop..eop pages in a fragment of an XDV stream."""
    import xdv
    out, i = [], 0
    while True:
        j = b.find(b"\x8b", i)  # bop
        if j < 0:
            return out
        try:
            pg = xdv.pages(b"\xf7\x07" + b"\0" * 12 + b"\0" + b[j:])
        except (ValueError, IndexError):
            i = j + 1
            continue
        if pg:
            return pg
        i = j + 1


def prelude(engine, src, main):
    """The --hook command line (ship hook + the pass's macros) leaves the stock engine's output byte-identical
    (LuaTeX: but /ID, which hashes the path; both runs here use the same path)."""
    name = os.path.basename(os.path.abspath(src))
    base = settle(engine, src, main, name)
    out = f"{WORK}/pre-out"
    shutil.rmtree(out, ignore_errors=True)
    live = Live(engine, base, main, out, "--hook")
    live.until(lambda e: e["ev"] == "done")
    live.close()
    argv = open(f"{out}/t/cmdline", "rb").read().rstrip(b"\0").split(b"\0")
    ext = ENGINES[engine][1]
    run = f"{WORK}/pre-run"
    outs = []
    for args in (None, argv[1:]):
        copy(base, run)
        cmdl = cmd(engine, main, USTOCK) if args is None else [f"{USTOCK}/{ENGINES[engine][0][0]}", *[a.decode() for a in args]]
        subprocess.run(cmdl, cwd=run, env=stock_env(), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
        outs.append(open(f"{run}/{stem(main)}.{ext}", "rb").read())
    ok = outs[0] == outs[1]
    print(f"prelude {engine} {name}: {'identical' if ok else 'DIFFERENT'} ({len(argv[-1])} bytes of command line)")
    return ok


DERIVED = (".aux", ".bbl", ".blg", ".out", ".toc", ".lof", ".lot", ".log", ".pdf", ".xdv", ".synctex", ".fls", ".nav",
           ".snm", ".idx", ".ind", ".ilg", ".bcf", ".run.xml", ".fdb_latexmk")


_bib_last = {}


def bib_files_exist(d, aux):
    """latexmk's -bibtex-cond: BibTeX only when every database \\bibdata names is in the project."""
    names = [n for m in re.finditer(rb"\\bibdata\{([^}]*)\}", aux) for n in m.group(1).decode().split(",")]
    return bool(names) and all(os.path.exists(f"{d}/{n}.bib") or (n.endswith(".bib") and os.path.exists(f"{d}/{n}"))
                               for n in names)


def stock_rule(engine, d, main):
    """Stock runs as latexmk would: BibTeX when the bib lines change, reruns until the .aux stops changing."""
    st = stem(main)
    aux = open(f"{d}/{st}.aux", "rb").read() if os.path.exists(f"{d}/{st}.aux") else None
    for n in range(1, 6):
        run_stock(engine, d, main)
        a = open(f"{d}/{st}.aux", "rb").read() if os.path.exists(f"{d}/{st}.aux") else b""
        bl = b"\n".join(l for l in a.split(b"\n") if l.startswith((b"\\citation", b"\\bibdata", b"\\bibstyle")))
        bib = b"\\bibdata" in a and bl != _bib_last.get(d) and bib_files_exist(d, a)
        if bib:
            bbl = f"{d}/{st}.bbl"
            before = open(bbl, "rb").read() if os.path.exists(bbl) else None
            subprocess.run([f"{USTOCK}/bibtex", st], cwd=d, env=stock_env(), stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
            _bib_last[d] = bl
            after = open(bbl, "rb").read() if os.path.exists(bbl) else None
            if after == before and a == aux:
                break  # BibTeX changed nothing and the .aux has settled
        if a == aux and not bib:
            break
        aux = a
    return n


def rule(engine, src, main):
    """latexmk's rule in tau-live: from a project with no .aux/.bbl, the settled output == stock runs with BibTeX
    (pdflatex, bibtex, then reruns until the .aux stops changing, at most 5), and the events in order."""
    name = os.path.basename(os.path.abspath(src))
    clean = f"{WORK}/rule-{name}-src"
    copy(src, clean)
    shipped_bbl = not any(f.endswith(".bib") for f in os.listdir(clean))  # (arXiv sources: the .bbl is the source)
    for f in os.listdir(clean):
        if f.endswith(DERIVED) and not (shipped_bbl and f.endswith(".bbl")):
            os.remove(f"{clean}/{f}")
    # the reference
    ref = f"{WORK}/rule-{name}-ref"
    copy(clean, ref)
    st = stem(main)
    ext = ENGINES[engine][1]
    runs, aux = 0, None
    bib_lines_last = None
    for runs in range(1, 6):
        run_stock(engine, ref, main)
        a = open(f"{ref}/{st}.aux", "rb").read() if os.path.exists(f"{ref}/{st}.aux") else b""
        bl = b"\n".join(l for l in a.split(b"\n") if l.startswith((b"\\citation", b"\\bibdata", b"\\bibstyle")))
        bib_changed = b"\\bibdata" in a and bl != bib_lines_last
        if bib_changed:
            subprocess.run([f"{USTOCK}/bibtex", st], cwd=ref, env=stock_env(), stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)
            bib_lines_last = bl
        if a == aux and not bib_changed:
            break
        aux = a
    want = open(f"{ref}/{st}.{ext}", "rb").read()
    # tau-live
    out = f"{WORK}/rule-out"
    shutil.rmtree(out, ignore_errors=True)
    t = time.monotonic()
    live = Live(engine, clean, main, out, "--hook")
    done = live.until(lambda e: e["ev"] == "done", timeout=300)
    el = (time.monotonic() - t) * 1000
    live.close()
    got = open(done["path"], "rb").read()
    evs = [e["ev"] + (f"({e.get('why')},{e.get('run')})" if e["ev"] == "run" else
                      f"({e.get('tool')})" if e["ev"] == "bibtex" else "") for e in live.events
           if e["ev"] in ("run", "bibtex", "done")]
    ok = same_output(engine, got, want)
    print(f"rule {engine} {name}: {'identical' if ok else 'DIFFERENT'} to stock + BibTeX ({runs} stock runs); "
          f"tau-live {done['runs']} runs, {el:.0f} ms; events {' '.join(evs)}")
    return ok


def serve(engine, src, main):
    """The app's form and protocol: --serve --engine PATH DIR MAIN OUT; --state across sessions; goal; finish; rescan."""
    name = os.path.basename(os.path.abspath(src))
    clean = f"{WORK}/serve-{name}-src"
    copy(src, clean)
    shipped_bbl = not any(f.endswith(".bib") for f in os.listdir(clean))  # (arXiv sources: the .bbl is the source)
    for f in os.listdir(clean):
        if f.endswith(DERIVED) and not (shipped_bbl and f.endswith(".bbl")):
            os.remove(f"{clean}/{f}")
    state = f"{WORK}/serve-state"
    shutil.rmtree(state, ignore_errors=True)
    env = dict(os.environ)
    env.pop("TAU_FETCH", None)
    env.pop("TEXSTORE_URL", None)

    def start(out):
        shutil.rmtree(out, ignore_errors=True)
        lv = Live.__new__(Live)
        lv.events = []
        lv.p = subprocess.Popen([f"{UBIN}/tau-live", "--serve", "--engine", f"{UBIN}/{ENGINES[engine][0][0]}", "--state",
                                 state, clean, main, out], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                                env=env)
        return lv

    res = []
    lv = start(f"{WORK}/serve-out1")
    hello = lv.until(lambda e: e["ev"] == "hello")
    d1 = lv.until(lambda e: e["ev"] == "done", timeout=300)
    res.append(f"session 1: {d1['runs']} runs, bibtex {'yes' if any(e['ev'] == 'bibtex' for e in lv.events) else 'no'}, "
               f"blg {'yes' if 'blg' in d1 else 'no'}, synctex {'yes' if any(e.get('synctex') for e in lv.events) else 'no'}")
    # goal + an edit: the first PDF after it should be the edit's page, then finish asks for one now
    text = open(f"{clean}/{main}", "rb").read()
    pos = text.find(b"\\section", text.find(b"\\begin{document}")) + 200
    lv.send("goal", 2)
    lv.send("change", main, pos, 0, "word ")
    run = lv.until(lambda e: e["ev"] == "run")
    lv.send("finish")
    first = lv.until(lambda e: e["ev"] in ("pdf", "done") and e.get("seq") == run["seq"])
    res.append(f"edit: first output {first['ev']} {first.get('pages')} pages after {first.get('edit_us', 0) / 1000:.0f} ms")
    lv.until(lambda e: e["ev"] == "done" and e["seq"] == run["seq"], timeout=300)
    # rescan: a .bib changed on disk
    bibs = [f for f in os.listdir(clean) if f.endswith(".bib")]
    if bibs:
        with open(f"{clean}/{bibs[0]}", "a") as f:
            f.write("\n@misc{taudotextra, title={Extra}, year={2026}}\n")
        lv.send("rescan")
        r2 = lv.until(lambda e: e["ev"] in ("run", "bibtex", "done"), timeout=60)
        res.append(f"rescan after a .bib change: {r2['ev']} {r2.get('tool', r2.get('why', ''))}")
        lv.until(lambda e: e["ev"] == "done", timeout=300)
    lv.p.stdin.close()
    lv.p.wait(20)
    # session 2 with the kept state: no BibTeX, one run
    lv = start(f"{WORK}/serve-out2")
    d2 = lv.until(lambda e: e["ev"] == "done", timeout=300)
    res.append(f"session 2 (--state): {d2['runs']} runs, bibtex "
               f"{'yes' if any(e['ev'] == 'bibtex' for e in lv.events) else 'no'}")
    lv.p.stdin.close()
    lv.p.wait(20)
    print(f"serve {engine} {name}: hello {hello}\n  " + "\n  ".join(res))


def xpdf(engine, src, main, n=40, seed=5):
    """XeTeX's pages as PDF in tau-live (tau-pdfmx): typing as in `typing`; every pdf event's pdf_path must be the
    bytes stock xdvipdfmx makes of that event's XDV with the same arguments; times: edit -> PDF pages ready."""
    name = os.path.basename(os.path.abspath(src))
    base = settle(engine, src, main, name)
    out = f"{WORK}/x-out"
    shutil.rmtree(out, ignore_errors=True)
    rng = random.Random(seed)
    text = open(f"{base}/{main}", "rb").read()
    lo = text.find(b"\\begin{document}")
    live = Live(engine, base, main, out, "--hook")
    live.send("goal", 0)
    live.until(lambda e: e["ev"] == "done")
    pos = [m.end() for m in re.finditer(rb"[a-z]{4,}\. ", text[lo:])]
    sentence = "Typing goes here, one key at a time, as a user would. "
    checked = same = 0
    first_ms, conv_ms, ready_ms, final_conv = [], [], [], []
    shown = []  # the client's pages, as the protocol says to keep them: (PDF, its page)
    seen = 0
    pix = []

    def apply(e):
        if "pdf_first" not in e:
            return
        f, l = e["pdf_first"], e["pdf_last"]
        for k in range(f, l + 1):
            if k < len(shown):
                shown[k] = (e["pdf_path"], k - f)
            else:
                shown.append((e["pdf_path"], k - f))
        if e.get("final"):
            del shown[e["pages"]:]

    def compare(final_xdv):
        """Every page the client shows against a whole-document xdvipdfmx of the final XDV, drawn (pixels.py)."""
        import pixels
        ref = f"{out}/ref-all.pdf"
        subprocess.run([f"{UBIN}/xdvipdfmx", "-q", "-z", "1", "-o", ref, final_xdv], cwd=f"{out}/work", check=True)
        rb = open(ref, "rb").read()
        import pikepdf
        boxes = [tuple(float(v) for v in pg.mediabox) for pg in pikepdf.open(ref).pages]
        bad = 0
        for k, (path, i) in enumerate(shown):
            a = pixels.render(open(path, "rb").read(), i, boxes[k])[0]
            b = pixels.render(rb, k, boxes[k])[0]
            bad += a != b
        pix.append((len(shown) - bad, len(boxes), len(shown)))

    def check(e):
        nonlocal checked, same
        if "pdf_path" not in e:
            return
        mine = open(e["pdf_path"], "rb").read()
        os.remove(e["pdf_path"])  # the stock run writes the same name (the subset tags hash it)
        r = subprocess.run([f"{UBIN}/xdvipdfmx", "-q", "-z", "1", "-s", f"{e['pdf_first'] + 1}-{e['pdf_last'] + 1}", "-o",
                            e["pdf_path"], e["path"]], cwd=f"{out}/work", stdin=subprocess.DEVNULL)
        checked += 1
        same += r.returncode == 0 and open(e["pdf_path"], "rb").read() == mine

    for spot in range(n // 20):
        p = lo + rng.choice(pos)
        for i in range(20):
            time.sleep(0.12)
            live.send("change", main, p + i, 0, sentence[i])
            run = newer_run(live)
            e = live.until(lambda e: e["ev"] in ("pdf", "done") and e.get("seq") == run["seq"])
            if e["ev"] == "pdf" and "pdf_first" in e and "pdf_path" in e:
                first_ms.append(e["edit_us"] / 1000)
                conv_ms.append(e["pdfmx_us"] / 1000)
                ready_ms.append((e["edit_us"] + e["pdfmx_us"]) / 1000)
                check(e)
        done = live.until(lambda e: e["ev"] == "done" and e["seq"] == run["seq"])
        for e in live.events[seen:]:
            if e["ev"] == "pdf" and e.get("final") and "pdf_path" in e and e["seq"] != 0:
                final_conv.append((e["pdfmx_us"] / 1000, e["pdf_last"] + 1 - e["pdf_first"]))
                check(e)
            if e["ev"] == "pdf":
                apply(e)
        seen = len(live.events)
        compare(done["path"])
    # jumps: whole chunks at random spots that bring fonts not used before (XeTeX numbers fonts as it defines them,
    # so every later number shifts) and move page breaks
    chunks = [" \\textsc{Small Capitals Here} ", " \\texttt{monospaced words} \\textbf{\\textit{bold italic}} ",
              "\n\n\\begin{center}\\Huge A big line\\end{center}\n\n", " \\textsf{\\textbf{sans bold}} ",
              " \\fbox{\\scriptsize tiny boxed words} ", "\n\n" + "More text to push pages. " * 30 + "\n\n"]
    for j, c in enumerate(chunks):
        p = lo + rng.choice(pos)
        live.send("change", main, p, 0, c)
        run = newer_run(live)
        done = live.until(lambda e: e["ev"] == "done" and e["seq"] == run["seq"])
        for e in live.events[seen:]:
            if e["ev"] == "pdf" and "pdf_path" in e:
                check(e)
            if e["ev"] == "pdf":
                apply(e)
        seen = len(live.events)
        compare(done["path"])
    live.close()

    def pq(v):
        v = sorted(v)
        return f"p50 {statistics.median(v):.1f} p90 {v[min(len(v) - 1, int(.9 * len(v)))]:.1f} ms"

    print(f"xpdf {engine} {name}: {same}/{checked} PDFs identical to stock xdvipdfmx")
    for ok, n_ref, n_shown in pix:
        print(f"  after an edit: {ok}/{n_ref} pages the client shows draw identically to a whole-document xdvipdfmx"
              f"{'' if n_shown == n_ref else f' (client has {n_shown})'}")
    print(f"  per key: edit -> first exact XDV {pq(first_ms)}; its pages -> PDF {pq(conv_ms)}; edit -> PDF {pq(ready_ms)}")
    if final_conv:
        print(f"  final outputs: {len(final_conv)}, pages -> PDF {pq([c for c, _ in final_conv])} "
              f"({statistics.median([k for _, k in final_conv]):.0f} pages p50)")
    return same == checked and checked > 0 and all(ok == n == m for ok, n, m in pix)


def bigopen(engine, src, main):
    """Long command lines (the app's `open` of a whole file, a big paste): each is applied (no error, `applied`
    counts it), and the settled output equals a stock run of the same text. Also with the paragraph pass off."""
    name = os.path.basename(os.path.abspath(src))
    base = settle(engine, src, main, name)
    ok = True
    for opts in (["--hook"], ["--hook", "--no-para"]):
        out = f"{WORK}/bo-out"
        shutil.rmtree(out, ignore_errors=True)
        live = Live(engine, base, main, out, *opts)
        live.until(lambda e: e["ev"] == "done")
        text = open(f"{base}/{main}", encoding="utf-8").read()
        lo = text.find("\\begin{document}") + 20
        filler = "\n\n" + ("Plain words to fill the line. " * 3500) + "\n\n"  # ~100 KB
        steps = [("open", text[:lo] + filler + text[lo:]), ("change", lo, len(filler), "x" * 100000),
                 ("open", text[:lo] + " Caf\u00e9 na\u00efve \u2014 \U0001d4b3 " + text[lo:])]
        applied = 0
        for k, st in enumerate(steps):
            if st[0] == "open":
                live.send("open", main, st[1])
                cur = st[1]
            else:
                live.send("change", main, st[1], st[2], st[3])
                cur = cur[:st[1]] + st[3] + cur[st[1] + st[2]:]
            applied += 1
            run = newer_run(live)
            done = live.until(lambda e: e["ev"] == "done" and e["seq"] == run["seq"])
            errs = [e for e in live.events if e["ev"] == "error" and e.get("what") == "protocol"]
            ref = f"{WORK}/bo-ref"
            copy(base, ref)
            open(f"{ref}/{main}", "w", encoding="utf-8").write(cur)
            stock_rule(engine, ref, main)
            ext = ENGINES[engine][1]
            same = same_output(engine, open(done["path"], "rb").read(), open(f"{ref}/{stem(main)}.{ext}", "rb").read())
            good = not errs and run["applied"] == applied and same
            ok &= good
            print(f"  {' '.join(opts)}: {st[0]} of {len(cur) if st[0] == 'open' else len(st[3])} chars: applied "
                  f"{run['applied']} (want {applied}), protocol errors {len(errs)}, output "
                  f"{'identical' if same else 'DIFFERENT'} to stock")
        live.close()
    print(f"bigopen {engine} {name}: {'ok' if ok else 'FAILED'}")
    return ok


def bblonly(engine, src, main):
    """A project that ships its .bbl and no .bib (arXiv sources): opened with no .aux, tau-live must not run BibTeX
    (it would replace the .bbl with an empty one), every citation resolves, and the output equals stock runs."""
    name = os.path.basename(os.path.abspath(src))
    clean = f"{WORK}/bbl-{name}-src"
    copy(src, clean)
    if any(f.endswith(".bib") for f in os.listdir(clean)):
        sys.exit(f"{src} has a .bib: this check needs a project with only its .bbl")
    st = stem(main)
    for f in os.listdir(clean):
        if f.endswith(DERIVED) and not f.endswith(".bbl"):
            os.remove(f"{clean}/{f}")
    bbl = open(f"{clean}/{st}.bbl", "rb").read()
    out = f"{WORK}/bbl-out"
    shutil.rmtree(out, ignore_errors=True)
    env = dict(os.environ)
    env.pop("TAU_FETCH", None)
    lv = Live.__new__(Live)
    lv.events = []
    lv.p = subprocess.Popen([f"{UBIN}/tau-live", "--serve", "--engine", f"{UBIN}/{ENGINES[engine][0][0]}", clean, main,
                             out], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
    done = lv.until(lambda e: e["ev"] == "done", timeout=300)
    lv.p.stdin.close()
    lv.p.wait(20)
    tools = [e.get("tool") for e in lv.events if e["ev"] == "bibtex"]
    ran = any("bibtex" in (t or "") for t in tools)
    kept = open(f"{out}/work/{st}.bbl", "rb").read() == bbl
    log = open(done["log"], "rb").read() if done.get("log") else b""
    undefined = len(re.findall(rb"Citation `[^']*' (?:on page \d+ )?undefined", log))
    ref = f"{WORK}/bbl-ref"
    copy(clean, ref)
    stock_rule(engine, ref, main)
    ext = ENGINES[engine][1]
    same = same_output(engine, open(done["path"], "rb").read(), open(f"{ref}/{st}.{ext}", "rb").read())
    ok = not ran and kept and undefined == 0 and same
    print(f"bblonly {engine} {name}: BibTeX {'RAN' if ran else 'not run'}, .bbl {'kept' if kept else 'CHANGED'}, "
          f"undefined citations {undefined}, output {'identical' if same else 'DIFFERENT'} to stock "
          f"({done['runs']} runs): {'ok' if ok else 'FAILED'}")
    return ok


def parked(engine, src, main, n=3):
    """The parked engine (tau-live --park): N sessions forked from it open SRC (no .aux) and settle; each output equals
    an unparked session's byte for byte; open -> done for both; and a session started differently (another TEXINPUTS)
    is spawned as usual."""
    name = os.path.basename(os.path.abspath(src))
    clean = f"{WORK}/park-{name}-src"
    copy(src, clean)
    shipped_bbl = not any(f.endswith(".bib") for f in os.listdir(clean))
    for f in os.listdir(clean):
        if f.endswith(DERIVED) and not (shipped_bbl and f.endswith(".bbl")):
            os.remove(f"{clean}/{f}")
    sock = f"{os.environ.get('TMPDIR', '/tmp')}/tau-park-test-{engine}.sock"  # (a Unix socket's path: <= 103 bytes)
    env = dict(os.environ)
    env.pop("TAU_FETCH", None)
    eng = f"{UBIN}/{ENGINES[engine][0][0]}"
    pk = subprocess.Popen([f"{UBIN}/tau-live", "--park", sock, "--serve", "--engine", eng], stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, text=True, env=env)
    print(f"  parked: {pk.stdout.readline().strip()}")

    def session(opts, env2):
        out = f"{WORK}/park-out"
        shutil.rmtree(out, ignore_errors=True)
        log = f"{WORK}/park-live.log"
        t0 = time.monotonic()
        lv = Live.__new__(Live)
        lv.events = []
        lv.p = subprocess.Popen([f"{UBIN}/tau-live", *opts, "--serve", "--engine", eng, clean, main, out],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                                env=dict(env2, TAU_LIVE_LOG=log))
        done = lv.until(lambda e: e["ev"] == "done", timeout=600)
        ms = (time.monotonic() - t0) * 1000
        data = open(done["path"], "rb").read()
        lv.p.stdin.close()
        lv.p.wait(20)
        how = "parked" if "from the parked engine" in open(log).read() else "spawned"
        return data, ms, how

    ref, ms_ref, _ = session([], env)
    ok, times = True, []
    for k in range(n):
        data, ms, how = session(["--parked", sock], env)
        same = data == ref
        ok &= same and how == "parked"
        times.append(ms)
        print(f"  session {k}: {how}, open -> done {ms:.0f} ms, output {'identical' if same else 'DIFFERENT'}")
    _, ms_o, how = session(["--parked", sock], dict(env, TEXINPUTS=".:"))
    ok &= how == "spawned"
    print(f"  started differently (TEXINPUTS): {how}")
    pk.stdin.close()
    pk.wait(20)
    print(f"parked {engine} {name}: unparked {ms_ref:.0f} ms, parked p50 {statistics.median(times):.0f} ms: "
          f"{'ok' if ok else 'FAILED'}")
    return ok


def display(engine, src, main, n=40, seed=3):
    """Display pages (tau-tdl page): typing as in `typing`, then keys bringing characters the document doesn't use.
    Each display page against the same run's finished output, page for page, drawn at 288 dpi (every pixel counts);
    a key whose page needs a glyph the last finished output lacks must get no display page."""
    import pixels
    name = os.path.basename(os.path.abspath(src))
    base = settle(engine, src, main, name)
    out = f"{WORK}/d-out"
    shutil.rmtree(out, ignore_errors=True)
    rng = random.Random(seed)
    text = open(f"{base}/{main}", "rb").read()
    lo = text.find(b"\\begin{document}")
    live = Live(engine, base, main, out, "--hook")
    live.send("goal", 0)
    live.until(lambda e: e["ev"] == "done")
    pos = [m.end() for m in re.finditer(rb"[a-z]{4,}\. ", text[lo:])]
    keys = list("Typing goes here, one key at a time. ") * (n // 37 + 1)
    novel = ["\\textsuperscript{\\textcircled{z}}", "\\L{}\\o{}\\ae{}", "$\\aleph\\wp$"]
    checked = same = shown = refused_ok = 0
    worst = 0
    t_disp, t_first = [], []

    def key(p, ch, expect_refusal=False):
        nonlocal checked, same, shown, refused_ok, worst
        live.send("change", main, p, 0, ch)
        run = newer_run(live)
        done = live.until(lambda e: e["ev"] == "done" and e["seq"] == run["seq"])
        evs = [e for e in live.events if e["ev"] == "pdf" and e["seq"] == run["seq"]]
        disp = [e for e in evs if e.get("display")]
        real = [e for e in evs if not e.get("display")]
        if evs:
            t_first.append(evs[0]["edit_us"] / 1000)
        if expect_refusal and not disp:
            refused_ok += 1
            return len(ch)
        if not disp or not real:
            return len(ch)
        d = disp[0]
        shown += 1
        t_disp.append(d["edit_us"] / 1000)
        k = d["from_page"]
        ref = next((e for e in real if e["pages"] > k), done if done.get("path") else None)
        if not ref:
            return len(ch)
        a, b = open(d["path"], "rb").read(), open(ref["path"], "rb").read()
        H = pixels.page_height(b, k)
        import pikepdf
        with pikepdf.open(ref["path"]) as doc:
            w = float(doc.pages[k].mediabox[2])
        ra = pixels.render(a, k, (0, 0, w, H))[0]
        rb = pixels.render(b, k, (0, 0, w, H))[0]
        diff = sum(1 for i in range(0, len(ra), 4) if ra[i:i + 3] != rb[i:i + 3])
        checked += 1
        same += diff == 0
        worst = max(worst, diff)
        return len(ch)

    for spot in range(n // 20):
        p = lo + rng.choice(pos)
        for i in range(20):
            time.sleep(0.12)
            p += key(p, keys[spot * 20 + i])
    # characters the document may not draw yet: no display page when the font subsets lack them, else (the glyph is
    # drawn somewhere already) a page that draws identically
    novel += ["\\symbol{\"2603}", "\\symbol{\"0416}\\symbol{\"03A8}"] if engine != "pdflatex" else []
    for c in novel:
        p = lo + rng.choice(pos)
        key(p, " " + c + " ", expect_refusal=True)
    live.close()
    print(f"display {engine} {name}: {shown} display pages for {n} keys; {same}/{checked} draw identically to the "
          f"run's finished page (288 dpi, worst {worst} px); keys with new characters: {refused_ok}/{len(novel)} refused, the others checked above")
    if t_disp:
        print(f"  edit -> display page p50 {statistics.median(t_disp):.1f} ms; edit -> first output p50 "
              f"{statistics.median(t_first):.1f} ms")
    return same == checked and refused_ok > 0


if __name__ == "__main__":
    if sys.argv[1:2] == ["serve"]:
        serve(*sys.argv[2:5])
        sys.exit(0)
    if sys.argv[1:2] == ["rule"]:
        sys.exit(0 if rule(*sys.argv[2:5]) else 1)
    if sys.argv[1:2] == ["prelude"]:
        sys.exit(0 if prelude(*sys.argv[2:5]) else 1)
    if sys.argv[1:2] == ["paragraph"]:
        paragraph(*sys.argv[2:5], *(int(x) for x in sys.argv[5:6]))
        sys.exit(0)
    if sys.argv[1:2] == ["display"]:
        sys.exit(0 if display(*sys.argv[2:5]) else 1)
    if sys.argv[1:2] == ["parked"]:
        sys.exit(0 if parked(*sys.argv[2:5]) else 1)
    if sys.argv[1:2] == ["bblonly"]:
        sys.exit(0 if bblonly(*sys.argv[2:5]) else 1)
    if sys.argv[1:2] == ["bigopen"]:
        sys.exit(0 if bigopen(*sys.argv[2:5]) else 1)
    if sys.argv[1:2] == ["xpdf"]:
        sys.exit(0 if xpdf(*sys.argv[2:5], *(int(x) for x in sys.argv[5:6])) else 1)
    if sys.argv[1:2] == ["typing"]:
        typing(*sys.argv[2:5], *(int(x) for x in sys.argv[5:6]))
        sys.exit(0)
    if a := sys.argv[1:2] == ["finish"] and sys.argv[2:]:
        sys.exit(0 if finish(*a[:3], *(int(x) for x in a[3:4])) else 1)
    a = sys.argv[1:]
    if a[:1] == ["exact"]:
        sys.exit(0 if exact(*a[1:4]) else 1)
    if a[:1] == ["edits"]:
        sys.exit(0 if edits(*a[1:4], *(int(x) for x in a[4:5])) else 1)
    print(__doc__ if __doc__ else "see the header", file=sys.stderr)
    sys.exit(2)
