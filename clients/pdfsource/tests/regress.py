# /// script
# requires-python = ">=3.11"
# ///
"""Quick regression check: prove a few corpus PDFs and compare with the proven counts they reached.

uv run tests/regress.py [--bin target-dev/release/pdfsource]
Needs TAUDOT_REF and the ground truth from tests/corpus.py. Exit 1 if any paper proves fewer paragraphs.
"""
import json, os, subprocess, sys
from pathlib import Path

R = Path(os.environ["TAUDOT_REF"])
CACHE = Path(os.environ.get("PDFSOURCE_CACHE", R / "pdfsource"))
HERE = Path(__file__).resolve().parent.parent

# paper: (pdf name, proven paragraphs reached) — one CM text, two-column CVPR, microtype + math, microtype + lists
CASES = {
    "synthetic-page": ("main.pdf", 3),
    "1512.03385": ("residual_v1_arxiv_release.pdf", 82),
    "2006.11239": ("main.pdf", 54),
    "1910.10683": ("20-074.pdf", 123),
    "1810.04805": ("main.pdf", 79),
    "2302.13971": ("acl2023.pdf", 178),
}

def main():
    args = sys.argv[1:]
    binary = HERE / (args[args.index("--bin") + 1] if "--bin" in args else "target-dev/release/pdfsource")
    bad = 0
    for paper, (pdf, want) in CASES.items():
        work = CACHE / "work-regress" / paper
        work.mkdir(parents=True, exist_ok=True)
        r = subprocess.run([str(binary), "prove", str(CACHE / "build" / paper / pdf), "--json"], capture_output=True,
                           text=True, env={**os.environ, "PDFSOURCE_WORK": str(work)})
        j = json.loads(r.stdout.strip().splitlines()[-1])
        ok = j["proven"] >= want
        bad += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {paper:16} {j['proven']}/{j['paras']} (want >= {want})  {j['ms_total']/1000:.1f}s", flush=True)
    sys.exit(1 if bad else 0)

if __name__ == "__main__":
    main()
