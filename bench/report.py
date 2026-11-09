# AGPL-3.0-or-later. Tables and a chart from bench/results/*.tsv into docs/bench.md (between the markers) and
# docs/bench.svg.   uv run bench/report.py
import csv
import os
import platform
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import REPO, RESULTS, pct  # noqa: E402

DOC = f"{REPO}/docs/bench.md"
SVG = f"{REPO}/docs/bench.svg"
SIZES = ("synth-10", "synth-100", "synth-300")
PAPERS = ("arxiv-1512.03385", "arxiv-1706.03762", "arxiv-2103.00020")
ROWS = [  # (system, engine, label)
    ("taudot-pdftex", "pdflatex", "**Taudot**, patched pdfTeX"),
    ("taudot-universal", "pdflatex", "**Taudot** universal, pdfLaTeX"),
    ("taudot-universal", "xelatex", "**Taudot** universal, XeLaTeX"),
    ("taudot-universal", "lualatex", "**Taudot** universal, LuaLaTeX"),
    ("rtex", "lualatex", "rtex, LuaLaTeX"),
    ("rosina", "pdflatex", "liveTeX-Rosina, pdfLaTeX"),
    ("rosina", "xelatex", "liveTeX-Rosina, XeLaTeX"),
    ("rosina", "lualatex", "liveTeX-Rosina, LuaLaTeX"),
    ("texpresso", "xelatex", "TeXpresso, XeLaTeX"),
    ("typst", "typst", "Typst `watch` (not LaTeX)"),
    ("latexmk", "pdflatex", "latexmk, pdfLaTeX"),
    ("latexmk", "xelatex", "latexmk, XeLaTeX"),
    ("latexmk", "lualatex", "latexmk, LuaLaTeX"),
    ("stock-run", "pdflatex", "one stock run, pdfLaTeX"),
    ("stock-run", "xelatex", "one stock run, XeLaTeX"),
    ("stock-run", "lualatex", "one stock run, LuaLaTeX"),
]


def load(name):
    p = f"{RESULTS}/{name}.tsv"
    return list(csv.DictReader(open(p), delimiter="\t")) if os.path.exists(p) else []


def num(x):
    return float(x) if x not in ("", None) else None


def cell(xs):
    xs = [x for x in xs if x is not None]
    if not xs:
        return "–"
    return f"{f(pct(xs, 50))} / {f(pct(xs, 90))}"


def f(x):
    return f"{x:.0f}" if x >= 100 else f"{x:.1f}" if x >= 1 else f"{x:.2f}"


NO_PREVIEW = ("latexmk", "stock-run", "typst", "texpresso")
OWN = {"para_ms": ("taudot-pdftex", "taudot-universal", "rtex", "rosina"), "page_ms": ("typst", "texpresso")}


def table(edits, docs, key, title, note=None, extra=None):
    out = [f"| {title} | " + " | ".join(d.replace("synth-", "") + " pp" if d.startswith("synth") else d.replace("arxiv-", "")
                                        for d in docs) + " |", "|---|" + "---|" * len(docs)]
    for s, e, label in ROWS:
        if key == "para_ms" and s in NO_PREVIEW:
            continue
        cells, any_ = [], False
        for d in docs:
            rs = [r for r in edits if r["system"] == s and r["engine"] == e and r["doc"] == d]
            if d.startswith("synth") and s == "typst":
                rs = [r for r in edits if r["system"] == s and r["doc"] == d]
            if not rs:
                cells.append("")
                continue
            any_ = True
            c = cell([num(r[key]) for r in rs])
            if extra:
                c += extra(rs)
            if s in OWN.get(key, ()):  # the system's own figure for the same thing, where it reports one
                own = [num(r["self_ms"]) for r in rs if r.get("self_ms")]
                if own:
                    c += f"<br><sub>own p50 {f(pct(own, 50))}</sub>"
            cells.append(c)
        if any_:
            out.append(f"| {label} | " + " | ".join(cells) + " |")
    return "\n".join(out) + ("\n\n" + note if note else "")


def coverage(rs):
    n = len(rs)
    ex = sum(r["para_state"] == "exact" for r in rs)
    pr = sum(r["para_state"] == "provisional" for r in rs)
    if ex == 0 and pr == 0:
        return ""
    return f"<br><sub>{ex} exact, {pr} prov. of {n}</sub>" if ex else f"<br><sub>{pr} prov. of {n}</sub>"


def exact_table(edits):
    out = ["| | exact page = stock | whole PDF = stock |", "|---|---|---|"]
    for s, e, label in ROWS:
        rs = [r for r in edits if r["system"] == s and r["engine"] == e]
        if not rs or s in ("latexmk", "stock-run"):
            continue

        def c(k):
            vals = [r[k] for r in rs]
            if all(v in ("n/a", "claim") for v in vals):
                return {"n/a": "not checkable", "claim": "claimed (display lists)"}[vals[0]]
            return f"{sum(v == 'yes' for v in vals)} / {len(vals)}" + (
                f" ({sum(v == 'NO' for v in vals)} differ)" if any(v == "NO" for v in vals) else "")
        out.append(f"| {label} | {c('page_exact')} | {c('final_exact')} |")
    return "\n".join(out)


def first_table(first):
    out = ["| | " + " | ".join(f"{d.replace('synth-', '')} pp: first page / settled / peak RSS" for d in SIZES) + " |",
           "|---|" + "---|" * len(SIZES)]
    for s, e, label in ROWS:
        cells, any_ = [], False
        for d in SIZES:
            r = [x for x in first if x["system"] == s and (x["engine"] == e or s == "typst") and x["doc"] == d]
            if not r or s == "stock-run":
                cells.append("")
                continue
            any_ = True
            r = r[0]
            fp, dn, mb = num(r["first_page_ms"]), num(r["done_ms"]), num(r["peak_mb"])
            cells.append(f"{f(fp) if fp else '–'} / {f(dn) if dn else '–'} ms / {mb:.0f} MB" if mb else
                         f"{f(fp) if fp else '–'} / {f(dn) if dn else '–'} ms")
        if any_:
            out.append(f"| {label} | " + " | ".join(cells) + " |")
    return "\n".join(out)


# ---------------------------------------------------------------------------------------------- chart
LIGHT = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4"]
DARK = ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181"]
MARK = ["circle", "square", "diamond", "triangle", "circle-open"]
PANELS = [
    ("pdfLaTeX: edit → exact page", "page_ms", [
        ("taudot-pdftex", "pdflatex", "Taudot (patched)"), ("taudot-universal", "pdflatex", "Taudot universal"),
        ("rosina", "pdflatex", "Rosina (full build)"), ("latexmk", "pdflatex", "latexmk")]),
    ("XeLaTeX, LuaLaTeX, Typst: edit → page", "page_ms", [
        ("taudot-universal", "xelatex", "Taudot, XeLaTeX"), ("taudot-universal", "lualatex", "Taudot, LuaLaTeX"),
        ("rtex", "lualatex", "rtex layout"), ("texpresso", "xelatex", "TeXpresso*"), ("typst", "typst", "Typst watch")]),
]


def chart(edits):
    W, H, PW, top, left, bottom = 1080, 440, 450, 56, 64, 76
    ph = H - top - bottom
    lo, hi = 1, 10000
    import math

    def y(v):
        return top + ph - (math.log10(max(lo, min(hi, v))) - 0) / 4 * ph

    css = (":root{--s:#fcfcfb;--t1:#1b1b19;--t2:#55554f;--g:#e4e3df;" +
           "".join(f"--c{i}:{c};" for i, c in enumerate(LIGHT)) + "}"
           "@media (prefers-color-scheme: dark){:root{--s:#1a1a19;--t1:#f0efec;--t2:#c3c2b7;--g:#33332f;" +
           "".join(f"--c{i}:{c};" for i, c in enumerate(DARK)) + "}}"
           "text{font:12px -apple-system,Helvetica,Arial,sans-serif;fill:var(--t2)}"
           ".h{font-size:14px;font-weight:600;fill:var(--t1)}.l{fill:var(--t1)}")
    g = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" role="img" '
         f'aria-label="Edit to exact page, median ms, log scale, by document length"><style>{css}</style>',
         f'<rect width="{W}" height="{H}" fill="var(--s)"/>']
    for p, (title, key, series) in enumerate(PANELS):
        x0 = left + p * (PW + 70)
        xs = {d: x0 + 30 + i * (PW - 190) / 2 for i, d in enumerate(SIZES)}
        g.append(f'<text class="h" x="{x0}" y="24">{title}</text>')
        g.append(f'<text x="{x0}" y="42">median ms after a key, log scale</text>')
        for v in (1, 10, 100, 1000, 10000):
            g.append(f'<line x1="{x0}" x2="{x0 + PW - 150}" y1="{y(v):.1f}" y2="{y(v):.1f}" stroke="var(--g)"/>')
            g.append(f'<text x="{x0 - 6}" y="{y(v) + 4:.1f}" text-anchor="end">{v:,}</text>')
        for d in SIZES:
            g.append(f'<text x="{xs[d]:.1f}" y="{H - bottom + 20}" text-anchor="middle">'
                     f'{d.replace("synth-", "")} pp</text>')
        labels = []
        for i, (s, e, name) in enumerate(series):
            pts = []
            for d in SIZES:
                rs = [num(r[key]) for r in edits if r["system"] == s and r["doc"] == d and (r["engine"] == e)]
                rs = [v for v in rs if v is not None]
                if rs:
                    pts.append((xs[d], y(pct(rs, 50)), pct(rs, 50), d))
            if not pts:
                continue
            c = f"var(--c{i})"
            g.append('<polyline fill="none" stroke-width="2" stroke="%s" points="%s"/>' %
                     (c, " ".join(f"{a:.1f},{b:.1f}" for a, b, _, _ in pts)))
            for a, b, v, d in pts:
                g.append(marker(MARK[i], a, b, c) + f"<title>{name}, {d}: {f(v)} ms</title></g>")
            labels.append([pts[-1][1], name, c, pts[-1][0]])
        labels.sort()
        for j in range(1, len(labels)):  # keep end labels 14 px apart
            labels[j][0] = max(labels[j][0], labels[j - 1][0] + 14)
        for yy, name, c, xx in labels:
            g.append(f'<text class="l" x="{xx + 10:.1f}" y="{yy + 4:.1f}">{name}</text>')
    g.append(f'<text x="{left}" y="{H - 26}">* TeXpresso: an XDV page in memory, not a PDF, from an engine older '
             f'than TeX Live 2025: not checkable against stock.</text>')
    g.append(f'<text x="{left}" y="{H - 10}">rtex: a background layout of display lists (exact by its own check). '
             f'Rosina, latexmk, Typst: the whole PDF. Typst is its own typesetter.</text>')
    g.append("</svg>")
    open(SVG, "w").write("\n".join(g) + "\n")


def marker(kind, x, y, c):
    s = 4.5
    shape = {
        "circle": f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{s}" fill="{c}"/>',
        "circle-open": f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{s}" fill="var(--s)" stroke="{c}" stroke-width="2"/>',
        "square": f'<rect x="{x - s:.1f}" y="{y - s:.1f}" width="{2 * s}" height="{2 * s}" rx="1" fill="{c}"/>',
        "diamond": f'<path d="M{x:.1f},{y - s - 1:.1f}L{x + s + 1:.1f},{y:.1f}L{x:.1f},{y + s + 1:.1f}L{x - s - 1:.1f},{y:.1f}Z" fill="{c}"/>',
        "triangle": f'<path d="M{x:.1f},{y - s - 1:.1f}L{x + s + 1:.1f},{y + s:.1f}L{x - s - 1:.1f},{y + s:.1f}Z" fill="{c}"/>',
    }[kind]
    return f'<g stroke="var(--s)" stroke-width="2" paint-order="stroke">{shape}'


# ---------------------------------------------------------------------------------------------- doc
def machine():
    chip = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
    mem = int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout) // 2**30
    return f"{chip}, {mem} GB, macOS {platform.mac_ver()[0]}"


def main():
    edits, first = load("edits"), load("first")
    versions = sorted({(r["system"], r["version"]) for r in first})
    loads = [num(r["load"]) for r in first if r.get("load")]
    block = [
        f"Machine: {machine()}; load average during runs {min(loads):.1f}–{max(loads):.1f} (other agents' work "
        f"shared the machine). Dates: {', '.join(sorted({r['date'] for r in first}))}. "
        "Cells: **p50 / p90 ms** over the 30 edits. Blank: the system doesn't support that engine.",
        "",
        "Versions: " + "; ".join(f"{s} `{v}`" for s, v in versions) + ".",
        "",
        "### Edit → paragraph preview",
        "",
        table(edits, SIZES, "para_ms", "", extra=coverage),
        "",
        "### Edit → exact page",
        "",
        table(edits, SIZES, "page_ms", ""),
        "",
        "### Edit → whole exact PDF",
        "",
        table(edits, SIZES, "final_ms", ""),
        "",
        "### Real papers (pdfLaTeX): edit → preview, exact page, whole PDF",
        "",
        table(edits, PAPERS, "para_ms", "preview", extra=coverage),
        "",
        table(edits, PAPERS, "page_ms", "exact page"),
        "",
        table(edits, PAPERS, "final_ms", "whole PDF"),
        "",
        "### Checked against stock (all documents)",
        "",
        exact_table(edits),
        "",
        "### First compile and memory",
        "",
        first_table(first),
    ]
    text = open(DOC).read()
    a, b = text.index("<!-- bench:begin -->"), text.index("<!-- bench:end -->")
    open(DOC, "w").write(text[:a] + "<!-- bench:begin -->\n" + "\n".join(block) + "\n" + text[b:])
    chart(edits)
    print(f"wrote {DOC} and {SVG}")


if __name__ == "__main__":
    main()
