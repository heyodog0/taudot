#!/usr/bin/env python3
"""A fake live pdfTeX driver for the app's tests: docs/live-protocol.md, with stock pdfLaTeX run from scratch.

    fake-live.py --serve [--engine PDFLATEX] [--bibtex BIBTEX] [--max-runs N] DIR MAIN.tex OUT

Copies DIR into OUT/work and compiles there (the project folder is never written). Every batch of edits is a new
compile: pdfLaTeX with -synctex=1 -interaction=batchmode, then latexmk's rule in small (BibTeX when the .aux's
\\citation/\\bibdata/\\bibstyle lines changed or there's no .bbl; a rerun while the .aux changed, at most N runs).
Each run gives one `final` PDF; there are no partial PDFs, `goal` and `finish` are accepted and ignored.
An edit during a compile kills it and starts over. Environment (TEXMFCNF, TEXSTORE_*, TEXFORMATS) as the app sets it.

Test hooks: FAKE_LIVE_DELAY_MS sleeps before each run (to see edits coalesce), FAKE_LIVE_FAIL=offline sends an
`error` event and typesets nothing.
"""
import hashlib
import json
import os
import re
import select
import shutil
import subprocess
import sys
import time

KEEP = 4  # files of each kind kept (the protocol promises three newer)


def emit(**ev):
    sys.stdout.write(json.dumps(ev, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def bib_lines(aux):
    try:
        with open(aux, encoding="latin-1") as f:
            return [l for l in f if l.startswith(("\\citation", "\\bibdata", "\\bibstyle"))]
    except OSError:
        return None


def digest(p):
    try:
        with open(p, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except OSError:
        return None


class Driver:
    def __init__(self, a):
        self.engine, self.bibtex, self.max_runs = a["engine"], a["bibtex"], a["max_runs"]
        self.dir, self.main, self.out = a["dir"], a["main"], a["out"]
        self.work = os.path.join(self.out, "work")
        shutil.rmtree(self.work, ignore_errors=True)
        self.job = os.path.splitext(self.main)[0]
        job = self.job

        def skip(d, names):  # the project's own output, not figures
            top = os.path.abspath(d) == self.dir
            return [n for n in names if n in (".git",) or n.startswith(".taudot")
                    or (top and n in (job + ".pdf", job + ".synctex.gz"))]

        shutil.copytree(self.dir, self.work, symlinks=True, ignore=skip)
        self.texts = {}  # path -> bytes, as the app sent them
        self.applied = 0
        self.seq = 0
        self.dirty = "open"
        self.since = 0.0
        self.kept = []
        self.files = 0

    # ---- commands
    def command(self, c):
        if not isinstance(c, list) or not c:
            return emit(ev="error", what="protocol", message=f"not a command: {c!r}")
        k = c[0]
        if k == "open":
            self.texts[c[1]] = c[2].encode()
            self.write(c[1])
            self.edited("edit")
        elif k == "change":
            path, pos, dele, ins = c[1], c[2], c[3], c[4]
            b = self.texts.get(path)
            if b is None:
                try:
                    with open(os.path.join(self.work, path), "rb") as f:
                        b = f.read()
                except OSError:
                    b = b""
            if pos < 0 or dele < 0 or pos + dele > len(b):
                return emit(ev="error", what="protocol", message=f"change out of range: {path} @{pos} -{dele}")
            self.texts[path] = b[:pos] + ins.encode() + b[pos + dele:]
            self.write(path)
            self.edited("edit")
        elif k == "rescan":
            for root, _, names in os.walk(self.dir):
                for n in names:
                    if n.endswith((".bib", ".bst", ".png", ".jpg", ".pdf", ".sty", ".cls", ".eps")):
                        src = os.path.join(root, n)
                        rel = os.path.relpath(src, self.dir)
                        dst = os.path.join(self.work, rel)
                        if digest(src) != digest(dst):
                            os.makedirs(os.path.dirname(dst), exist_ok=True)
                            shutil.copy2(src, dst)
            self.edited("rescan")
        elif k in ("goal", "finish"):
            pass
        else:
            emit(ev="error", what="protocol", message=f"unknown command {k}")

    def write(self, path):
        p = os.path.join(self.work, path)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(self.texts[path])

    def edited(self, why):
        if why == "edit":
            self.applied += 1
        self.dirty = self.dirty or why
        self.since = time.monotonic()

    # ---- runs
    def keep(self, *paths):
        self.kept.append(paths)
        while len(self.kept) > KEEP:
            for p in self.kept.pop(0):
                try:
                    os.remove(p)
                except OSError:
                    pass

    def run_tex(self, poll):
        """One pdfLaTeX run; returns its exit code, or None if an edit came in (the run is killed)."""
        if os.environ.get("FAKE_LIVE_DELAY_MS"):
            time.sleep(int(os.environ["FAKE_LIVE_DELAY_MS"]) / 1000)
        try:  # a run that ships no page leaves an older PDF behind: it isn't this run's
            os.remove(os.path.join(self.work, self.job + ".pdf"))
        except OSError:
            pass
        p = subprocess.Popen(
[self.engine, "-fmt=pdflatex", "-interaction=batchmode", "-synctex=1", self.main],
                             cwd=self.work, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
        while p.poll() is None:
            if poll(0.005):
                p.kill()
                p.wait()
                return None
        return p.returncode

    def compile(self, poll):
        why, applied = self.dirty, self.applied
        self.dirty = None
        self.seq += 1
        seq, t0 = self.seq, time.monotonic()
        aux = os.path.join(self.work, self.job + ".aux")
        code = 0
        runs = 0
        blg = None
        pages, outs = 0, {}
        while runs < self.max_runs:
            before_aux, before_bib = digest(aux), bib_lines(aux)
            runs += 1
            emit(ev="run", seq=seq, run=runs, applied=applied, why=why, from_page=0)
            code = self.run_tex(poll)
            if code is None:
                return  # an edit came in: start over
            pdf = os.path.join(self.work, self.job + ".pdf")
            name = f"pdf-{seq}-{runs}"
            outs = {}
            if not os.path.exists(pdf):  # a fatal error before the first page: no PDF, `done` names the log only
                s = os.path.join(self.work, self.job + ".log")
                if os.path.exists(s):
                    outs["log"] = os.path.join(self.out, name + ".log")
                    shutil.copyfile(s, outs["log"])
                    self.keep(outs["log"])
                break
            for ext, src in (("pdf", ".pdf"), ("synctex", ".synctex.gz"), ("log", ".log")):
                s = os.path.join(self.work, self.job + src)
                if os.path.exists(s):
                    d = os.path.join(self.out, name + src)
                    shutil.copyfile(s, d)
                    outs[ext] = d
            self.keep(*outs.values())
            pages = count_pages(outs.get("log"))
            us = int((time.monotonic() - t0) * 1e6)
            emit(ev="pdf", seq=seq, run=runs, applied=applied, pages=pages, final=True, from_page=0,
                 path=outs["pdf"], synctex=outs.get("synctex"), log=outs.get("log"), edit_us=us, finish_us=0)
            # latexmk's rule, in small
            after_bib = bib_lines(aux)
            bbl = os.path.join(self.work, self.job + ".bbl")
            if self.bibtex and after_bib and any(l.startswith("\\bibdata") for l in after_bib) and (
                    after_bib != before_bib or not os.path.exists(bbl) or why == "rescan"):
                old = digest(bbl)
                b = subprocess.run([self.bibtex, self.job], cwd=self.work, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
                src = os.path.join(self.work, self.job + ".blg")
                if os.path.exists(src):
                    blg = os.path.join(self.out, f"{self.job}-{seq}.blg")
                    shutil.copyfile(src, blg)
                changed = digest(bbl) != old
                emit(ev="bibtex", seq=seq, code=b.returncode, blg=blg, bbl_changed=changed)
                if changed:
                    why = "bibtex"
                    continue
            if digest(aux) != before_aux and runs < self.max_runs:
                why = "aux"
                continue
            break
        done = dict(ev="done", seq=seq, runs=runs, pages=pages, code=code)
        if outs.get("pdf"):
            done["path"] = outs["pdf"]
        if outs.get("log"):
            done["log"] = outs["log"]
        if blg:
            done["blg"] = blg
        emit(**done)

    def serve(self):
        emit(ev="hello", protocol=1, engine="fake: stock pdfLaTeX from scratch", image=os.environ.get("TEXSTORE_IMAGE"))
        if os.environ.get("FAKE_LIVE_FAIL") == "offline":
            emit(ev="error", what="offline", message="can't fetch tex/latex/base/article.cls: no network")
        buf = b""
        eof = False

        def poll(timeout):
            """Reads what stdin has; true if an edit came in."""
            nonlocal buf, eof
            got = False
            while not eof:
                r, _, _ = select.select([sys.stdin.buffer], [], [], timeout)
                if not r:
                    break
                d = os.read(sys.stdin.fileno(), 1 << 20)
                if not d:
                    eof = True
                    break
                buf += d
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    if line.strip():
                        try:
                            c = json.loads(line)
                        except ValueError:
                            emit(ev="error", what="protocol", message="bad JSON")
                            continue
                        self.command(c)
                        got = got or c[0] in ("open", "change", "rescan")
                timeout = 0
            if eof:
                sys.exit(0)
            return got

        while True:
            if self.dirty and time.monotonic() - self.since > 0.01 and os.environ.get("FAKE_LIVE_FAIL") != "offline":
                self.compile(poll)
            else:
                poll(0.05)


def count_pages(log):
    """From pdfTeX's "Output written on main.pdf (N pages, B bytes)." (the page tree is in a compressed object stream)."""
    try:
        with open(log, encoding="latin-1") as f:
            m = re.search(r"Output written on .*?\((\d+) pages?", f.read().replace("\n", ""))
    except (OSError, TypeError):
        return 0
    return int(m.group(1)) if m else 0


def main():
    a = sys.argv[1:]
    opts = {"engine": "pdflatex", "bibtex": shutil.which("bibtex"), "max_runs": 5}
    pos = []
    i = 0
    while i < len(a):
        if a[i] == "--serve":
            pass
        elif a[i] in ("--engine", "--bibtex", "--max-runs", "--snapshot-ms"):
            key = a[i][2:].replace("-", "_")
            opts[key] = int(a[i + 1]) if key in ("max_runs", "snapshot_ms") else a[i + 1]
            i += 1
        else:
            pos.append(a[i])
        i += 1
    if len(pos) != 3:
        sys.exit(__doc__)
    opts["dir"], opts["main"], opts["out"] = os.path.abspath(pos[0]), pos[1], os.path.abspath(pos[2])
    os.makedirs(opts["out"], exist_ok=True)
    Driver(opts).serve()


if __name__ == "__main__":
    main()
