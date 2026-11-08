# /// script
# dependencies = ["numpy"]
# ///
"""Reaction times from a probe run with scripted actions: keystroke -> glyph (editor pane), keystroke -> PDF change,
and every other action's first visible change. p50/p95 in ms.
  uv run clients/mac/Tests/perf/reactions.py DIR"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from analyse import analyse


def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(q * len(v)))] * 1000 if v else float("nan")


r = analyse(Path(sys.argv[1]))["actions"]
chars = [a for a in r if a["what"].startswith("char")]
for pane in ["editor", "pdf"]:
    v = [a["per_pane"][pane] for a in chars if pane in a["per_pane"]]
    print(f"char -> {pane}: n {len(v)}/{len(chars)}  p50 {pct(v, .5):.0f} ms  p95 {pct(v, .95):.0f} ms  max {pct(v, 1):.0f} ms")
for a in r:
    if not a["what"].startswith("char"):
        pp = {k: round(v * 1000) for k, v in a["per_pane"].items()}
        print(f"{a['t']:7.2f}  {a['what']:<28} first change {a['reaction'] and round(a['reaction'] * 1000)} ms  {pp}")
