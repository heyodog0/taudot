"""Summaries of run.sh's runs: per editor mode, PDF path and script, the latency stages pooled over the runs.

  uv run clients/mac/Tests/perf/benchsum.py OUT [--commit C] [--load L] [--write clients/mac/Tests/perf/README.md]
  uv run clients/mac/Tests/perf/benchsum.py --compare OUT/A OUT/B [--margin PCT] [--labels A B]

Each run dir is MODE-ENGINE-SCRIPT-K with latency.json (latency.py --json). --write replaces the text between
`<!-- bench:begin -->` and `<!-- bench:end -->` in the given file. --compare writes 0/1 to OUT/compare.status: 1 when
B's key → presented or key → committed p95 or p99 is worse than A's by more than PCT % and 2 ms in any group.
"""
import json
import sys
from collections import defaultdict
from pathlib import Path

STAGES = ["committed", "presented", "typesetSent", "pdfReady", "pageShown", "outside", "gap"]
NAMES = {"committed": "key → committed", "presented": "key → presented", "typesetSent": "key → typesetter",
         "pdfReady": "key → PDF ready", "pageShown": "key → page shown", "outside": "outside: key → glyph",
         "gap": "outside − presented"}


def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(q * (len(v) - 1) + 0.5))] if v else float("nan")


def groups(out: Path):
    g = defaultdict(lambda: defaultdict(list))
    runs = defaultdict(int)
    for d in sorted(out.iterdir()):
        f = d / "latency.json"
        if not d.is_dir() or not f.exists():
            continue
        try:
            r = json.loads(f.read_text())
        except json.JSONDecodeError:
            continue
        key = d.name.rsplit("-", 1)[0]
        runs[key] += 1
        for s, v in r.get("raw", {}).items():
            g[key][s] += v
    return g, runs


def fmt(v):
    if not v:
        return "–"
    return f"{pct(v, .5):.1f} / {pct(v, .95):.1f} / {pct(v, .99):.1f} / {max(v):.1f}"


def table(g, runs):
    lines = ["| mode · PDF · script | runs | keys | " + " | ".join(NAMES[s] for s in STAGES) + " | turns > 12 ms (n, max) |",
             "|" + "---|" * (len(STAGES) + 4)]
    for key in sorted(g):
        v = g[key]
        lt = v.get("longTurn", [])
        lines.append(f"| {key.replace('-', ' · ')} | {runs[key]} | {len(v.get('presented', []))} | "
                     + " | ".join(fmt(v.get(s, [])) for s in STAGES) + f" | {len(lt)}, {max(lt) if lt else 0:.0f} |")
    return "\n".join(lines)


def main():
    a = sys.argv[1:]
    if "--compare" in a:
        i = a.index("--compare")
        A, B = Path(a[i + 1]), Path(a[i + 2])
        margin = float(a[a.index("--margin") + 1]) if "--margin" in a else 15
        la, lb = (a[a.index("--labels") + 1], a[a.index("--labels") + 2]) if "--labels" in a else ("A", "B")
        ga, ra = groups(A)
        gb, rb = groups(B)
        bad = []
        print(f"# {la} (A) vs {lb} (B), p50 / p95 / p99 / max ms\n")
        print("| group | stage | A | B | verdict |\n|---|---|---|---|---|")
        for key in sorted(set(ga) | set(gb)):
            for s in ["committed", "presented", "pageShown", "outside"]:
                va, vb = ga[key].get(s, []), gb[key].get(s, [])
                verdict = ""
                if s in ("committed", "presented") and va and vb:
                    for q in (.95, .99):
                        x, y = pct(va, q), pct(vb, q)
                        if y > x * (1 + margin / 100) and y - x > 2:
                            verdict = f"worse at p{int(q * 100)}"
                            bad.append((key, s, q))
                        elif x > y * (1 + margin / 100) and x - y > 2 and not verdict:
                            verdict = f"better at p{int(q * 100)}"
                print(f"| {key} | {NAMES[s]} | {fmt(va)} | {fmt(vb)} | {verdict} |")
        status = 1 if bad else 0
        print(f"\n{'FAIL' if bad else 'ok'}: margin {margin} % and 2 ms; {len(bad)} regressions")
        (A.parent / "compare.status").write_text(str(status))
        return
    out = Path(a[0])
    g, runs = groups(out)
    commit = a[a.index("--commit") + 1] if "--commit" in a else "?"
    load = a[a.index("--load") + 1] if "--load" in a else "?"
    text = (f"**run.sh at {commit}**, load average {load}. ms, p50 / p95 / p99 / max, pooled over the runs. "
            "In-app stages from the app's probes (Latency.swift); outside from the off-screen window capture.\n\n"
            + table(g, runs))
    print(text)
    if "--write" in a:
        f = Path(a[a.index("--write") + 1])
        s = f.read_text()
        b, e = "<!-- bench:begin -->", "<!-- bench:end -->"
        if b in s and e in s:
            s = s[:s.index(b) + len(b)] + "\n" + text + "\n" + s[s.index(e):]
        else:
            s += f"\n{b}\n{text}\n{e}\n"
        f.write_text(s)


if __name__ == "__main__":
    main()
