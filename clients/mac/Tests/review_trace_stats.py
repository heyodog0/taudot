# Summarize a TAUDOT_MARGIN_TRACE file: place() cost (median, p95, max, frames over 2 ms), cards on screen next to
# their visible lines (per frame), how far they sit from their line (0 = beside it; large = pushed down a long stack),
# and stacking jumps (a card at rest whose offset from its line changes between frames, the cursor not moving it).
#   uv run --no-project Tests/review_trace_stats.py OUT/margin.txt [-v]
import re, sys, statistics as st
costs, jumps, frames, last, onscreen, offs, events = [], 0, 0, {}, [], [], []
for line in open(sys.argv[1]):
    m = re.search(r"^([\d.]+) place ([\d.]+) ms top \S+ shown \d* ?(.*?)( \| |$)", line)
    if not m: continue
    frames += 1
    costs.append(float(m.group(2)))
    now = {k: float(v) for k, v in re.findall(r"(\S+)=(-?[\d.]+)", m.group(3))}
    onscreen.append(len(now))
    offs += [abs(v) for v in now.values()]
    for k, v in now.items():
        if k in last and abs(v - last[k]) > 0.5:
            jumps += 1
            events.append(f"{m.group(1)} {k} {last[k]:.1f} -> {v:.1f}")
    last = now
costs.sort()
q = lambda a, p: a[min(len(a) - 1, int(p * len(a)))]
print(f"frames {frames}  place median {st.median(costs):.3f} ms  p95 {q(costs, 0.95):.3f}  max {costs[-1]:.3f}  >2ms {sum(c > 2 for c in costs)}")
vis = [n for n in onscreen if n]
print(f"cards beside visible lines: in {len(vis)} of {frames} frames, median {st.median(vis) if vis else 0} per frame;"
      f" offset from the line median {st.median(offs) if offs else 0:.0f} pt, p95 {q(sorted(offs), 0.95) if offs else 0:.0f} pt;  jumps {jumps}")
if "-v" in sys.argv:
    print("\n".join(events[:30]))
