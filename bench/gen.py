# AGPL-3.0-or-later. The benchmark's documents: synthetic articles of about 10, 100 and 300 pages with the same text
# in four variants (pdfLaTeX, XeLaTeX, LuaLaTeX, Typst), plus copies of real arXiv papers from the pdfsource corpus;
# and for each, the fixed edit script (where the keys go).
#
#   uv run bench/gen.py [--pages 10 100 300] [--papers ID ...]
#
# Output: $BENCH_DIR/docs/<doc>/<variant>/ (main.tex or main.typ, settled .aux) and <doc>/edits.json.
import argparse
import json
import os
import random
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import DOCS, ENGINES, REF, copy, log, page_count, run_fetching, run_stock, stem  # noqa: E402

KEYS = "quick "  # typed at every spot, one key per edit
SPOTS = (0.5, 0.1, 0.9, 0.3, 0.7)  # fractions of the document's prose paragraphs, in the order visited

# Plain words (no TeX specials), so the same text is valid LaTeX and Typst.
WORDS = """the of and to in is that for it as with be on by this are from at an which or we can not have has more
one all their its also two these other such but than been first only when they may between each new used time
where most into some over many well both three under same however each model data result method system value
case form number point order level state field space group function process theory analysis structure effect
energy given small large general shown above below following different important possible particular previous
simple single linear local global initial final standard total average higher lower greater common known
approach problem solution condition parameter variable equation distribution measure sample estimate error
signal source surface region boundary interval sequence matrix vector element operator transform series limit
rate scale range weight density pressure temperature frequency phase mode wave field charge mass length width
present consider assume define obtain derive follow require provide describe compare observe measure compute
apply extend reduce increase decrease remain become contain include produce depend correspond represent""".split()
SYMS = [("x", "x"), ("y", "y"), ("t", "t"), ("n", "n"), ("k", "k")]


def sentence(r):
    n = r.randint(8, 22)
    w = [r.choice(WORDS) for _ in range(n)]
    w[0] = w[0].capitalize()
    for _ in range(r.randint(0, 2)):
        i = r.randint(2, n - 2)
        w[i] += ","
    return " ".join(w) + "."


def inline_math(r):
    a, _ = r.choice(SYMS)
    i = r.choice("ijk")
    return [(f"${a}_{{{i}}}^{{2}} + {r.randint(2, 9)}{a}_{{{i}}}$", f"${a}_{i}^2 + {r.randint(2, 9)}{a}_{i}$"),
            (f"$f({a}) \\leq {r.randint(2, 9)}$", f"$f({a}) <= {r.randint(2, 9)}$"),
            (f"$\\alpha_{{{i}}}$", f"$alpha_{i}$")][r.randint(0, 2)]


def blocks(r):
    """An endless stream of blocks: ('sec', title), ('par', [(latex, typst) pieces]), ('eq', latex, typst),
    ('list', [items])."""
    sec = 0
    while True:
        sec += 1
        yield ("sec", " ".join(r.choice(WORDS) for _ in range(r.randint(2, 4))).capitalize())
        for p in range(r.randint(5, 9)):
            pieces = []
            for _ in range(r.randint(2, 9)):
                s = sentence(r)
                pieces.append((s, s))
                if r.random() < 0.25:
                    m = inline_math(r)
                    pieces.append((f"Thus {m[0]} holds.", f"Thus {m[1]} holds."))
            yield ("par", pieces)
            if r.random() < 0.12:
                c = r.randint(2, 9)
                yield ("eq", f"\\sum_{{i=1}}^{{n}} a_{{i}} x_{{i}}^{{2}} = {c} \\int_{{0}}^{{1}} f(t)\\, dt",
                       f"sum_(i=1)^n a_i x_i^2 = {c} integral_0^1 f(t) dif t")
            if r.random() < 0.06:
                yield ("list", [sentence(r) for _ in range(r.randint(2, 4))])


PRE = {
    "pdflatex": "\\usepackage[T1]{fontenc}\n\\usepackage{lmodern}\n",
    "xelatex": "\\usepackage{fontspec}\n",
    "lualatex": "\\usepackage{fontspec}\n",
}


def latex(bl, engine):
    out = ["\\documentclass[11pt]{article}\n", PRE[engine],
           "\\usepackage{amsmath}\n\\usepackage[a4paper,margin=25mm]{geometry}\n\\usepackage{microtype}\n",
           "\\begin{document}\n\n"]
    spots = []
    for b in bl:
        if b[0] == "sec":
            out.append(f"\\section{{{b[1]}}}\n\n")
        elif b[0] == "par":
            text = " ".join(p[0] for p in b[1])
            spots.append(len("".join(out).encode()) + mid(text))
            out.append(text + "\n\n")
        elif b[0] == "eq":
            out.append(f"\\begin{{equation}}\n{b[1]}\n\\end{{equation}}\n\n")
        else:
            out.append("\\begin{itemize}\n" + "".join(f"\\item {s}\n" for s in b[1]) + "\\end{itemize}\n\n")
    out.append("\\end{document}\n")
    return "".join(out), spots


def typst(bl):
    out = ['#set page(paper: "a4", margin: 25mm)\n#set text(font: "New Computer Modern", size: 11pt)\n',
           '#set par(justify: true)\n#set heading(numbering: "1")\n#set math.equation(numbering: "(1)")\n\n']
    spots = []
    for b in bl:
        if b[0] == "sec":
            out.append(f"= {b[1]}\n\n")
        elif b[0] == "par":
            text = " ".join(p[1] for p in b[1])
            spots.append(len("".join(out).encode()) + mid(text))
            out.append(text + "\n\n")
        elif b[0] == "eq":
            out.append(f"$ {b[2]} $\n\n")
        else:
            out.append("".join(f"- {s}\n" for s in b[1]) + "\n")
    return "".join(out), spots


def mid(text):
    """A word start near the middle of a paragraph, outside math, in bytes."""
    return _mid_bytes(text.encode())


def pick(spots):
    return [spots[min(len(spots) - 1, int(f * len(spots)))] for f in SPOTS], [min(len(spots) - 1, int(f * len(spots)))
                                                                            for f in SPOTS]


def write_variant(d, name, text):
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    open(f"{d}/{name}", "w").write(text)


def settle(engine, d, main="main.tex"):
    """Fetch what the document needs, then stock runs until the .aux is stable (as latexmk would leave it)."""
    run_fetching(engine, d, main)
    aux = f"{d}/{stem(main)}.aux"
    prev = None
    for _ in range(4):
        _, code = run_stock(engine, d, main)
        cur = open(aux, "rb").read() if os.path.exists(aux) else b""
        if cur == prev:
            break
        prev = cur
    out = f"{d}/{stem(main)}." + ("xdv" if engine == "xelatex" else "pdf")
    return page_count(out) if os.path.exists(out) else 0


def synthetic(pages):
    name = f"synth-{pages}"
    root = f"{DOCS}/{name}"
    stream = list(_take(blocks(random.Random(2026)), pages * 14))
    # calibrate the block count on pdfLaTeX: the most blocks that still fit in PAGES pages (bisection)
    d = f"{root}/pdflatex"

    def pages_of(k):
        write_variant(d, "main.tex", latex(stream[:k], "pdflatex")[0])
        run_fetching("pdflatex", d, "main.tex")
        run_stock("pdflatex", d, "main.tex")
        return page_count(f"{d}/main.pdf")

    lo, hi = 1, len(stream)
    while lo < hi:
        k = (lo + hi + 1) // 2
        got = pages_of(k)
        log(f"{name}: {k} blocks -> {got} pages")
        lo, hi = (k, hi) if got <= pages else (lo, k - 1)
    k = lo
    bl = stream[:k]
    meta = {"doc": name, "kind": "synthetic", "keys": KEYS, "variants": {}}
    for engine in ENGINES:
        text, spots = latex(bl, engine)
        d = f"{root}/{engine}"
        write_variant(d, "main.tex", text)
        n = settle(engine, d)
        pos, idx = pick(spots)
        meta["variants"][engine] = {"main": "main.tex", "file": "main.tex", "spots": pos, "paragraphs": idx,
                                    "pages": n, "bytes": len(text.encode())}
        log(f"{name}/{engine}: {n} pages")
    text, spots = typst(bl)
    write_variant(f"{root}/typst", "main.typ", text)
    pos, idx = pick(spots)
    meta["variants"]["typst"] = {"main": "main.typ", "file": "main.typ", "spots": pos, "paragraphs": idx,
                                 "bytes": len(text.encode())}
    json.dump(meta, open(f"{root}/edits.json", "w"), indent=1)


def _take(it, n):
    for _ in range(n):
        yield next(it)


# ---------------------------------------------------------------------------------------------- arXiv papers
PROSE = re.compile(rb"^[A-Za-z][^\n%\\]{30}[^\n%]{150,}$", re.M)


def paper(pid, engines=("pdflatex",)):
    """A copy of a corpus paper (its source as arXiv serves it); edits at the middle of five prose lines."""
    src = f"{REF}/corpus/{pid}"
    srcdir = next(p for p in (f"{src}/src", src) if os.path.isdir(p) and any(f.endswith(".tex") for f in os.listdir(p)))
    mains = [f for f in os.listdir(srcdir) if f.endswith(".tex") and b"\\documentclass" in open(f"{srcdir}/{f}", "rb").read()]
    main = "main.tex" if "main.tex" in mains else sorted(mains)[0]
    root = f"{DOCS}/arxiv-{pid}"
    meta = {"doc": f"arxiv-{pid}", "kind": "arxiv", "keys": KEYS, "variants": {}}
    for engine in engines:
        d = f"{root}/{engine}"
        copy(srcdir, d)
        for x in ("aux", "blg", "log", "out", "pdf", "xdv", "synctex.gz", "toc", "fls", "fdb_latexmk"):
            if os.path.exists(f"{d}/{stem(main)}.{x}"):  # the main file's outputs only (figures may be PDFs)
                os.remove(f"{d}/{stem(main)}.{x}")
        n = settle(engine, d, main)
        # the prose lines: in the main file, else in the biggest \input file
        files = [main] + sorted((f for f in _tex_files(d) if f != main), key=lambda f: -os.path.getsize(f"{d}/{f}"))
        for f in files:
            b = open(f"{d}/{f}", "rb").read()
            body = b.find(b"\\begin{document}") if f == main else 0
            lines = [m for m in PROSE.finditer(b) if m.start() > body]
            if len(lines) >= 10:
                break
        pos, idx = pick([m.start() + _mid_bytes(m.group()) for m in lines])
        meta["variants"][engine] = {"main": main, "file": f, "spots": pos, "paragraphs": idx, "pages": n,
                                    "bytes": len(b)}
        log(f"arxiv-{pid}/{engine}: {n} pages, edits in {f}")
    json.dump(meta, open(f"{root}/edits.json", "w"), indent=1)


def _tex_files(d):
    for dp, _, fs in os.walk(d):
        for f in fs:
            if f.endswith(".tex"):
                yield os.path.relpath(f"{dp}/{f}", d)


def _mid_bytes(line):
    """The first word start at or after the middle with an even number of $ before it."""
    i = len(line) // 2
    while i < len(line):
        if line[i - 1:i] == b" " and line[:i].count(b"$") % 2 == 0:
            return i
        i += 1
    return line.rfind(b" ") + 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pages", type=int, nargs="*", default=[10, 100, 300])
    ap.add_argument("--papers", nargs="*", default=["1706.03762", "2103.00020", "1512.03385"])
    ap.add_argument("--paper-engines", nargs="*", default=["pdflatex"])
    a = ap.parse_args()
    os.makedirs(DOCS, exist_ok=True)
    for p in a.pages:
        synthetic(p)
    for pid in a.papers:
        paper(pid, a.paper_engines)


if __name__ == "__main__":
    main()
