"""Backend's own check loop: typeset with the harness's Txp (clients/render/harness/txp.py), then per page write the
MuPDF oracle PNG and the display list. Not a second harness: scores come from harness/run.

  uv run --with pillow --with numpy clients/render/swift/Scripts/drive.py DOC.tex OUTDIR [--scale S] [--pages 0,3]

Writes OUTDIR/p{N}.oracle.png, OUTDIR/p{N}.tdl and OUTDIR/drive.json (sizes and timings).
"""

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "harness"))
from txp import Txp  # noqa: E402


def main():
    a = argparse.ArgumentParser()
    a.add_argument("doc", type=Path)
    a.add_argument("out", type=Path)
    a.add_argument("--scale", type=float, default=2.0)
    a.add_argument("--pages", default="")
    a.add_argument("--no-oracle", action="store_true")
    o = a.parse_args()
    o.out.mkdir(parents=True, exist_ok=True)
    with Txp(o.doc.resolve()) as t:
        t0 = time.monotonic()
        ev = t.typeset()
        stats = {"typeset_s": round(time.monotonic() - t0, 2), "n": len(ev["sizes"]), "pages": []}
        pages = [int(x) for x in o.pages.split(",")] if o.pages else range(len(ev["sizes"]))
        for pg in pages:
            rec = {"page": pg}
            if not o.no_oracle:
                rec["render_cpu_us"] = t.render(pg, o.scale, o.out / f"p{pg}.oracle.png")["cpu_us"]
            rec["dlist"] = t.dlist(pg, o.out / f"p{pg}.tdl")
            stats["pages"].append(rec)
            print(json.dumps(rec), file=sys.stderr)
    (o.out / "drive.json").write_text(json.dumps(stats, indent=1))


if __name__ == "__main__":
    main()
