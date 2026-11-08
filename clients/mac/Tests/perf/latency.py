# /// script
# dependencies = ["numpy"]
# ///
"""The app's latency probes (Sources/TaudotShared/Latency.swift) from a keys.sh run, per stage, and the outside check.

  uv run clients/mac/Tests/perf/latency.py OUT [--json] [--from SECONDS] [--keys]

Editor chain, ms from the key event: handed (keyDown returned), model (text / grid updated), committed (the CA
transaction with the change committed, or the Metal frame encoded), presented (on glass: Metal's present time, or for
AppKit the refresh the commit went out with).
PDF chain, ms from the key: typesetSent (the edit reached the typesetter), typesetRun (the driver started the run that
has it), pdfReady (a PDF / pages event with it), pageShown (a page in view swapped in).
Outside: the first changed frame of the editor pane after each typed character (probe's capture), next to the app's
`presented` for the same key; `gap` = outside - presented.
Long turns: main-thread run-loop turns over 12 ms, with the stage events and sections inside them.
"""
import json
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

EDITOR = ["handed", "model", "committed", "presented"]
PDF = ["typesetSent", "typesetRun", "pdfReady", "pageShown"]


def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(q * (len(v) - 1) + 0.5))] if v else float("nan")


def stats(v):
    return {"n": len(v), "p50": pct(v, .5), "p95": pct(v, .95), "p99": pct(v, .99), "max": max(v) if v else float("nan")}


def load(path: Path):
    rows = []
    for l in path.read_text().splitlines():
        if l.startswith("#") or not l.strip():
            continue
        f = l.split("\t")
        rows.append((float(f[0]), f[1], int(f[2]), int(f[3]), f[4] if len(f) > 4 else ""))
    return rows


def editor_chain(rows, t_from=0.0):
    keys = {}
    for t, p, k, v, _ in rows:
        if p == "keyDown" and t >= t_from:
            keys[k] = {"t": t}
    for t, p, k, v, _ in rows:
        if p in EDITOR and k in keys and p not in keys[k]:
            keys[k][p] = t
    return keys


def pdf_chain(rows, keys):
    """For each key: its edit reaching the typesetter (the first typesetSent at or after it, whose value is the
    typesetter's command count n), the first run and PDF whose `applied` count reaches n, and the first page swapped
    in after that PDF."""
    ev = [(t, p, k, v) for t, p, k, v, _ in rows if p in PDF]
    out = {}
    for k, d in keys.items():
        r = {}
        sent = next(((t, v) for t, p, kk, v in ev if p == "typesetSent" and kk == k and t >= d["t"]), None)
        if sent:
            r["typesetSent"] = sent[0]
            for stage in ("typesetRun", "pdfReady"):
                x = next((t for t, p, kk, v in ev if p == stage and t >= sent[0] and v >= sent[1]), None)
                if x is not None:
                    r[stage] = x
            if "pdfReady" in r:
                x = next((t for t, p, kk, v in ev if p == "pageShown" and t >= r["pdfReady"]), None)
                if x is not None:
                    r["pageShown"] = x
        out[k] = r
    return out


def outside(run: Path, keys):
    """Per key: (outside glyph time, in-app presented), host seconds; matched in order of the typed characters."""
    from analyse import analyse
    d = run / "drive"
    if not (d / "frames.bin").exists():
        return []
    t0 = float((d / "clock.txt").read_text())
    acts = [a for a in analyse(d).get("actions", []) if a["what"].startswith("char")]
    # keyDowns in the app, in order, from the first typed character on
    first = t0 + acts[0]["t"] if acts else 0
    ks = sorted((v["t"], k) for k, v in keys.items() if v["t"] >= first - 0.05)
    pairs = []
    for a, (kt, k) in zip(acts, ks):
        sent = t0 + a["t"]
        glyph = a["per_pane"].get("editor")
        pres = keys[k].get("presented")
        pairs.append({"key": k, "sent": sent, "keyDown": kt, "outside": None if glyph is None else sent + glyph, "presented": pres})
    return pairs


def long_turns(rows):
    out = []
    starts = [t for t, p, *_ in rows if p == "turnStart"]
    for t, p, k, v, _ in rows:
        if p != "longTurn":
            continue
        a = max([s for s in starts if s <= t] or [t - v / 1e6])
        inside = [(round((tt - a) * 1000, 1), pp, lab or kk, vv) for tt, pp, kk, vv, lab in rows
                  if a <= tt <= t and pp not in ("turnStart", "longTurn")]
        out.append({"start": a, "ms": v / 1000, "inside": inside[:12]})
    return out


def main():
    args = sys.argv[1:]
    run = Path(args[0])
    t_from = float(args[args.index("--from") + 1]) if "--from" in args else 0.0
    rows = load(run / "latency.tsv")
    keys = editor_chain(rows, t_from)
    pdf = pdf_chain(rows, keys)
    res = {"keys": len(keys), "editor": {}, "pdf": {}, "raw": {}}
    for s in EDITOR:
        res["raw"][s] = [(d[s] - d["t"]) * 1000 for d in keys.values() if s in d]
        res["editor"][s] = stats(res["raw"][s])
    for s in PDF:
        res["raw"][s] = [(pdf[k][s] - keys[k]["t"]) * 1000 for k in keys if s in pdf[k]]
        res["pdf"][s] = stats(res["raw"][s])
    pairs = outside(run, keys)
    if pairs:
        o = [(p["outside"] - p["sent"]) * 1000 for p in pairs if p["outside"]]
        gap = [(p["outside"] - p["presented"]) * 1000 for p in pairs if p["outside"] and p["presented"]]
        lag = [(p["keyDown"] - p["sent"]) * 1000 for p in pairs]
        res["outside"] = {"glyph": stats(o), "gap_outside_minus_presented": stats(gap), "event_post_to_keyDown": stats(lag)}
        res["raw"]["outside"] = o
        res["raw"]["gap"] = gap
    lt = long_turns(rows)
    res["long_turns"] = {"n": len(lt), "ms": stats([x["ms"] for x in lt])}
    res["raw"]["longTurn"] = [x["ms"] for x in lt]
    sec = defaultdict(list)
    for t, p, k, v, lab in rows:
        if p == "section":
            sec[lab].append(v / 1000)
    res["sections"] = {k: stats(v) for k, v in sec.items()}
    if "--json" in args:
        print(json.dumps(res))
        return
    f = lambda s: f"n {s['n']:4d}  p50 {s['p50']:7.1f}  p95 {s['p95']:7.1f}  p99 {s['p99']:7.1f}  max {s['max']:7.1f}"
    print(f"{run}: {len(keys)} keys")
    for s in EDITOR:
        print(f"  key → {s:<12} {f(res['editor'][s])}")
    for s in PDF:
        print(f"  key → {s:<12} {f(res['pdf'][s])}")
    if "outside" in res:
        for k, v in res["outside"].items():
            print(f"  {k:<30} {f(v)}")
    print(f"  long turns (> 12 ms): {f(res['long_turns']['ms'])}")
    for k, v in sorted(res["sections"].items(), key=lambda kv: -kv[1]["max"]):
        print(f"  section {k:<24} {f(v)}")
    if "--keys" in args:
        for k, d in sorted(keys.items()):
            print(k, " ".join(f"{s}={(d[s] - d['t']) * 1000:.1f}" for s in EDITOR if s in d),
                  " ".join(f"{s}={(pdf[k][s] - d['t']) * 1000:.0f}" for s in PDF if s in pdf[k]))
    for x in lt:
        print(f"  long turn {x['ms']:.1f} ms at {x['start']:.3f}: {x['inside']}")


if __name__ == "__main__":
    main()
