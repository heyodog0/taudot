# review_capture_geometry.py OUTDIR [LAG]: the editor's reported y(ofLine:) (margin trace) against where the line is
# drawn in the captured frames, for the comment lines on screen, LAG trace entries back (2 lines up best: ~1 frame).
import sys, re, bisect
from collections import Counter
d = sys.argv[1]; lag = int(sys.argv[2]) if len(sys.argv) > 2 else 2
tr = []
for l in open(d + '/margin.txt'):
    m = re.match(r'([\d.]+) place .*\| off (\S+) (\w+) vis (\d+)-(\d+) (.*)', l)
    if not m: continue
    tr.append((float(m[1]), int(m[4]), int(m[5]), {int(k[1]): float(k[2]) for k in re.finditer(r'L(\d+):(-?[\d.]+)/', m[6])}))
ts = [x[0] for x in tr]
def merge(v, w=15):
    out = []
    for y in sorted(v):
        if out and y - out[-1] < w: continue
        out.append(y)
    return out
c = Counter(); prevM = None; nmove = 0
for l in open(d + '/frames.txt'):
    p = l.split()
    if len(p) < 7: continue
    t = float(p[0]); M = merge([float(x) for x in p[4].split(',') if x])
    moved = prevM is not None and M != prevM; prevM = M
    if not moved: continue
    nmove += 1
    i = bisect.bisect_right(ts, t) - 1 - lag
    if i < 0: continue
    _, a, b, ys = tr[i]
    for L, y in ys.items():
        if a < L < b and M:
            r = min(M, key=lambda z: abs(z - (y + 32))) - (y + 32)
            if abs(r) <= 20:
                c['exact' if abs(r) <= 0.5 else ('one row' if abs(abs(r) - 15.5) <= 1 else 'partial')] += 1
n = sum(c.values())
print(f"moving frames {nmove}; drawn comment line vs reported y(ofLine): " + ", ".join(f"{k} {v} ({100*v/n:.0f}%)" for k, v in c.most_common()))
