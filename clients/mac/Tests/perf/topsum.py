"""Summarise `top -l N -s 1 -stats pid,ppid,command,cpu,csw,power,mem` (every process, once a second) for one
process tree: the app (ROOT pid) and all its descendants as they come and go, plus EXTRA pids (the engine).

Per process name (children of the same name, e.g. TeXpresso's xetex forks, are added up per sample):
  cpu      % of one core, mean and p95 over the samples
  wakeups  context switches per second (top's CSW is cumulative: the delta between samples), mean and p95.
           A process that does nothing has ~0; each timer firing, display-link frame or pipe read costs >= 1.
  power    top's energy impact, mean
  rss      the last sample's memory (MB), added up per name
The first sample is dropped (top has no interval for it).

  uv run clients/mac/Tests/perf/topsum.py top.txt ROOT [EXTRA,...] [NAME:FROM:TO ...]   (FROM, TO: seconds since the first sample, by its clock line)
"""
import re
import sys
from collections import defaultdict


def mem_mb(s: str) -> float:
    m = re.match(r"([\d.]+)([BKMG])?", s.rstrip("+-"))
    if not m:
        return 0
    return float(m.group(1)) * {"B": 1 / 2**20, "K": 1 / 1024, "M": 1, "G": 1024, None: 1 / 2**20}[m.group(2)]


def parse(path):
    samples, cur, when = [], None, None
    for l in open(path):
        m = re.match(r"\d{4}/\d\d/\d\d (\d\d):(\d\d):(\d\d)", l)
        if m:
            when = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
            continue
        if l.startswith("PID"):
            cur = {"_t": when}
            samples.append(cur)
            continue
        f = l.split()
        if cur is None or len(f) < 7 or not f[0].isdigit():
            continue
        # COMMAND may hold spaces: the last four columns are cpu, csw, power, mem.
        cur[int(f[0])] = dict(ppid=int(f[1]), name=" ".join(f[2:-4]), cpu=float(f[-4]),
                              csw=int(f[-3].rstrip("+-")), power=float(f[-2]), mem=mem_mb(f[-1]))
    return samples


def tree(sample, roots):
    keep, grew = set(r for r in roots if r in sample), True
    while grew:
        grew = False
        for p, r in sample.items():
            if p == "_t":
                continue
            if p not in keep and r["ppid"] in keep:
                keep.add(p)
                grew = True
    return keep


def summarise(samples, roots, extra, lo, hi):
    per = defaultdict(lambda: defaultdict(lambda: [0.0, 0.0, 0.0, 0.0]))  # name -> sample index -> cpu, csw, power, mem
    for i in range(1, len(samples)):
        prev, s = samples[i - 1], samples[i]
        dt = max(1, (s["_t"] or 0) - (prev["_t"] or 0)) if s["_t"] and prev["_t"] else 1
        if not (lo <= (s["_t"] or 0) - (samples[0]["_t"] or 0) < hi):
            continue
        for p in tree(s, roots) | (set(extra) & s.keys()):
            r = s[p]
            name = "app" if p in roots else ("engine" if p in extra else r["name"])
            v = per[name][i]
            v[0] += r["cpu"]
            v[1] += max(0, r["csw"] - prev[p]["csw"]) / dt if p in prev else 0
            v[2] += r["power"]
            v[3] += r["mem"]
    print("process\tcpu_mean\tcpu_p95\twakeups_mean\twakeups_p95\tpower_mean\trss_mb\tsamples")
    for name, by in sorted(per.items(), key=lambda kv: -sum(v[0] for v in kv[1].values())):
        rows = [by[i] for i in sorted(by)]
        def stat(k):
            v = sorted(r[k] for r in rows)
            return sum(v) / len(v), v[min(len(v) - 1, int(0.95 * len(v)))]
        c, w, pw = stat(0), stat(1), stat(2)
        print(f"{name}\t{c[0]:.1f}\t{c[1]:.1f}\t{w[0]:.1f}\t{w[1]:.0f}\t{pw[0]:.1f}\t{rows[-1][3]:.0f}\t{len(rows)}")


def main(path, root, extra="", *phases):
    samples = parse(path)
    roots, ex = [int(root)], [int(x) for x in extra.split(",") if x]
    if not phases:
        phases = [f"all:0:{len(samples)}"]
    for ph in phases:
        n, a, b = ph.split(":")
        print(f"# {n} ({a}-{b} s)")
        summarise(samples, roots, ex, int(a), int(b))


if __name__ == "__main__":
    main(*sys.argv[1:])
