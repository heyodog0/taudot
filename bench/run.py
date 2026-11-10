# AGPL-3.0-or-later. Run the fixed edit script against one live-typesetting system and write raw TSV rows.
#
#   uv run bench/run.py SYSTEM DOC ENGINE        e.g.  latexmk synth-100 pdflatex
#   uv run bench/run.py all [--docs ...]          every system on every document it supports
#
# Measures (defined in docs/bench.md): first compile, edit -> paragraph preview, edit -> exact page,
# edit -> whole exact PDF, peak memory. latexmk runs first on each document: its output after every edit is the
# stock reference the other systems' pages and PDFs are checked against.
import argparse
import json
import os
import queue
import re
import shutil
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import (TL_ROOT, BUILD, REPO, TAU_BIN, DOCS, LATEXMK, PDFTEX_BUILD, RESULTS, SRC, UBIN, USTOCK, WORK, TreeRSS, copy, git_rev, log,  # noqa
                    page_count, run_stock, same_file, same_pages, stem, tex_env)

TIMEOUT = 300  # s, per edit
REST = 0.3  # s between edits, after the previous one settled


def load(doc):
    return json.load(open(f"{DOCS}/{doc}/edits.json"))


def script(meta, variant):
    """The edit script: (n, spot, file, byte offset, key). Offsets already account for earlier keys."""
    v = meta["variants"][variant]
    keys = meta["keys"]
    out, typed = [], []  # typed: (offset, length) of text inserted so far, in the file's current coordinates
    n = 0
    for s, pos in enumerate(v["spots"]):
        p = pos + sum(l for o, l in typed if o <= pos)
        for j, c in enumerate(keys):
            n += 1
            out.append((n, s, v["file"], p + j, c))
        typed.append((pos, len(keys)))
    return out


def apply(path, pos, ins):
    b = open(path, "rb").read()
    open(path, "wb").write(b[:pos] + ins.encode() + b[pos:])


def line_of(path, pos):
    return open(path, "rb").read()[:pos].count(b"\n") + 1


def synctex_page(path, file, line):
    """The last page (0-based) holding a record of FILE:LINE in a plain SyncTeX file, or None."""
    if not os.path.exists(path):
        return None
    tags, page, pages = set(), -1, set()
    with open(path, "rb") as f:
        for raw in f:
            if raw.startswith(b"Input:"):
                _, tag, p = raw.decode(errors="replace").rstrip("\n").split(":", 2)
                if os.path.normpath(p).endswith(os.path.normpath(file)):
                    tags.add(tag.encode())
            elif raw.startswith(b"{"):
                page = int(raw[1:]) - 1
            elif raw[:1] in b"[(hvxkg$" and b"," in raw:
                t, _, rest = raw[1:].partition(b",")
                if t in tags and rest.split(b":", 1)[0] == str(line).encode():
                    pages.add(page)
    return max(pages) if pages else None


# ---------------------------------------------------------------------------------------------- systems
class System:
    name = "?"
    engines = ()
    exact_kind = "pdf"

    def version(self):
        return ""


class Latexmk(System):
    """Stock latexmk with TeX Live's own engines: every edit saved, then one latexmk run (its -pvc polling delay
    left out). Its outputs are the references."""
    name = "latexmk"
    engines = ("pdflatex", "xelatex", "lualatex")

    def version(self):
        v = subprocess.run(["perl", LATEXMK, "-v"], capture_output=True, text=True).stdout
        return " ".join(v.split()[:8]).strip()

    def argv(self, engine, main):
        sync = "-synctex=-1"
        if engine == "pdflatex":
            e = [f"-pdflatex={USTOCK}/pdflatex -interaction=batchmode {sync} %O %S", "-pdf"]
        elif engine == "xelatex":
            e = [f"-xelatex={USTOCK}/xelatex -no-pdf -interaction=batchmode {sync} %O %S",
                 "-e", f"$xdvipdfmx = '{UBIN}/xdvipdfmx -q -E -o %D %O %S'", "-xelatex"]
        else:
            e = [f"-lualatex={USTOCK}/lualatex -interaction=batchmode {sync} %O %S", "-lualatex"]
        return ["perl", LATEXMK, *e, f"-bibtex-cond", "-silent", main]

    def compile(self, proj, engine, main):
        e = tex_env()
        e["PATH"] = f"{USTOCK}:{e['PATH']}"
        t = time.monotonic()
        r = subprocess.run(self.argv(engine, main), cwd=proj, env=e, stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        if r.returncode:
            log(f"  latexmk exit {r.returncode}: {r.stderr[-500:]}")
        return (time.monotonic() - t) * 1000


class TaudotDriver(System):
    """A driver speaking docs/live-protocol.md: pdftex-live --serve (patched pdfTeX) or tau-live --serve."""

    def __init__(self):
        self.q = queue.Queue()

    def start(self, proj, engine, main, out):
        self.out = out
        self.keep = f"{out}-keep"
        shutil.rmtree(self.keep, ignore_errors=True)
        os.makedirs(self.keep)
        self.p = subprocess.Popen(self.argv(proj, engine, main, out), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=open(f"{out}.stderr", "w"), env=self.env(), text=True, bufsize=1)
        self.t0 = time.monotonic()
        threading.Thread(target=self.reader, daemon=True).start()
        self.applied = 0
        self.nkeep = 0

    def reader(self):
        for line in self.p.stdout:
            t = time.monotonic()
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            for k in ("path", "overlay", "pdf_path"):  # driver files are reused after a few newer ones: keep a link
                if ev.get(k) and ev["ev"] in ("pdf", "para") and os.path.exists(ev[k]):
                    self.nkeep += 1
                    dst = f"{self.keep}/{self.nkeep}-{os.path.basename(ev[k])}"
                    try:
                        os.link(ev[k], dst)
                        ev["kept_" + k] = dst
                    except OSError:
                        pass
            self.q.put((t, ev))
        self.q.put((time.monotonic(), {"ev": "eof"}))

    def next(self, timeout=TIMEOUT):
        t, ev = self.q.get(timeout=timeout)
        if ev["ev"] == "eof":
            raise RuntimeError(f"{self.name} exited")
        return t, ev

    def send(self, *c):
        self.p.stdin.write(json.dumps(list(c)) + "\n")
        self.p.stdin.flush()

    def first(self):
        """Open -> first PDF, open -> done (the settled first compile)."""
        r = {"first_page_ms": None}
        while True:
            t, ev = self.next()
            if ev["ev"] == "pdf" and r["first_page_ms"] is None:
                r["first_page_ms"] = (t - self.t0) * 1000
            if ev["ev"] == "error":
                log(f"  {self.name}: error {ev}")
            if ev["ev"] == "done":
                r["done_ms"] = (t - self.t0) * 1000
                r["pages"] = ev.get("pages")
                self.last_seq = ev.get("seq", 0)
                return r

    def edit(self, file, pos, key, page):
        if page is not None:
            self.send("goal", page)
        t0 = time.monotonic()
        self.send("change", file, pos, 0, key)
        self.applied += 1
        n = self.applied
        r = blank()
        seq = None
        while True:
            t, ev = self.next()
            ms = (t - t0) * 1000
            k = ev["ev"]
            if k == "para" and ev.get("applied", 0) >= n and r["para_state"] == "":
                r["para_state"] = ev.get("state", "") + (f"/{ev['why']}" if ev.get("why") else "")
                if ev.get("state") in ("exact", "provisional") and ev.get("path"):
                    r["para_ms"], r["self_ms"] = ms, ev.get("us", 0) / 1000 or None
            elif k == "run" and ev.get("applied", 0) >= n and seq is None:
                seq = ev["seq"]
            elif k == "pdf" and ev.get("display") and ev.get("applied", 0) >= n and r.get("display_ms") is None:
                # tau-live's display page: the last finished PDF with the run's first page drawn anew
                r["display_ms"], r["display_pdf"], r["display_page"] = ms, ev.get("kept_path"), ev.get("from_page", 0)
            elif k == "pdf" and not ev.get("display") and ev.get("applied", 0) >= n and r["page_ms"] is None:
                if page is None or ev.get("final") or ev.get("pages", 0) > page:
                    r["page_ms"], r["early"] = ms, ev.get("kept_path")
                    r["early_pages"], r["early_from"] = ev.get("pages"), ev.get("from_page", 0)
                    if "pdf_first" in ev:  # XeTeX through tau-pdfmx: the changed pages as a PDF
                        r["early_pdf"], r["pdf_first"], r["pdf_last"] = ev.get("kept_pdf_path"), ev["pdf_first"], \
                            ev["pdf_last"]
                        r["pdf_path"], r["xdv_path"] = ev.get("pdf_path"), ev.get("path")
                        r["xdvipdfmx_ms"] = ev.get("pdfmx_us", 0) / 1000
            elif k == "done" and (seq is None or ev.get("seq", -1) >= seq) and ev.get("seq", -1) > self.last_seq:
                self.last_seq = ev["seq"]
                r["final_ms"] = ms
                r["final"] = self.kept_final(ev)
                r["para_state"] = r["para_state"] or "no event"
                return r
            elif k == "error":
                log(f"  {self.name}: error {ev}")

    def kept_final(self, ev):
        p = ev.get("path")
        if not p:
            return None
        for f in sorted(os.listdir(self.keep), key=lambda f: -int(f.split("-")[0])):
            if f.split("-", 1)[1] == os.path.basename(p):
                return f"{self.keep}/{f}"
        return p if os.path.exists(p) else None

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(20)
        except Exception:
            self.p.kill()


class PdftexLive(TaudotDriver):
    name = "taudot-pdftex"
    engines = ("pdflatex",)

    def version(self):
        return "pdftex-live " + git_rev(REPO)

    def env(self):
        e = tex_env(fmt=f"{BUILD}/fmt-pdftex")
        e["TEXSTORE_URL"] = "https://texlive.taudot.app"
        return e

    def argv(self, proj, engine, main, out):
        return [f"{BUILD}/pdftex-live", "--serve", "--engine", f"{PDFTEX_BUILD}/texk/web2c/pdflatex",
                "--bibtex", f"{USTOCK}/bibtex", proj, main, out]


class TauLive(TaudotDriver):
    name = "taudot-universal"
    engines = ("pdflatex", "xelatex", "lualatex")

    def version(self):
        return "tau-live " + git_rev(REPO)

    def env(self):
        e = tex_env()
        if os.environ.get("TAU_LIVE_LOG"):  # the driver's debug log, for a look
            e["TAU_LIVE_LOG"] = os.environ["TAU_LIVE_LOG"]
        return e

    def argv(self, proj, engine, main, out):
        return [f"{TAU_BIN}/tau-live", "--serve", "--engine", f"{UBIN}/{engine}", "--bibtex", f"{UBIN}/bibtex", proj,
                main, out]



# ---------------------------------------------------------------------------------------------- the others
TL_BIN = f"{BUILD}/tl/bin/aarch64-darwin"  # stock engines, kpsewhich, synctex, xdvipdfmx in TeX Live's layout
RTEX = f"{BUILD}/bin/rtex"  # built from SRC/realtime-tex, target/ removed after
TYPST = f"{BUILD}/bin/typst"  # built from SRC/typst at v0.15.1
TXP = f"{BUILD}/txp/txp-headless"
ROSINA = f"{SRC}/liveTeX-Rosina/build/livetex-rosina"


def tl_env():
    e = tex_env()
    e["PATH"] = f"{TL_BIN}:{e['PATH']}"
    return e


class External(System):
    """A process whose lines (stdout, or stderr) are read with a timestamp on a thread."""
    read_stderr = False

    def start(self, proj, engine, main, out):
        self.proj, self.engine, self.main, self.out = proj, engine, main, out
        self.keep = f"{out}-keep"
        shutil.rmtree(self.keep, ignore_errors=True)
        os.makedirs(self.keep)
        err = subprocess.STDOUT if self.read_stderr else open(f"{out}.stderr", "w")
        self.p = subprocess.Popen(self.argv(), cwd=proj, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err,
                                  env=self.env(), bufsize=0)
        self.q = queue.Queue()
        self.t0 = time.monotonic()
        threading.Thread(target=self.reader, daemon=True).start()

    def env(self):
        return tl_env()

    def reader(self):
        for line in iter(self.p.stdout.readline, b""):
            t = time.monotonic()
            ev = self.parse(line.decode(errors="replace"))
            if ev is not None:
                self.on_event(ev)
                self.q.put((t, ev))
        self.q.put((time.monotonic(), None))

    def on_event(self, ev):
        pass

    def parse(self, line):
        try:
            return json.loads(line)
        except ValueError:
            return None

    def next(self, timeout=TIMEOUT):
        t, ev = self.q.get(timeout=timeout)
        if ev is None:
            raise RuntimeError(f"{self.name} exited")
        return t, ev

    def send(self, obj):
        self.p.stdin.write((json.dumps(obj) + "\n").encode())
        self.p.stdin.flush()

    def close(self):
        try:
            self.p.stdin.close()
        except OSError:
            pass
        try:
            self.p.terminate()
            self.p.wait(20)
        except Exception:
            self.p.kill()


def blank(**kw):
    r = {"para_ms": None, "para_state": "", "page_ms": None, "early": None, "early_pages": None, "early_from": None,
         "final_ms": None, "final": None, "self_ms": None}
    r.update(kw)
    return r


class Rtex(External):
    """rtex serve (LuaLaTeX only). Each edit is followed by request_layout (no 300 ms debounce) and export_pdf
    (a clean LuaLaTeX build, the stock-identical PDF)."""
    name = "rtex"
    engines = ("lualatex",)

    def version(self):
        return subprocess.run([RTEX, "--version"], capture_output=True, text=True).stdout.strip() + " " + \
            git_rev(f"{SRC}/realtime-tex")

    def env(self):
        e = tl_env()
        e["RTEX_TEXLIVE_BIN"] = TL_BIN
        return e

    def argv(self):
        return [RTEX, "serve", "--project", self.proj, "--main", self.main]

    def first(self):
        while True:
            t, ev = self.next()
            if ev.get("event") == "LayoutUpdate":
                self.rev = ev["versions"]["source_revision"]
                self.n = 0
                ms = (t - self.t0) * 1000
                return {"first_page_ms": ms, "done_ms": ms, "pages": ev.get("pages_total")}

    def edit(self, file, pos, key, page):
        self.n += 1
        want = self.rev + self.n
        pdf = f"{self.keep}/export-{self.n}.pdf"
        t0 = time.monotonic()
        self.send({"cmd": "edit", "path": file, "start": pos, "end": pos, "text": key})
        r = blank(page_exact="claim")
        asked = False
        while r["page_ms"] is None or r["final_ms"] is None:
            # the layout and the export are asked for once the paragraph is in (or won't come), so they don't
            # compete with it; their times still count from the edit
            if not asked and r["para_state"]:
                self.send({"cmd": "request_layout"})
                self.send({"cmd": "export_pdf", "out": pdf})
                asked = True
            try:
                t, ev = self.next(timeout=2 if not asked else TIMEOUT)
            except queue.Empty:
                r["para_state"] = "no event"  # nothing for the paragraph in 2 s
                continue
            ms, k = (t - t0) * 1000, ev.get("event") or ev.get("reply")
            if k == "ParagraphUpdate" and r["para_state"] == "":
                st = ev.get("status")
                if st in ("ok", "ok_degraded"):
                    exact = st == "ok" and not ev.get("pagination_stale") and not ev.get("context_stale")
                    r["para_ms"], r["para_state"] = ms, "exact" if exact else "provisional"
                    r["self_ms"] = (ev.get("timing") or {}).get("total_us", 0) / 1000 or None
                else:
                    r["para_state"] = f"none/{st}"
            elif k == "BackgroundScheduled" and r["para_state"] == "":
                r["para_state"] = "none/background"
            elif k == "LayoutUpdate" and ev["versions"]["source_revision"] >= want and r["page_ms"] is None:
                r["page_ms"] = ms
            elif k == "PdfExported":
                r["final_ms"], r["final"] = ms, ev.get("path") or pdf
                if not ev.get("converged", True):
                    r["final_exact"] = "unconverged"
            elif k == "error":
                log(f"  rtex: {ev}")

        r["para_state"] = r["para_state"] or "no event"
        return r


class Typst(External):
    """typst watch on the Typst variant: a whole PDF after every saved edit. Not LaTeX, so nothing is checked
    against a stock run."""
    name = "typst"
    engines = ("typst",)
    read_stderr = True

    def version(self):
        return subprocess.run([TYPST, "--version"], capture_output=True, text=True).stdout.strip()

    def env(self):
        return dict(os.environ)

    def argv(self):
        return [TYPST, "watch", self.main, "out.pdf"]

    def parse(self, line):
        m = re.search(r"compiled (successfully|with warnings|with errors)(?: in ([\d.]+) ?(ms|s|µs))?", line)
        if not m:
            return None
        v = float(m.group(2)) * {"ms": 1, "s": 1000, "µs": 0.001}[m.group(3)] if m.group(2) else None
        return {"ok": m.group(1) != "with errors", "ms": v}

    def first(self):
        t, ev = self.next()
        ms = (t - self.t0) * 1000
        return {"first_page_ms": ms, "done_ms": ms, "pages": page_count(f"{self.proj}/out.pdf")}

    def edit(self, file, pos, key, page):
        t0 = time.monotonic()
        apply(f"{self.proj}/{file}", pos, key)
        try:
            t, ev = self.next(timeout=20)
        except queue.Empty:  # the watcher missed the save: counted as a key with no output
            log("  typst: no compile within 20 s of the save")
            return blank(para_state="n/a", page_exact="n/a", final_exact="missed")
        ms = (t - t0) * 1000
        return blank(para_state="n/a", page_ms=ms, final_ms=ms, self_ms=ev["ms"], page_exact="n/a",
                     final_exact="n/a")


class Texpresso(External):
    """TeXpresso's engine and incremental machinery (its frontend objects, unmodified, at the default 500 ms
    snapshots) without its SDL window: clients/preview/texpresso/txp-headless. XeLaTeX only; its pages are XDV
    in memory, drawn by its own interpreter: no file to check."""
    name = "texpresso"
    engines = ("xelatex",)

    def version(self):
        return "texpresso " + git_rev(f"{SRC}/texpresso") + " via txp-headless " + git_rev(REPO)

    def env(self):
        e = tl_env()
        # Overleaf's TeX Live image has no kanjix.map/ckx.map, which TeXpresso's DVI reader insists on: empty ones
        e["TEXMFDBS"] = f"{BUILD}/txp/texmf:{TL_ROOT}/texmf-var:{TL_ROOT}/texmf-dist"
        return e

    def argv(self):
        return [TXP, "-texlive", f"{self.proj}/{self.main}"]

    def first(self):
        r = {"first_page_ms": None}
        self.opened = set()
        while True:
            t, ev = self.next()
            if ev.get("ev") == "pages":
                if r["first_page_ms"] is None and ev.get("n", 0) > 0:
                    r["first_page_ms"] = (t - self.t0) * 1000
                if ev.get("done"):
                    r["done_ms"], r["pages"] = (t - self.t0) * 1000, ev.get("n")
                    self.applied = ev.get("applied", 0)
                    return r

    def edit(self, file, pos, key, page):
        if file not in self.opened:  # TeXpresso takes changes only to files the editor opened
            self.opened.add(file)
            self.send(["open", file, open(f"{self.proj}/{file}", encoding="utf-8").read()])
            self.applied += 1
        if page is not None:
            self.send(["goal", page])
        apply(f"{self.proj}/{file}", pos, key)  # our copy of the text, for the next open
        t0 = time.monotonic()
        self.send(["change", file, pos, 0, key])
        self.applied += 1
        r = blank(para_state="n/a", page_exact="n/a", final_exact="n/a")
        while True:
            t, ev = self.next()
            if ev.get("ev") != "pages" or ev.get("applied", 0) < self.applied:
                continue
            ms = (t - t0) * 1000
            if r["page_ms"] is None and (page is None or ev.get("n", 0) > page or ev.get("done")):
                r["page_ms"], r["self_ms"] = ms, ev.get("edit_us", 0) / 1000
            if ev.get("done"):
                r["final_ms"] = ms
                return r


class Rosina(External):
    """liveTeX-Rosina, PDF-output mode, watching the saved file (1 ms polling), full correction with no debounce.
    Its previews are provisional by design; its full builds are compared with stock."""
    name = "rosina"
    engines = ("pdflatex", "xelatex", "lualatex")

    def version(self):
        return "liveTeX-Rosina " + git_rev(f"{SRC}/liveTeX-Rosina")

    def argv(self):
        return [ROSINA, "--engine", self.engine, "--source", f"{self.proj}/{self.main}", "--out", self.out,
                "--debounce-ms", "0", "--editor"]

    def on_event(self, ev):  # the published PDF is replaced by later builds: keep this one
        if ev.get("event") in ("full", "preview") and ev.get("pdf") and os.path.exists(ev["pdf"]):
            dst = f"{self.keep}/{ev['event']}-{ev.get('revision')}.pdf"
            try:
                shutil.copyfile(ev["pdf"], dst)
                ev["kept"] = dst
            except OSError:
                pass

    def first(self):
        while True:
            t, ev = self.next()
            if ev.get("event") == "full":
                self.rev = ev.get("revision", 1)
                ms = (t - self.t0) * 1000
                return {"first_page_ms": ms, "done_ms": ms, "pages": page_count(ev["pdf"]) if ev.get("pdf") else None}

    def edit(self, file, pos, key, page):
        self.rev += 1
        t0 = time.monotonic()
        apply(f"{self.proj}/{file}", pos, key)
        r = blank()
        while True:
            t, ev = self.next()
            if ev.get("revision", 0) < self.rev:
                continue
            ms, k = (t - t0) * 1000, ev.get("event")
            if k == "preview" and r["para_state"] == "":
                if ev.get("ok"):
                    r["para_ms"], r["para_state"] = ms, "provisional"
                    r["self_ms"] = ev.get("elapsed_ms")
                else:
                    r["para_state"] = "none/failed"
            elif k == "background_scheduled" and r["para_state"] == "":
                r["para_state"] = "none/" + re.sub(r"[^a-z]+", "-", ev.get("reason", "").split(";")[0])[:40]
            elif k == "full":
                self.rev = ev.get("revision", self.rev)
                r["page_ms"] = r["final_ms"] = ms
                r["final"], r["page_is_final"] = ev.get("kept"), True  # the whole PDF at once
                r["para_state"] = r["para_state"] or "no event"
                return r


SYSTEMS = {s.name: s for s in (Latexmk, PdftexLive, TauLive, Rtex, Typst, Texpresso, Rosina)}


# ---------------------------------------------------------------------------------------------- one run
def ref_dir(doc, engine):
    return f"{WORK}/refs/{doc}/{engine}"


def ext(engine):
    return "xdv" if engine == "xelatex" else "pdf"


def run_latexmk(doc, engine, meta):
    sysm = Latexmk()
    v = meta["variants"][engine]
    proj = f"{WORK}/run/latexmk-{doc}-{engine}"
    copy(f"{DOCS}/{doc}/{engine}", proj)
    refs = ref_dir(doc, engine)
    shutil.rmtree(refs, ignore_errors=True)
    os.makedirs(refs)
    main = v["main"]
    # first compile: a settled project (its .aux kept), no latexmk database yet
    first = sysm.compile(proj, engine, main)
    pages = page_count(f"{proj}/{stem(main)}.{ext(engine)}")
    shutil.copy(f"{proj}/{stem(main)}.{ext(engine)}", f"{refs}/0.{ext(engine)}")
    rows = []
    for n, spot, file, pos, key in script(meta, engine):
        apply(f"{proj}/{file}", pos, key)
        ms = sysm.compile(proj, engine, main)
        out = f"{proj}/{stem(main)}.{ext(engine)}"
        shutil.copy(out, f"{refs}/{n}.{ext(engine)}")
        page = synctex_page(f"{proj}/{stem(main)}.synctex", file, line_of(f"{proj}/{file}", pos))
        open(f"{refs}/{n}.page", "w").write("" if page is None else str(page))
        rows.append(dict(n=n, spot=spot, para_ms=None, para_state="", page_ms=ms, page_exact="ref", final_ms=ms,
                         final_exact="ref", page=page))
        log(f"  latexmk {doc} {engine} #{n}: {ms:.0f} ms (page {page})")
        time.sleep(REST)
    # memory: one more compile; the peak resident size of latexmk's processes (rusage of waited-for children)
    e = tex_env()
    code = ("import resource, subprocess, sys; subprocess.run(sys.argv[1:], stdin=subprocess.DEVNULL, "
            "stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); "
            "print(resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss)")
    peak = int(subprocess.run([sys.executable, "-c", code, *sysm.argv(engine, main)[:-1], "-g", main], cwd=proj, capture_output=True,
                              text=True, env=dict(e, PATH=f"{USTOCK}:{e['PATH']}")).stdout.strip())
    # one plain stock run per state (no latexmk): the least any full recompile costs
    stock = []
    s2 = f"{proj}-stock"
    copy(f"{DOCS}/{doc}/{engine}", s2)
    for n, spot, file, pos, key in script(meta, engine):
        apply(f"{s2}/{file}", pos, key)
        ms, _ = run_stock(engine, s2, main)
        stock.append(dict(n=n, spot=spot, para_ms=None, para_state="", page_ms=ms, page_exact="", final_ms=ms,
                          final_exact="", page=rows[n - 1]["page"]))
    shutil.rmtree(proj, ignore_errors=True)
    shutil.rmtree(s2, ignore_errors=True)
    return sysm, dict(first_page_ms=first, done_ms=first, pages=pages, peak_mb=peak / 2**20, procs=""), rows, stock


class Stock(System):
    """One run of the stock engine after each edit, .aux already settled: the floor of any full recompile."""
    name = "stock-run"
    engines = ("pdflatex", "xelatex", "lualatex")

    def version(self):
        return "TeX Live 2026 static engines"


def run_driver(cls, doc, engine, meta):
    sysm = cls()
    v = meta["variants"][engine]
    refs = ref_dir(doc, engine)
    if engine != "typst" and not os.path.exists(f"{refs}/0.{ext(engine)}"):
        sys.exit(f"no references for {doc}/{engine}: run latexmk first")
    proj = f"{WORK}/run/{sysm.name}-{doc}-{engine}"
    out = f"{proj}-out"
    copy(f"{DOCS}/{doc}/{engine}", proj)
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    sysm.start(proj, engine, v["main"], out)
    mem = TreeRSS(sysm.p.pid)
    first = sysm.first()
    rows = []
    for n, spot, file, pos, key in script(meta, engine)[:int(os.environ.get("BENCH_EDITS", 999))]:
        pg = open(f"{refs}/{n}.page").read().strip() if os.path.exists(f"{refs}/{n}.page") else ""
        page = int(pg) if pg else None
        r = sysm.edit(file, pos, key, page)
        r.update(n=n, spot=spot, page=page)
        rows.append(r)
        log(f"  {sysm.name} {doc} {engine} #{n}: para {fmt(r['para_ms'])} {r['para_state']}, page {fmt(r['page_ms'])}"
            f", final {fmt(r['final_ms'])}")
        time.sleep(REST)
    peak, procs = mem.done()
    sysm.close()
    first.update(peak_mb=peak / 2**20, procs=procs)
    # exactness, after the timed part: the early PDF's new pages and the final output against latexmk's
    for r in rows:
        ref = f"{refs}/{r['n']}.{ext(engine)}"
        if r["final"] and r["final"].endswith(".pdf") and ref.endswith(".xdv"):  # a XeLaTeX PDF: latexmk's PDF
            if not os.path.exists(ref[:-4] + ".pdf"):
                subprocess.run([f"{UBIN}/xdvipdfmx", "-q", "-E", "-o", ref[:-4] + ".pdf", ref], env=tex_env(),
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            ref = ref[:-4] + ".pdf"
        if "final_exact" not in r:
            if r["final"] and os.path.exists(r["final"]):
                try:
                    r["final_exact"] = "yes" if same_file(r["final"], ref) or \
                        all(e for _, e in same_pages(r["final"], ref)) else "NO"
                except Exception as x:
                    log(f"  check failed: {x}")
                    r["final_exact"] = "unreadable"
            else:
                r["final_exact"] = "none"
        if r.get("page_is_final"):
            r["page_exact"] = r["final_exact"]
        if r.get("early_pdf") and r.get("pdf_path"):  # tau-pdfmx's pages: what stock xdvipdfmx makes of the same
            # pages of latexmk's XDV, written to the same path (the font subset tags hash the output's name)
            p = r["pdf_path"]
            os.makedirs(os.path.dirname(p), exist_ok=True)
            if os.path.exists(p):
                os.remove(p)  # our hard link keeps tau-pdfmx's bytes
            x = r["xdv_path"]  # latexmk's XDV under the event's own name, as tau-pdfmx read it
            if os.path.exists(x):
                os.remove(x)
            shutil.copy(ref, x)
            subprocess.run([f"{UBIN}/xdvipdfmx", "-q", "-z", "1", "-s", f"{r['pdf_first'] + 1}-{r['pdf_last'] + 1}",
                            "-o", p, x], cwd=f"{out}/work" if os.path.isdir(f"{out}/work") else out, env=tex_env(),
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            r["page_exact"] = "yes" if os.path.exists(p) and same_file(r["early_pdf"], p) else "NO"
        if "page_exact" not in r:
            if r["early"]:
                new = range(r["early_from"] or 0, r["early_pages"] or 0)
                try:
                    r["page_exact"] = "yes" if all(e for _, e in same_pages(r["early"], ref, new)) else "NO"
                except Exception as x:
                    log(f"  check failed: {x}")
                    r["page_exact"] = "unreadable"
            else:
                r["page_exact"] = "none"
    for r in rows:
        if r.get("display_pdf"):
            ref = f"{refs}/{r['n']}.{ext(engine)}"
            try:
                r["display_exact"] = display_check(r["display_pdf"], r["display_page"], ref)
            except Exception as x:
                log(f"  display check failed: {x}")
                r["display_exact"] = "unreadable"
    if not os.environ.get("BENCH_KEEP"):  # BENCH_KEEP=1: leave the run's files for a look
        for d in (proj, out, f"{out}-keep"):
            shutil.rmtree(d, ignore_errors=True)
    return sysm, first, rows


def display_check(path, k, ref):
    """A display page against stock's page k: "yes" when the content streams are byte-equal and the two pages draw
    the same pixels at 288 dpi (Core Graphics, every channel of every pixel), "pixels" when only the drawing agrees,
    "NO" otherwise."""
    from pypdf import PdfReader
    a, b = PdfReader(path).pages[k], PdfReader(ref).pages[k]
    same_stream = a.get_contents().get_data() == b.get_contents().get_data()
    box = [float(v) for v in b.mediabox]
    ra = _pixels().render(open(path, "rb").read(), k, box)[0]
    rb = _pixels().render(open(ref, "rb").read(), k, box)[0]
    return "yes" if same_stream and ra == rb else "pixels" if ra == rb else "NO"


def _pixels():
    sys.path.insert(0, f"{REPO}/clients/universal/tests")
    import pixels  # Core Graphics renders (pikepdf, pyobjc)
    return pixels


def fmt(x):
    return "-" if x is None else f"{x:.1f}"


COLS = ["date", "system", "version", "doc", "engine", "n", "spot", "page", "para_ms", "para_state", "page_ms",
        "page_exact", "final_ms", "final_exact", "self_ms", "xdvipdfmx_ms", "display_ms", "display_exact", "display_page"]
FCOLS = ["date", "system", "version", "doc", "engine", "pages", "first_page_ms", "done_ms", "peak_mb", "procs", "load", "other_cpu"]


def write(sysm, doc, engine, first, rows):
    os.makedirs(RESULTS, exist_ok=True)
    date = time.strftime("%Y-%m-%d")
    base = dict(date=date, system=sysm.name, version=sysm.version(), doc=doc, engine=engine)
    for name, cols, items in (("edits", COLS, rows), ("first", FCOLS, [first])):
        path = f"{RESULTS}/{name}.tsv"
        old = []
        if os.path.exists(path):
            old = [l for l in open(path).read().splitlines()[1:]
                   if l.split("\t")[1:2] + l.split("\t")[3:5] != [sysm.name, doc, engine]]
        new = ["\t".join(fmt_cell({**base, **it}.get(c)) for c in cols) for it in items]
        open(path, "w").write("\t".join(cols) + "\n" + "".join(l + "\n" for l in old + new))


def fmt_cell(x):
    if x is None:
        return ""
    if isinstance(x, float):
        return f"{x:.2f}"
    return str(x)


class Load:
    """While a run lasts, every second: the 1-minute load average, and the cores busy in processes outside this
    harness's process tree (ps's %cpu summed): other agents' work. The run's noise is the mean of the second."""

    def __init__(self):
        self.load, self.other, self.stop = [], [], False
        self.t = threading.Thread(target=self.loop, daemon=True)
        self.t.start()

    def loop(self):
        me = os.getpid()
        while not self.stop:
            self.load.append(os.getloadavg()[0])
            out = subprocess.run(["ps", "-Ao", "pid=,ppid=,pcpu="], capture_output=True, text=True).stdout
            parent, cpu = {}, {}
            for line in out.splitlines():
                p, pp, c = line.split()
                parent[int(p)], cpu[int(p)] = int(pp), float(c)
            ours = set()
            for p in parent:
                q, seen = p, 0
                while q > 1 and seen < 64:
                    if q == me:
                        ours.add(p)
                        break
                    q, seen = parent.get(q, 0), seen + 1
            self.other.append(sum(c for p, c in cpu.items() if p not in ours and p != me) / 100)
            time.sleep(1)

    def done(self):
        self.stop = True
        self.t.join()
        return sum(self.load) / len(self.load), sum(self.other) / len(self.other)


OTHER_MAX = float(os.environ.get("BENCH_OTHER_MAX", 2))  # cores busy elsewhere; above it the run is done again


def run(system, doc, engine):
    meta = load(doc)
    if engine not in meta["variants"]:
        log(f"skip {system} {doc} {engine}: no such variant")
        return
    prev = None
    for attempt in range(3):
        log(f"{system} {doc} {engine}" + (f" (again: {prev:.1f} cores busy elsewhere)" if attempt else ""))
        saved = {n: open(f"{RESULTS}/{n}.tsv").read() for n in ("edits", "first") if os.path.exists(f"{RESULTS}/{n}.tsv")}
        lo = Load()
        if system == "latexmk":
            sysm, first, rows, stock = run_latexmk(doc, engine, meta)
        else:
            sysm, first, rows = run_driver(SYSTEMS[system], doc, engine, meta)
        load_, other = lo.done()
        first["load"], first["other_cpu"] = f"{load_:.1f}", f"{other:.2f}"
        if prev is not None and other >= prev:  # no quieter than the kept run: keep that one
            for n, text in saved.items():
                open(f"{RESULTS}/{n}.tsv", "w").write(text)
        else:
            if system == "latexmk":
                write(Stock(), doc, engine, dict(pages=first["pages"], load=first["load"],
                                                 other_cpu=first["other_cpu"]), stock)
            write(sysm, doc, engine, first, rows)
            prev = other
        if prev <= OTHER_MAX:
            return


def done(system, doc, engine):
    """Already in results/first.tsv (bench/run.py all resumes; delete the rows or the file to redo)."""
    p = f"{RESULTS}/first.tsv"
    return os.path.exists(p) and any(l.split("\t")[1:2] + l.split("\t")[3:5] == [system, doc, engine]
                                     for l in open(p).read().splitlines()[1:])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("system")
    ap.add_argument("doc", nargs="?")
    ap.add_argument("engine", nargs="?")
    ap.add_argument("--docs", nargs="*")
    ap.add_argument("--engines", nargs="*")
    a = ap.parse_args()
    if a.system == "all":
        docs = a.docs or sorted(d for d in os.listdir(DOCS) if os.path.exists(f"{DOCS}/{d}/edits.json"))
        for engine in a.engines or ("pdflatex", "xelatex", "lualatex", "typst"):  # pdfLaTeX's verdict first
            for doc in docs:
                for s in SYSTEMS.values():
                    if engine in s.engines and engine in load(doc)["variants"] and not done(s.name, doc, engine):
                        run(s.name, doc, engine)
        return
    run(a.system, a.doc, a.engine)


if __name__ == "__main__":
    main()
