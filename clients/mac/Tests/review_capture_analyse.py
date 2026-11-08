# review_capture_analyse.py FRAMES.txt: card motion against text motion in captured frames (review_capture_scroll.sh).
# Per frame pair: the text's movement (magenta + cyan line markers matched across frames), the cards' movement
# (green card markers), the difference. Per frame: each card's offset from the nearest comment line (2.0 pt when it
# sits at its line) and the gaps between cards.
import sys
from collections import Counter

TOP, BOTTOM = 60, None  # ignore markers in the title bar / header region

def merge(v, within=10.0):
    out = []
    for y in sorted(v):
        if out and y - out[-1] < within:
            continue
        out.append(y)
    return out

frames = []
for line in open(sys.argv[1]):
    p = line.split()
    if len(p) < 7:
        continue
    t = float(p[0]); g = [float(x) for x in p[2].split(',') if x] if p[1] == 'G' else []
    rest = p[3:]
    m = [float(x) for x in rest[1].split(',') if x] if len(rest) > 1 and rest[0] == 'M' else []
    c = [float(x) for x in rest[3].split(',') if x] if len(rest) > 3 and rest[2] == 'C' else []
    frames.append((t, merge([y for y in g if y > TOP]), merge([y for y in m if y > TOP]), merge([y for y in c if y > TOP])))

def shift(a, b):
    # The movement that maps most of a onto b (to 0.5 pt), and how many it maps.
    votes = Counter()
    for x in a:
        for y in b:
            d = y - x
            if abs(d) < 150:
                votes[round(d * 2) / 2] += 1
    if not votes:
        return None, 0
    d, n = votes.most_common(1)[0]
    # count with a 0.5 pt tolerance
    n = sum(v for k, v in votes.items() if abs(k - d) <= 0.5)
    return d, n

rows = []
moving = 0
for (t0, g0, m0, c0), (t1, g1, m1, c1) in zip(frames, frames[1:]):
    dt, nt = shift(m0 + c0, m1 + c1)
    dc, nc = shift(g0, g1)
    if dt is None or nt < 3 or dc is None or nc < 1:
        continue
    if dt != 0 or dc != 0:
        moving += 1
        rows.append((t1, dt, dc, dc - dt, len(g1)))

offs = []
for t, g, m, c in frames:
    for y in g:
        near = min(m, key=lambda z: abs(z - y), default=None)
        if near is not None and abs(y - near) < 3 * 16:
            offs.append(round((y - near) * 2) / 2)

bad = [r for r in rows if abs(r[3]) > 0.75]
print(f"frames {len(frames)}, frame pairs with motion {moving}")
print(f"card motion − text motion: |diff| > 0.75 pt in {len(bad)} of {len(rows)} moving pairs")
if rows:
    diffs = sorted(abs(r[3]) for r in rows)
    print(f"  |diff| p50 {diffs[len(diffs)//2]:.1f} p90 {diffs[int(len(diffs)*.9)]:.1f} max {diffs[-1]:.1f} pt")
for r in bad[:25]:
    print(f"  t {r[0]:.3f}: text {r[1]:+.1f} cards {r[2]:+.1f} diff {r[3]:+.1f} ({r[4]} cards)")
print("card − nearest comment line (2.0 = at its line):", sorted(Counter(offs).items(), key=lambda kv: -kv[1])[:8])
