# /// script
# requires-python = ">=3.11"
# ///
"""Run `pdfsource prove --json` on every ground-truth PDF and summarise.

uv run tests/measure.py [paper...]     (needs `cargo build --release` and tests/corpus.py build first)
Results: $PDFSOURCE_CACHE/results/<paper>.json and a summary on stdout.
"""
import json, os, shutil, subprocess, sys, time
from collections import Counter
from pathlib import Path

R = Path(os.environ["TAUDOT_REF"])  # the reference tree: corpus, texlive-2026, universal engines
CACHE = Path(os.environ.get("PDFSOURCE_CACHE", R / "pdfsource"))
BIN = Path(os.environ.get("PDFSOURCE_BIN", Path(__file__).resolve().parent.parent / "target/release/pdfsource"))

# Not ground truth: their main file only includes a prebuilt PDF of the paper (pdfpages).
SUMMARY = False
EXCLUDE = {"1412.6980", "1707.06347"}

def pdf_of(paper):
    d = CACHE / "build" / paper
    logs = [p for p in d.glob("*.pdf") if (d / (p.stem + ".tex")).exists() and (d / (p.stem + ".log")).exists()]
    return logs[0] if logs else None

def main(papers):
    out = CACHE / "results"
    out.mkdir(parents=True, exist_ok=True)
    papers = papers or sorted(p.name for p in (CACHE / "build").iterdir() if p.is_dir())
    tot = Counter()
    reasons = Counter()
    phases = Counter()
    rows = []
    for p in papers:
        if p in EXCLUDE:
            continue
        pdf = pdf_of(p)
        if not pdf:
            continue
        if SUMMARY:
            f = out / f"{p}.json"
            if not f.exists():
                continue
            j = json.loads(f.read_text())
        else:
          work = CACHE / "work" / p
          work.mkdir(parents=True, exist_ok=True)
          t = time.time()
          try:
            r = subprocess.run([str(BIN), "prove", str(pdf), "--json"], capture_output=True, text=True, timeout=1800,
                               env={**os.environ, "PDFSOURCE_WORK": str(work)})
            j = json.loads(r.stdout.strip().splitlines()[-1])
          except Exception as e:
            print(f"{p}: failed {e}", flush=True)
            continue
          j["wall_s"] = time.time() - t
          if not os.environ.get("PDFSOURCE_KEEP"):
              shutil.rmtree(work, ignore_errors=True)  # the batches' PDFs (disk is tight)
          (out / f"{p}.json").write_text(json.dumps(j))
        for k in ("paras", "proven", "lines", "lines_proven", "words", "words_proven", "pages", "doc_lines"):
            tot[k] += j[k]
        # Displayed formulas are reported on their own; text totals leave them out.
        for d in j.get("detail", []):
            if d.get("kind") == "display":
                tot["disp"] += 1
                tot["disp_proven"] += d["proven"]
                tot["paras"] -= 1
                tot["proven"] -= d["proven"]
                tot["lines"] -= d["lines"]
                tot["lines_proven"] -= d["lines"] * d["proven"]
                tot["words"] -= d.get("words", 0)
                tot["words_proven"] -= d.get("words", 0) * d["proven"]
        tot["ms"] += j["ms_total"]
        for k, v in j.get("ms", {}).items():
            phases[k] += v
        rc = j.get("recheck", [0, 0])
        tot["recheck"] += rc[0]
        tot["recheck_ok"] += rc[1]
        for d in j.get("detail", []):
            if d.get("lines", 0) >= 2 and d.get("kind") != "display":
                tot["multi"] += 1
                tot["multi_proven"] += d["proven"]
        reasons.update(j["reasons"])
        rows.append((p, j))
        print(f"{p:16} {j['pages']:3}p  paras {j['proven']:4}/{j['paras']:<4} ({100*j['proven']/max(1,j['paras']):5.1f}%)  "
              f"lines {j['lines_proven']:5}/{j['lines']:<5}  {j['ms_total']/1000:6.1f}s  {j['reasons']}", flush=True)
    if not rows:
        return
    print(f"\nALL {len(rows)} papers, {tot['pages']} pages: paragraphs {tot['proven']}/{tot['paras']} "
          f"({100*tot['proven']/tot['paras']:.1f}%), lines {tot['lines_proven']}/{tot['lines']} "
          f"({100*tot['lines_proven']/tot['lines']:.1f}%), words {tot['words_proven']}/{tot['words']} "
          f"({100*tot['words_proven']/tot['words']:.1f}%); body lines {tot['lines']} of {tot['doc_lines']} text lines; "
          f"{tot['ms']/tot['paras']:.0f} ms/paragraph, {tot['ms']/tot['pages']:.0f} ms/page")
    if tot["multi"]:
        print(f"paragraphs of 2+ lines: {tot['multi_proven']}/{tot['multi']} ({100*tot['multi_proven']/tot['multi']:.1f}%)")
    if tot["disp"]:
        print(f"displays: {tot['disp_proven']}/{tot['disp']} ({100*tot['disp_proven']/tot['disp']:.1f}%)")
    if phases:
        print("time (ms/paragraph): " + ", ".join(f"{k} {v/tot['paras']:.1f}" for k, v in sorted(phases.items(), key=lambda e: -e[1])))
    if tot["recheck"]:
        print(f"stock pdfLaTeX recheck of proven paragraphs: {tot['recheck_ok']}/{tot['recheck']} agree")
    for k, v in reasons.most_common():
        print(f"  {v:5}  {k}")

if __name__ == "__main__":
    SUMMARY = "--summary" in sys.argv
    main([a for a in sys.argv[1:] if a != "--summary"])
