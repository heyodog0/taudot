"""Compare txp-render's MuPDF draw of a test document with mutool's draw of Tectonic's PDF, page by page.

    uv run --with numpy --with pillow --with scipy clients/render/texpresso/tests/compare.py tests/dash [--scale 1]
        [--txp PATH/txp-render] [--out DIR]

Builds in a scratch copy (DIR, default a temp folder) so the test folder stays clean. Prints, per page: differing
pixels (any channel off), pixels off by > 32 levels, and the harness's bad-pixel measure (measure.py). Writes
txp-N.png, tec-N.png and diff-N.png to DIR."""

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
RENDER = HERE.parent.parent
sys.path.insert(0, str(RENDER / "harness"))
from measure import bad_masks  # noqa: E402
from txp import Txp  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("test", type=Path)
    ap.add_argument("--scale", type=float, default=1.0)
    ap.add_argument("--txp", type=Path, default=RENDER / "txp-render")
    ap.add_argument("--out", type=Path)
    a = ap.parse_args()
    a.txp = a.txp.resolve()
    out = a.out or Path(tempfile.mkdtemp(prefix="txpcmp-"))
    work = out / "src"
    shutil.rmtree(work, ignore_errors=True)
    shutil.copytree(a.test, work)
    r = subprocess.run(["tectonic", "-c", "minimal", "main.tex"], cwd=work, capture_output=True, text=True)
    if r.returncode:
        sys.exit("tectonic failed:\n" + r.stderr[-2000:])
    dpi = 72 * a.scale
    subprocess.run(["mutool", "draw", "-q", "-r", str(dpi), "-c", "rgb", "-o", str(out / "tec-%d.png"),
                    str(work / "main.pdf")], check=True)
    for f in ("main.aux", "main.pdf", "main.log"):
        (work / f).unlink(missing_ok=True)
    with Txp(work / "main.tex", log=out / "txp.log", binary=a.txp) as t:
        t.typeset(timeout=120)
        n = len(t.pages["sizes"])
        for i in range(n):
            t.render(i, a.scale, out / f"txp-{i + 1}.png")
    print(f"{a.test.name}: {n} pages, scale {a.scale}, out {out}")
    worst = 0
    for i in range(1, n + 1):
        tp, mp = out / f"txp-{i}.png", out / f"tec-{i}.png"
        if not mp.exists():
            print(f"  p{i}: no Tectonic page"); worst = max(worst, 10**9); continue
        x = np.asarray(Image.open(tp).convert("RGB"), dtype=np.int16)
        y = np.asarray(Image.open(mp).convert("RGB"), dtype=np.int16)
        if x.shape != y.shape:
            print(f"  p{i}: size {x.shape} vs {y.shape}"); worst = max(worst, 10**9); continue
        d = np.abs(x - y).max(axis=2)
        fine, coarse = bad_masks(x.astype(np.float32), y.astype(np.float32))
        bad = int((fine | coarse).sum())
        print(f"  p{i}: differing {int((d > 0).sum())}, off>32 {int((d > 32).sum())}, bad {bad}")
        Image.fromarray(np.where(d[..., None] > 32, [255, 0, 0], x).astype(np.uint8)).save(out / f"diff-{i}.png")
        worst = max(worst, bad)
    return 0


if __name__ == "__main__":
    sys.exit(main())
