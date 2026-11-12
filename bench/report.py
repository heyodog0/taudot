# AGPL-3.0-or-later. Tables and a chart from bench/results/*.tsv into docs/bench.md (between the markers) and
# docs/bench.svg.   uv run bench/report.py
# One table per question; the prose around the markers (method, fairness) is written by hand.
import csv
import os
import sys
import textwrap

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import REPO, RESULTS, pct  # noqa: E402

DOC = f"{REPO}/docs/bench.md"
SVG = f"{REPO}/docs/bench.svg"
SIZES = ("synth-10", "synth-100", "synth-300")
PAPERS = ("arxiv-1512.03385", "arxiv-1706.03762", "arxiv-2103.00020")
ENGINES = (("pdflatex", "pdfLaTeX"), ("xelatex", "XeLaTeX"), ("lualatex", "LuaLaTeX"))


def load(name):
    p = f"{RESULTS}/{name}.tsv"
    return list(csv.DictReader(open(p), delimiter="\t")) if os.path.exists(p) else []


def num(x):
    return float(x) if x not in ("", None) else None


def f(x):
    return f"{x:.0f}" if x >= 100 else f"{x:.1f}" if x >= 1 else f"{x:.2f}"


def vals(rs, k):
    return [v for v in (num(r.get(k)) for r in rs) if v is not None]


def cell(xs):
    """p50 / p90, or the one value when there is one."""
    if not xs:
        return "–"
    return f(xs[0]) if len(xs) == 1 else f"{f(pct(xs, 50))} / {f(pct(xs, 90))}"


def pick(rows, system, doc, engine=None):
    return [r for r in rows if r["system"] == system and r["doc"] == doc and (engine is None or r["engine"] == engine)]


def size(d):
    return d.replace("synth-", "") + " pp" if d.startswith("synth") else d.replace("arxiv-", "")


def head(first, docs, extra=()):
    cols = [first] + [size(d) for d in docs] + list(extra)
    return [f"| {' | '.join(cols)} |", "|" + "---|" * len(cols)]


def counted(rs, k, first_col):
    """p50 / p90 (exact previews, and provisional ones when any), with "of N" in the first column."""
    xs = vals(rs, k)
    if not rs:
        return ""
    ex = sum(r.get("para_state") == "exact" for r in rs)
    pr = sum(r.get("para_state", "").startswith("provisional") for r in rs)
    n = f"{ex} of {len(rs)}" if first_col else f"{ex}"
    return f"{cell(xs)} ({n}" + (f", +{pr} prov.)" if pr else ")")


def own_counted(rs, k, first_col):
    """As counted(), with the system's own figure (self_ms p50) in brackets."""
    xs, own = vals(rs, k), vals(rs, "self_ms")
    o = f" [{f(pct(own, 50))}]" if own else ""
    return f"{cell(xs)}{o} ({len(xs)} of {len(rs)})" if first_col else f"{cell(xs)}{o} ({len(xs)})"


# The systems on the synthetic documents: (label, rows, system, engine).
def exact_page(e, r):
    out = ["## Edit → exact page", "",
           "The page holding the edit, as stock sets it. Display page: universal's copy of it sent before the run "
           "finishes (in brackets, keys that got one).", ""] + head("system", SIZES)
    rows = [
        ("**Taudot** patched, pdfLaTeX", e, "taudot-pdftex", "pdflatex", "page_ms"),
        ("**Taudot** universal, pdfLaTeX", e, "taudot-universal", "pdflatex", "page_ms"),
        ("↳ display page", e, "taudot-universal", "pdflatex", "display_ms"),
        ("**Taudot** universal, XeLaTeX", e, "taudot-universal", "xelatex", "page_ms"),
        ("**Taudot** universal, LuaLaTeX", e, "taudot-universal", "lualatex", "page_ms"),
        ("↳ display page", e, "taudot-universal", "lualatex", "display_ms"),
        ("TeXpresso, XeLaTeX (XDV page)", e, "texpresso", "xelatex", "page_ms"),
        ("Typst `watch` (not LaTeX)", e, "typst", "typst", "page_ms"),
        ("Rosina quick mode, pdfLaTeX (whole PDF)", r, "rosina-quick", "pdflatex", "final_ms"),
        ("rtex, LuaLaTeX (background layout)", e, "rtex", "lualatex", "page_ms"),
    ] + [(f"latexmk, {n}", e, "latexmk", en, "final_ms") for en, n in ENGINES] \
      + [(f"one stock run, {n}", e, "stock-run", en, "final_ms") for en, n in ENGINES]
    for label, src, s, en, k in rows:
        cells = []
        for d in SIZES:
            rs = pick(src, s, d, None if s == "typst" else en)
            cells.append(f"{cell(vals(rs, k))} ({len(vals(rs, k))})" if k == "display_ms" else cell(vals(rs, k)))
        out.append(f"| {label} | " + " | ".join(cells) + " |")
    own = [pct(vals(pick(e, "typst", d), "self_ms"), 50) for d in SIZES]
    out += ["", f"Typst's own compile is {' / '.join(f(x) for x in own)} ms; the rest of its wall time is the file "
            "watcher."]
    return out


def whole_pdf(e, r):
    out = ["## Edit → whole exact PDF", ""] + head("system", SIZES)
    for label, s, en in [("**Taudot** patched, pdfLaTeX", "taudot-pdftex", "pdflatex"),
                         ("**Taudot** universal, pdfLaTeX", "taudot-universal", "pdflatex"),
                         ("**Taudot** universal, XeLaTeX", "taudot-universal", "xelatex"),
                         ("**Taudot** universal, LuaLaTeX", "taudot-universal", "lualatex"),
                         ("TeXpresso, XeLaTeX (its `done`, no file)", "texpresso", "xelatex")]:
        out.append(f"| {label} | " + " | ".join(cell(vals(pick(e, s, d, en), "final_ms")) for d in SIZES) + " |")
    out.append("| Rosina, pdfLaTeX, quick / PDF mode (p50) | " + " | ".join(
        f"{f(pct(vals(pick(r, 'rosina-quick', d, 'pdflatex'), 'final_ms'), 50))} / "
        f"{f(pct(vals(pick(r, 'rosina', d, 'pdflatex'), 'final_ms'), 50))}" for d in SIZES) + " |")
    out.append("| rtex, LuaLaTeX (`export_pdf`) | " + " | ".join(
        cell(vals(pick(e, "rtex", d, "lualatex"), "final_ms")) for d in SIZES) + " |")
    out += ["", "latexmk and one stock run: as in the table above (they write nothing before the whole PDF)."]
    return out


def preview(e, r):
    out = ["## Edit → paragraph preview", "",
           "The edited paragraph alone, set by the real engine on the old page; in brackets, keys that got one and "
           "[the system's own figure]. Taudot's previews are exact (same lines and heights) except the few marked "
           "prov.; Rosina's are provisional by design.", ""] + head("system", SIZES)
    rows = [("**Taudot** patched, pdfLaTeX", e, "taudot-pdftex", "pdflatex", counted),
            ("**Taudot** universal, pdfLaTeX", e, "taudot-universal", "pdflatex", counted),
            ("**Taudot** universal, XeLaTeX", e, "taudot-universal", "xelatex", counted),
            ("**Taudot** universal, LuaLaTeX", e, "taudot-universal", "lualatex", counted),
            ("rtex, LuaLaTeX", e, "rtex", "lualatex", own_counted),
            ("Rosina quick, pdfLaTeX", r, "rosina-quick", "pdflatex", own_counted),
            ("Rosina quick, XeLaTeX", r, "rosina-quick", "xelatex", own_counted),
            ("Rosina PDF mode, pdfLaTeX", r, "rosina", "pdflatex", own_counted)]
    for label, src, s, en, fn in rows:
        out.append(f"| {label} | " + " | ".join(fn(pick(src, s, d, en), "para_ms", i == 0)
                                               for i, d in enumerate(SIZES)) + " |")
    out += ["", "Taudot has none for the first key at a new spot, or a paragraph across a page or column or in a box."]
    return out


def papers(e, r):
    out = ["## Real papers (pdfLaTeX)", "",
           "1512.03385 (12 pp., one column), 1706.03762 (15 pp., `\\input` sections), 2103.00020 (48 pp., two "
           "columns, many figures).", ""] + head("measure, system", PAPERS)
    rows = [("preview, patched", e, "taudot-pdftex", "para_ms", counted),
            ("preview, universal", e, "taudot-universal", "para_ms", counted),
            ("display page, universal", e, "taudot-universal", "display_ms", None),
            ("exact page, patched", e, "taudot-pdftex", "page_ms", cell),
            ("exact page, universal", e, "taudot-universal", "page_ms", cell),
            ("whole PDF, patched", e, "taudot-pdftex", "final_ms", cell),
            ("whole PDF, universal", e, "taudot-universal", "final_ms", cell),
            ("whole PDF, Rosina quick (no previews)", r, "rosina-quick", "final_ms", cell),
            ("latexmk", e, "latexmk", "final_ms", cell),
            ("one stock run", e, "stock-run", "final_ms", cell)]
    for label, src, s, k, fn in rows:
        cells = []
        for i, d in enumerate(PAPERS):
            rs = pick(src, s, d, "pdflatex")
            xs = vals(rs, k)
            cells.append(fn(rs, k, i == 0) if fn in (counted,) else f"{cell(xs)} ({len(xs)})" if fn is None
                         else cell(xs))
        out.append(f"| {label} | " + " | ".join(cells) + " |")
    rp = [x for d in PAPERS for x in vals(pick(r, "rosina-quick", d, "pdflatex"), "para_ms")]
    out += ["", "Rosina previews none of the keys on the papers: each falls back to a whole build." if not rp else
            f"Rosina previews {len(rp)} of the keys on the papers."]
    return out


def burst():
    keys, runs = load("burst"), load("burst_runs")
    out = ["## Burst typing, 8 keys a second", "",
           "Each spot's six keys sent 125 ms apart without waiting, two runs per row (60 keys); times from each key to "
           "the first output containing it (first pixels: preview, display page or page). Skipped: keys whose own "
           "state never reached an exact page.", "",
           "| document | first pixels: patched | universal | exact page: patched | universal | skipped (universal) |",
           "|---|---|---|---|---|---|"]

    def ks(d, s, en):
        return [k for k in keys if k["doc"] == d and k["system"] == s and k["engine"] == en]
    for d in SIZES + PAPERS:
        p, u = ks(d, "taudot-pdftex", "pdflatex"), ks(d, "taudot-universal", "pdflatex")
        out.append(f"| {size(d)} | {cell(vals(p, 'pixels_ms'))} | {cell(vals(u, 'pixels_ms'))} | "
                   f"{cell(vals(p, 'exact_ms'))} | {cell(vals(u, 'exact_ms'))} | "
                   f"{sum(k['own_exact'] != 'True' for k in u)} |")
    other = []
    skipped = 0
    for en, n in ENGINES[1:]:
        px = " / ".join(f(pct(vals(ks(d, "taudot-universal", en), "pixels_ms"), 50)) for d in SIZES)
        ex = " / ".join(f(pct(vals(ks(d, "taudot-universal", en), "exact_ms"), 50)) for d in SIZES)
        skipped += sum(k["own_exact"] != "True" for d in SIZES for k in ks(d, "taudot-universal", en))
        other.append((n, px, ex))
    tot = lambda c: sum(int(x[c]) for x in runs)
    o, oe, fi, fe = tot("outputs"), tot("outputs_exact"), tot("finals"), tot("finals_exact")
    same = (f"All {o:,} outputs sent during bursts matched latexmk after the same keys" if o == oe else
            f"{oe:,} of {o:,} outputs sent during bursts matched latexmk after the same keys") + \
           (f", as did all {fi} settled PDFs." if fi == fe else f"; {fe} of {fi} settled PDFs did.")
    (xn, xp, xe), (ln, lp, le) = other
    out += ["", f"Universal {xn}, p50 at 10 / 100 / 300 pp: first pixels {xp}, exact page {xe}; {ln} {lp} and {le}; "
            + ("none skipped. " if not skipped else f"{skipped} skipped. ") + same,
            "Universal's one stall: an edit on page 1 of the 10-page document has no snapshot before it, so each key "
            "restarts a run that needs ~140 ms to ship a page, longer than the gap between keys; nothing shows until "
            "130–160 ms after the last key (patched: 61–88 ms per key)."]
    return out


def opens(e, first, rfirst):
    rows = load("opens")

    def med(s, d, k):
        xs = [float(r[k]) for r in rows if r["system"] == s and r["doc"] == d]
        return pct(xs, 50) if xs else None

    def fd(src, s, d, en, both=True):
        r = pick(src, s, d, en)
        if not r:
            return ""
        a, b = num(r[0]["first_page_ms"]), num(r[0]["done_ms"])
        return f"{f(a)} / {f(b)}" if both else f(a)
    out = ["## First output on open", "",
           "A reopened project (`.aux` settled). ms, first page / settled; Taudot pdfLaTeX: median of six opens.", "",
           "| system | 10 pp | 100 pp | 300 pp | papers (first page) |", "|---|---|---|---|---|"]
    for label, s in (("**Taudot** patched, pdfLaTeX", "taudot-pdftex"), ("**Taudot** universal, pdfLaTeX", "taudot-universal")):
        out.append(f"| {label} | " + " | ".join(f"{f(med(s, d, 'first_page_ms'))} / {f(med(s, d, 'done_ms'))}"
                                                 for d in SIZES)
                   + " | " + " / ".join(f(med(s, d, "first_page_ms")) for d in PAPERS) + " |")
    xe = rfirst if pick(rfirst, "taudot-universal", SIZES[0], "xelatex") else first
    out.append("| **Taudot** universal, XeLaTeX | " + " | ".join(fd(xe, "taudot-universal", d, "xelatex")
                                                                 for d in SIZES) + " | |")
    out.append("| **Taudot** universal, LuaLaTeX | " + " | ".join(fd(first, "taudot-universal", d, "lualatex")
                                                                  for d in SIZES) + " | |")
    for label, src, s, en, pap in (("TeXpresso, XeLaTeX", first, "texpresso", "xelatex", False),
                                   ("Typst `watch`", first, "typst", "typst", False),
                                   ("Rosina quick, pdfLaTeX", rfirst, "rosina-quick", "pdflatex", True),
                                   ("Rosina quick, XeLaTeX", rfirst, "rosina-quick", "xelatex", False),
                                   ("rtex, LuaLaTeX", first, "rtex", "lualatex", False)):
        p = " / ".join(fd(src, s, d, en, False) for d in PAPERS) if pap else ""
        out.append(f"| {label} | " + " | ".join(fd(src, s, d, en, False) for d in SIZES) + f" | {p} |")
    out.append("| latexmk, pdfLaTeX / XeLaTeX / LuaLaTeX | " + " | ".join(
        " / ".join(fd(first, "latexmk", d, en, False) for en, _ in ENGINES) for d in SIZES) + " | |")
    out += ["", "Settled on the papers: " + ", ".join(
        f"{n} " + " / ".join(f(med(s, d, "done_ms")) for d in PAPERS)
        for n, s in (("patched", "taudot-pdftex"), ("universal", "taudot-universal"))) + "."]
    return out


def memory():
    """phys_footprint summed over the process group, MB: idle (mean), typing (peak over keys and bursts), 10-15 s after
    the last key (mean); each cell the two runs' range when it is over 10 MB."""
    main_ = load("memory")
    tag = [r["tag"] for r in main_ if r["tag"].startswith("main-")][-1]
    main_ = [r for r in main_ if r["tag"] == tag]
    ros = [r for r in load("rosina/memory") if r["system"] == "rosina-quick"]
    out = ["## Memory, pdfLaTeX", "",
           "phys_footprint, MB: idle after open, peak while typing, 10–15 s after the last key. Two runs each (range "
           "when they differ by over 10 MB); Rosina in quick mode.", "",
           "| document | system | idle | typing peak | after |", "|---|---|---|---|---|"]
    srcs = ((main_, "taudot-pdftex"), (main_, "taudot-universal"), (ros, "rosina-quick"))

    def rng(xs):
        xs = sorted(xs)
        return f"{xs[0]:.0f}" if xs[-1] - xs[0] <= 10 else f"{xs[0]:.0f}–{xs[-1]:.0f}"

    def m(src, s, d, phases, k, agg):
        rs = [r for r in src if r["system"] == s and r["doc"] == d and r["phase"] in phases]
        return rng([agg(float(r[k]) for r in rs if r["round"] == x) for x in sorted({r["round"] for r in rs})])
    for d in SIZES + PAPERS:
        idle = " / ".join(m(src, s, d, ("idle",), "fp_mean_mb", max) for src, s in srcs)
        peak = " / ".join(m(src, s, d, ("keys", "burst"), "fp_peak_mb", max) for src, s in srcs)
        after = " / ".join(m(src, s, d, ("idle +10-15 s",), "fp_mean_mb", max) for src, s in srcs)
        out.append(f"| {size(d)} | patched / universal / Rosina | {idle} | {peak} | {after} |")

    def span(src, s, k, agg=max):
        xs = [agg(float(r[k]) for r in src if r["system"] == s and r["doc"] == d and r["round"] == x)
              for d in SIZES + PAPERS for x in sorted({r["round"] for r in src if r["system"] == s and r["doc"] == d})]
        return f"{min(xs):.0f}–{max(xs):.0f}"
    out += ["", "Universal reaps kept processes after 2.5 s idle and falls back to its idle level or below; patched "
            "holds its typing level until it exits. Processes: " + ", ".join(
                f"{n} {span(src, s, 'procs')}" for n, (src, s) in zip(("patched", "universal", "Rosina"), srcs))
            + ". Summed RSS gives the same order: " + ", ".join(
                f"{n} {span(src, s, 'rss_peak_mb')} MB" for n, (src, s) in zip(("universal", "patched"), srcs[1::-1]))
            + "."]
    return out


def checked(e, r):
    out = ["## Checked against stock", "",
           "| system | display page = stock | exact page = stock | whole PDF = stock |", "|---|---|---|---|"]

    def frac(rs, k):
        xs = [x[k] for x in rs if x.get(k)]
        if xs and all(v in ("n/a", "claim") for v in xs):
            return {"n/a": "not checkable", "claim": "claimed (display lists)"}[xs[0]]
        return f"{sum(v == 'yes' for v in xs)} / {len(xs)}" if xs else ""
    for label, s, en in (("**Taudot** patched, pdfLaTeX", "taudot-pdftex", "pdflatex"),
                         ("**Taudot** universal, pdfLaTeX", "taudot-universal", "pdflatex"),
                         ("**Taudot** universal, XeLaTeX", "taudot-universal", "xelatex"),
                         ("**Taudot** universal, LuaLaTeX", "taudot-universal", "lualatex"),
                         ("rtex, LuaLaTeX", "rtex", "lualatex")):
        rs = [x for x in e if x["system"] == s and x["engine"] == en]
        out.append(f"| {label} | {frac(rs, 'display_exact')} | {frac(rs, 'page_exact')} | {frac(rs, 'final_exact')} |")
    q, p = [x for x in r if x["system"] == "rosina-quick"], [x for x in r if x["system"] == "rosina"]
    out.append(f"| Rosina quick / PDF mode | | | {frac(q, 'final_exact')}, {frac(p, 'final_exact')} |")
    out.append("| TeXpresso, Typst | | not checkable | not checkable |")
    miss = sorted({(x["doc"], int(x["n"]) % 100) for x in q + p if x["final_exact"] != "yes"})
    if len(miss) == 1:
        out += ["", f"Rosina's misses are one edit ({size(miss[0][0])}, edit {miss[0][1]}): a page stays as before "
                "the key; stock's changes."]
    elif miss:
        out += ["", "Rosina's misses: " + ", ".join(f"{size(d)} edit {n}" for d, n in miss) + "."]
    return out


# ---------------------------------------------------------------------------------------------- chart
LIGHT = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4"]
DARK = ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181"]
MARK = ["circle", "square", "diamond", "triangle", "circle-open"]
PANELS = [
    ("pdfLaTeX: edit → exact page", "page_ms", [
        ("taudot-pdftex", "pdflatex", "Taudot (patched)"), ("taudot-universal", "pdflatex", "Taudot universal"),
        ("taudot-universal", "pdflatex", "universal: display page", "display_ms"),
        ("latexmk", "pdflatex", "latexmk")]),
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
        for i, (s, e, name, *kk) in enumerate(series):
            pts = []
            for d in SIZES:
                rs = [num(r.get(kk[0] if kk else key)) for r in edits if r["system"] == s and r["doc"] == d and (r["engine"] == e)]
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
             f'latexmk, Typst: the whole PDF. Typst is its own typesetter.</text>')
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
def main():
    edits, first = load("edits"), load("first")
    redits, rfirst = load("rosina/edits"), load("rosina/first")
    block = []
    for part in (exact_page(edits, redits), whole_pdf(edits, redits), preview(edits, redits), papers(edits, redits),
                 burst(), opens(edits, first, rfirst), memory(), checked(edits, redits)):
        block += part + [""]
    block = [x if x.startswith("|") else "\n".join(textwrap.wrap(x, 120, break_on_hyphens=False)) or x
             for x in block]
    block = [x.replace("|  |", "| |") for x in block]
    text = open(DOC).read()
    a, b = text.index("<!-- bench:begin -->"), text.index("<!-- bench:end -->")
    open(DOC, "w").write(text[:a] + "<!-- bench:begin -->\n" + "\n".join(block[:-1]) + "\n" + text[b:])
    chart(edits)
    print(f"wrote {DOC} and {SVG}")


if __name__ == "__main__":
    main()
