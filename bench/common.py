# AGPL-3.0-or-later. Shared paths, environment and small helpers for the live-typesetting benchmark.
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
REF = os.environ.get("TAUDOT_REF", os.path.expanduser("~/code/lab/taudot-ref"))
BENCH = os.environ.get("BENCH_DIR", f"{REF}/bench")  # builds of the other systems, documents, scratch
WORK = f"{BENCH}/work"
DOCS = f"{BENCH}/docs"
SRC = f"{BENCH}/src"
RESULTS = f"{REPO}/bench/results"

# TeX Live 2026 (the store tree), the universal build's engines, pinned dates: clients/universal/env.sh
TL_ROOT = f"{REF}/texlive-2026/store-root"
UBIN = f"{REF}/universal/bin"  # libtau, tau-live, engines built from release source (zlib as a dylib)
USTOCK = f"{REF}/universal/bin-static"  # TeX Live's own static build: the reference
UFMT = f"{REF}/universal/fmt-2026"
BUILD = f"{BENCH}/build"  # Taudot's drivers built from this checkout (bench/build.sh)
PDFTEX_BUILD = f"{BUILD}/pdftex"  # patched pdfTeX: clients/pdftex/patches/2026 on TeX Live 2026's release source
TAU_BIN = f"{BUILD}/universal"  # libtau, tau-live, tau-tdl
LATEXMK = f"{REF}/texlive-2026/src-stock/texk/texlive/linked_scripts/latexmk/latexmk.pl"
EPOCH = "1700000000"

ENGINES = ("pdflatex", "xelatex", "lualatex")


def tex_env(fmt=UFMT, fetch=False):
    e = {k: v for k, v in os.environ.items() if not k.startswith(("TAU_", "TEXSTORE")) and k != "DYLD_INSERT_LIBRARIES"}
    e.update(TEXMFCNF=f"{TL_ROOT}-cnf:{TL_ROOT}/texmf-dist/web2c", TEXFORMATS=f".:{fmt}",
             SOURCE_DATE_EPOCH=EPOCH, FORCE_SOURCE_DATE="1", TEXSTORE_IMAGE="2026.1@r79468", TEXSTORE_ROOT=TL_ROOT)
    if fetch:  # libtau fetches missing TeX Live files from the store (only under DYLD_INSERT_LIBRARIES)
        e.update(TAU_TLROOT=TL_ROOT, TEXSTORE_URL="https://texlive.taudot.app")
    return e


def engine_cmd(engine, main, bin=USTOCK, synctex=False):
    c = [f"{bin}/{engine}"] + (["-no-pdf"] if engine == "xelatex" else []) + ["-interaction=batchmode"]
    return c + (["-synctex=-1"] if synctex else []) + [main]


def run_fetching(engine, d, main):
    """One run under libtau that fetches every TeX Live file the document needs (outputs stay in memory)."""
    out = f"{WORK}/fetch-out"
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    e = dict(tex_env(fetch=True), DYLD_INSERT_LIBRARIES=f"{UBIN}/libtau.dylib", TAU_OUT=out, TAU_PROJECT=d)
    subprocess.run(engine_cmd(engine, main, UBIN), cwd=d, env=e, stdin=subprocess.DEVNULL,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shutil.rmtree(out, ignore_errors=True)


def run_stock(engine, d, main, synctex=False):
    t = time.monotonic()
    r = subprocess.run(engine_cmd(engine, main, synctex=synctex), cwd=d, env=tex_env(), stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return (time.monotonic() - t) * 1000, r.returncode


def stem(main):
    return os.path.splitext(main)[0]


def copy(src, dst):
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(src, dst, symlinks=True)


def page_count(path):
    """Pages of a PDF (its /Type /Pages /Count) or an XDV (eop bytes after the postamble's count)."""
    b = open(path, "rb").read()
    if path.endswith(".xdv"):
        return len(xdv_pages(b))
    counts = [int(m) for m in re.findall(rb"/Type\s*/Pages\b[^>]*?/Count\s+(\d+)", b)]
    counts += [int(m) for m in re.findall(rb"/Count\s+(\d+)[^>]*?/Type\s*/Pages\b", b)]
    if counts:
        return max(counts)
    from pypdf import PdfReader
    return len(PdfReader(path).pages)


# ---------------------------------------------------------------------------------------------- XDV pages
sys.path.insert(0, f"{REPO}/clients/universal/tests")
import xdv as _xdv  # noqa: E402  (the universal tests' XDV page splitter, MIT)


def xdv_pages(b):
    """Each page's bytes, bop's back pointer left out (it moves when earlier pages change length)."""
    return [p[:41] + p[45:] for p in _xdv.pages(b)]


def same_pages(a, b, pages=None):
    """Pages of two outputs that are equal (PDF: content stream and resources of the page; XDV: the page's
    bytes). Returns the list of (page, equal) for the given pages (default: all of a's)."""
    if a.endswith(".xdv"):
        pa, pb = xdv_pages(open(a, "rb").read()), xdv_pages(open(b, "rb").read())
        idx = range(len(pa)) if pages is None else pages
        return [(k, k < len(pa) and k < len(pb) and pa[k] == pb[k]) for k in idx]
    from pypdf import PdfReader
    ra, rb = PdfReader(a), PdfReader(b)
    idx = range(len(ra.pages)) if pages is None else pages
    out = []
    for k in idx:
        if k >= len(ra.pages) or k >= len(rb.pages):
            out.append((k, False))
            continue
        out.append((k, _page_sig(ra.pages[k]) == _page_sig(rb.pages[k])))
    return out


def _page_sig(p):
    h = hashlib.sha256()
    c = p.get_contents()
    h.update(c.get_data() if c is not None else b"")
    res = p.get("/Resources")
    fonts = res.get_object().get("/Font") if res is not None else None
    for name in sorted(fonts.get_object().keys()) if fonts is not None else []:
        f = fonts.get_object()[name].get_object()
        base = str(f.get("/BaseFont"))  # the subset tag (ABCDEF+) depends on the glyphs used so far in the file
        h.update(name.encode() + re.sub(r"^/[A-Z]{6}\+", "/", base).encode())
    h.update(str(p.mediabox).encode())
    return h.digest()


ID = re.compile(rb"/ID ?\[ ?<[0-9A-Fa-f]+> ?<[0-9A-Fa-f]+> ?\]")


def same_file(a, b):
    """Byte-identical, with the PDF's /ID masked (LuaTeX's hashes the output's absolute path)."""
    x, y = open(a, "rb").read(), open(b, "rb").read()
    return x == y or ID.sub(b"/ID[]", x) == ID.sub(b"/ID[]", y)


def pct(xs, p):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    k = (len(xs) - 1) * p / 100
    f = int(k)
    return xs[f] + (xs[min(f + 1, len(xs) - 1)] - xs[f]) * (k - f)


# ---------------------------------------------------------------------------------------------- memory
class TreeRSS:
    """Peak resident memory of a process and all its descendants, sampled every 50 ms with ps."""

    def __init__(self, pid):
        self.pid, self.peak, self.peak_n, self.stop = pid, 0, 0, False
        import threading
        self.t = threading.Thread(target=self.loop, daemon=True)
        self.t.start()

    def sample(self):
        out = subprocess.run(["ps", "-axo", "pid=,ppid=,rss="], capture_output=True, text=True).stdout
        kids, rss = {}, {}
        for line in out.splitlines():
            p, pp, r = map(int, line.split())
            kids.setdefault(pp, []).append(p)
            rss[p] = r
        tot, n, todo = 0, 0, [self.pid]
        while todo:
            p = todo.pop()
            tot += rss.get(p, 0)
            n += 1
            todo += kids.get(p, [])
        return tot * 1024, n

    def loop(self):
        while not self.stop:
            tot, n = self.sample()
            if tot > self.peak:
                self.peak, self.peak_n = tot, n
            time.sleep(0.05)

    def done(self):
        self.stop = True
        self.t.join()
        return self.peak, self.peak_n


def git_rev(d):
    try:
        return subprocess.run(["git", "-C", d, "rev-parse", "--short=10", "HEAD"], capture_output=True,
                              text=True).stdout.strip()
    except OSError:
        return ""


def log(*a):
    print(*a, file=sys.stderr, flush=True)
