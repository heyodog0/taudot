# MIT. Per edit, from tau-live's TAU_LIVE_LOG: resume, pages shipped, finisher start and end (ms after the edit).
import sys

t0 = seq = None
rows = {}
for line in open(sys.argv[1]):
    e = line.split()
    t = int(e[0])
    if e[1] == "apply":
        t0, seq = t, e[3]
        rows[seq] = [f"snap#{e[6].strip('(')}/{e[8].strip(')')}"]
        continue
    if t0 is None or len(e) < 5 or e[4] != seq:
        continue
    k, r = e[2], rows[seq]
    ms = lambda x: f"{(int(x) - t0) / 1000:.1f}"
    if k == "R":
        r.append(f"R+{ms(e[6])}")
    elif k == "S":
        r.append("s")
    elif k == "p":
        r.append(f"p{e[5]}+{ms(e[6])}")
    elif k == "F":
        r.append(f"F+{ms(e[6])}")
    elif k == "E" and e[-1] == "fin" and not any(x.startswith("Efin") for x in r):
        r.append(f"Efin+{ms(e[6])}")
for s, r in rows.items():
    print(s, " ".join(r).replace("s s", "ss")[:220])
