# /// script
# requires-python = ">=3.11"
# ///
"""Ground truth for pdfsource: typeset each corpus paper ourselves with stock pdfLaTeX (TeX Live 2026).

uv run tests/corpus.py build [paper...]   -> $PDFSOURCE_CACHE/build/<paper>/<main>.pdf
The sources stay outside the repo; so do the PDFs (never commit papers or their text).
"""
import os, re, shutil, subprocess, sys, time
from pathlib import Path

R = Path(os.environ["TAUDOT_REF"])  # the reference tree: corpus, texlive-2026, universal engines
CORPUS = R / "corpus"
CACHE = Path(os.environ.get("PDFSOURCE_CACHE", R / "pdfsource"))
TL = R / "texlive-2026/store-root"
STOCK = R / "universal/bin-static"

def env():
    e = dict(os.environ)
    e.update(TEXMFCNF=f"{TL}-cnf:{TL}/texmf-dist/web2c", TEXFORMATS=f".:{R}/universal/fmt-2026",
             SOURCE_DATE_EPOCH="1700000000", FORCE_SOURCE_DATE="1", max_print_line="10000")
    return e

def main_file(d: Path):
    for f in sorted(d.glob("*.tex")):
        t = f.read_text(errors="replace")
        if re.search(r"^\s*\\documentclass", t, re.M) and "\\begin{document}" in t and "subfiles" not in t[:2000]:
            return f
    return None

CLIENT = Path(__file__).resolve().parents[3] / "tools/texstore/client.py"
_lsr = None

def locate(name):
    """TeX Live path of a file name, from the tree's ls-R (the store fills the tree on demand)."""
    global _lsr
    if _lsr is None:
        _lsr, d = {}, ""
        for line in (TL / "texmf-dist/ls-R").read_text(errors="replace").splitlines():
            if line.endswith(":"):
                d = line[:-1]
            elif line and not line.startswith("%"):
                _lsr.setdefault(line, TL / "texmf-dist" / d[2:] / line)
    return _lsr.get(name)

def fetch(name):
    p = locate(name)
    if not p or p.exists():
        return False
    e = env(); e.update(TEXSTORE_URL="https://texlive.taudot.app", TEXSTORE_IMAGE="2026.1@r79468", TEXSTORE_ROOT=str(TL))
    return subprocess.run(["uv", "run", "--no-project", "python", "-I", str(CLIENT), "fetch", str(p)], env=e,
                          capture_output=True).returncode == 0

MISSING = [re.compile(rb"File `([^']+)' not found"), re.compile(rb"=([A-Za-z0-9_-]+) at [0-9.]+pt not loadable: Metric"),
           re.compile(rb"Font [^=]+=([A-Za-z0-9_-]+) not loadable: Metric"), re.compile(rb"! I can't find file `([^']+)'"),
           re.compile(rb"!pdfTeX error: [^\n]*\(file ([^)]+)\): cannot open")]

def run(cmd, cwd, log, tries=60):
    for _ in range(tries):
        p = subprocess.run(cmd, cwd=cwd, env=env(), stdin=subprocess.DEVNULL, capture_output=True, timeout=600)
        out = p.stdout + p.stderr
        names = dict.fromkeys(m.group(1).decode() for r in MISSING for m in r.finditer(out))
        cand = [c for n in names for c in ([n] if "." in n else [n + ".tfm", n + ".tex", n + ".sty"])]
        if not any([fetch(c) for c in cand]):
            break
    log.write(out)
    return p.returncode

def build(paper):
    src = CORPUS / paper
    m = main_file(src)
    if not m:
        return "no main"
    out = CACHE / "build" / paper
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(src, out)
    stem = m.stem
    with open(out / "_build.log", "wb") as log:
        t = time.time()
        pdfl = [str(STOCK / "pdflatex"), "-interaction=nonstopmode", m.name]
        run(pdfl, out, log)
        aux = out / f"{stem}.aux"
        if aux.exists() and not (out / f"{stem}.bbl").exists() and "\\bibdata" in aux.read_text(errors="replace"):
            run([str(STOCK / "bibtex"), stem], out, log)
        run(pdfl, out, log); run(pdfl, out, log)
    pdf = out / f"{stem}.pdf"
    return f"ok {pdf} {time.time()-t:.1f}s" if pdf.exists() else "no pdf"

if __name__ == "__main__":
    cmd, *papers = sys.argv[1:] or ["build"]
    papers = papers or sorted(p.name for p in CORPUS.iterdir() if p.is_dir())
    for p in papers:
        print(p, build(p), flush=True)
