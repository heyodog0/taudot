# review_capture_pixels.py FRAMES.txt (review_capture_scroll.sh): pixels only. In frames where the text moved, each card
# near a comment line: is it exactly at its line (card marker 2 pt below the line marker), a few pt off, or a row off.
import sys
from collections import Counter
def merge(v, w):
    out = []
    for y in sorted(v):
        if out and y - out[-1] < w: continue
        out.append(y)
    return out
c = Counter(); prev = None
for l in open(sys.argv[1]):
    p = l.split()
    if len(p) < 7: continue
    G = merge([float(x) for x in p[2].split(',') if x], 10); M = merge([float(x) for x in p[4].split(',') if x], 15)
    moved = prev is not None and M != prev; prev = M
    if not moved: continue
    for g in G:
        if g < 60 or not M: continue
        near = min(M, key=lambda z: abs(z - (g - 2)))
        r = g - 2 - near
        if -20 <= r <= 20:   # a card at (or near) a comment line; pushed cards are 30+ pt away
            c['exact (≤0.5 pt)' if abs(r) <= 0.5 else ('a row (15.5 pt)' if abs(abs(r) - 15.5) <= 1 else 'a few pt')] += 1
n = sum(c.values())
print(", ".join(f"{k} {v} ({100*v/n:.0f}%)" for k, v in c.most_common()), f"of {n}")
