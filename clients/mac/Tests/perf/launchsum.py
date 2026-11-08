"""p50 / p95 (ms since launch) of launch milestones over launch.sh runs, as a Markdown table.

  uv run clients/mac/Tests/perf/launchsum.py LABEL=OUTDIR[,OUTDIR...] ...

window     the app presented its window (its timeline), else CGWindowList's first sight of it
editor     the editor column visually complete (capture); "≤" when it already was in the first captured frame,
           which comes ~140 ms after the window (a ScreenCaptureKit limit): then the capture's start is given.
           Neovim: the first `flush` from Neovim (timeline) when that is earlier.
pdf        a page on screen: the last PDF from disk (timeline "pdf: the last PDF"), else the first page in view
fresh pdf  the first full typeset finished (timeline)
sidebar    the sidebar (comments) visually complete (capture; "≤" as for editor)
list       the Projects window (FOLDER "-"): its content visually complete, i.e. the list shown
"""
import json
import sys
from pathlib import Path


def pct(v, q):
    v = sorted(x for x in v if x is not None)
    return v[min(len(v) - 1, int(q * len(v)))] * 1000 if v else None


def pane_done(r, pane):
    p = r.get(pane) or {}
    if p.get("done") is None:
        return None, False
    return p["done"], abs(p["done"] - r["capture_from"]) < 1e-6


def row(r):
    tl = r.get("timeline", {})
    win = tl.get("presented", r.get("window"))
    ed, ed_le = pane_done(r, "editor")
    if "nvim_flush" in tl and (ed is None or tl["nvim_flush"] < ed):
        ed, ed_le = tl["nvim_flush"], False
    pdf = tl.get("pdf_cached", tl.get("pdf_page_in_view"))
    sb, sb_le = pane_done(r, "sidebar")
    return {"window": (win, False), "editor": (ed, ed_le), "pdf": (pdf, False),
            "fresh pdf": (tl.get("pdf_typeset"), False), "sidebar": (sb, sb_le), "list": pane_done(r, "all")}


cols = ["window", "editor", "pdf", "fresh pdf", "sidebar", "list"]
print("| run | n | " + " | ".join(cols) + " |")
print("|---|---|" + "---|" * len(cols))
for arg in sys.argv[1:]:
    label, dirs = arg.split("=", 1)
    rows = []
    for d in dirs.split(","):
        for l in (Path(d) / "milestones.jsonl").read_text().splitlines():
            r = json.loads(l)
            if "error" not in r:
                rows.append(row(r))
    cells = []
    for c in cols:
        v = [r[c][0] for r in rows]
        le = "≤ " if rows and sum(r[c][1] for r in rows) > len(rows) / 2 else ""
        a, b = pct(v, 0.5), pct(v, 0.95)
        cells.append("–" if a is None else f"{le}{a:.0f} / {b:.0f}")
    print(f"| {label} | {len(rows)} | " + " | ".join(cells) + " |")
