# review_floatscroll_pixels.py FRAMES.txt (review_floatscroll.sh): the floating card against its text, from pixels.
# The text's marker (magenta) is the comment range's last character; the card's (green) its top-left corner. In frames
# where the text moved and its marker is on screen, the card must keep its resting offset from it (the most common
# card − text offset, or the other side's). Counts exact (≤0.5 pt), a few pt, a row or more, and frames with the
# text on screen but no card ("hidden"). Other green (the status bar's dot) is ignored: the card is the green blob
# nearest a resting offset.
import sys
from collections import Counter
frames = []
for l in open(sys.argv[1]):
    p = l.split()
    if len(p) < 7: continue
    f = lambda s: [float(x) for x in s.split(',') if x]
    frames.append((float(p[0]), f(p[2]), f(p[4]), f(p[6])))
H = max((g for _, G, _, _ in frames for g in G), default=0)
offs = Counter()
for _, G, M, _ in frames:
    for g in G:
        for m in M[:1]:
            offs[round(g - m, 1)] += 1
if not offs:
    print("no frames with both markers"); sys.exit()
# the status bar's dot is at a fixed y, so its offset to a moving line varies: the card's offsets dominate
rest = [k for k, _ in offs.most_common(2)]
print("resting offsets (card − text):", ", ".join(f"{k:+.1f} pt ×{offs[k]}" for k in rest))
c = Counter(); prev = None; bad = []; flips = 0; side = None
for t, G, M, C in frames:
    key = (tuple(M), tuple(C))
    moved = prev is not None and key != prev
    prev = key
    if not M: continue
    m = M[0]
    best = min(((abs(g - m - k), k, g) for g in G for k in rest), default=None)
    s = best[1] if best and best[0] <= 0.5 else None
    if s is not None and side is not None and s != side: flips += 1
    if s is not None: side = s
    if not moved or m < 40: continue
    if best is None or best[0] > 60:
        c['hidden'] += 1; bad.append((t, 'hidden', m)); continue
    r = best[0]
    if r <= 0.5: c['exact (≤0.5 pt)'] += 1
    elif r < 12: c['a few pt'] += 1; bad.append((t, f'{r:+.1f}', m))
    else: c['a row or more'] += 1; bad.append((t, f'{r:+.1f}', m))
n = sum(c.values())
print(", ".join(f"{k} {v} ({100*v/n:.0f}%)" for k, v in c.most_common()), f"of {n} moving frames; side flips {flips}")
for b in bad[:10]: print("  off:", f"t={b[0]:.3f}", b[1], f"text y {b[2]:.0f}")
