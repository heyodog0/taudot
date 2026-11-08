# review_capture_motion.py FRAMES.txt (review_capture_scroll.sh): stricter than review_capture_pixels.py. In each pair
# of frames where the text moved by d (the line markers' shift), every card marker either moved by exactly d (with
# the text), moved by something else (jitter: held under the top, pushed, re-stacked), or appeared / vanished at an
# edge (pops). The share "with the text" is what the eye reads as smooth.
import sys
from collections import Counter

def merge(v, w):
    out = []
    for y in sorted(v):
        if out and y - out[-1] < w: continue
        out.append(y)
    return out

def shift(a, b):
    # the text's move: the shift that matches the most markers
    best, n = None, 0
    for x in a:
        for y in b:
            d = y - x
            k = sum(1 for p in a if any(abs(p + d - q) <= 0.5 for q in b))
            if k > n: best, n = d, k
    return best

c = Counter(); prev = None
for l in open(sys.argv[1]):
    p = l.split()
    if len(p) < 7: continue
    G = merge([float(x) for x in p[2].split(',') if x], 10)
    T = merge([float(x) for x in (p[4] + ',' + p[6]).split(',') if x], 8)
    if prev is not None:
        G0, T0 = prev
        if T and T0 and T != T0:
            d = shift(T0, T)
            if d is not None and abs(d) > 0.5:
                for g in G:
                    if any(abs(g0 + d - g) <= 0.5 for g0 in G0): c['with the text'] += 1
                    elif any(abs(g0 - g) <= 40 + abs(d) for g0 in G0): c['jitter'] += 1
                    else: c['pop'] += 1
                for g0 in G0:
                    if not any(abs(g0 + d - g) <= 40 + abs(d) for g in G): c['pop'] += 1
    prev = (G, T)
n = sum(c.values()) or 1
print(", ".join(f"{k} {v} ({100 * v / n:.1f}%)" for k, v in c.most_common()), f"of {n} card-frames")
