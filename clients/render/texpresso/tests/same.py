"""Check two txp-render builds draw a document identically, page by page (raw RGB at scale 1).

    uv run --with numpy --with pillow clients/render/texpresso/tests/same.py OLD_TXP NEW_TXP DOC_DIR MAIN.tex [--scale 1]

DOC_DIR is copied to a temp folder for each build, so the source stays untouched. Exit 0 when every page matches."""

import argparse
import hashlib
import shutil
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent / "harness"))
from txp import Txp  # noqa: E402


def draw(binary: Path, doc: Path, main: str, scale: float) -> list[str]:
    with tempfile.TemporaryDirectory(prefix="txpsame-") as tmp:
        work = Path(tmp) / "doc"
        shutil.copytree(doc, work)
        with Txp(work / main, binary=binary) as t:
            t.typeset(timeout=600)
            out = []
            for i in range(len(t.pages["sizes"])):
                png = Path(tmp) / f"p{i}.png"
                t.render(i, scale, png)
                from PIL import Image
                out.append(hashlib.sha256(Image.open(png).tobytes()).hexdigest())
            return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("old", type=Path)
    ap.add_argument("new", type=Path)
    ap.add_argument("doc", type=Path)
    ap.add_argument("main")
    ap.add_argument("--scale", type=float, default=1.0)
    a = ap.parse_args()
    a.old, a.new, a.doc = a.old.resolve(), a.new.resolve(), a.doc.resolve()
    old, new = draw(a.old, a.doc, a.main, a.scale), draw(a.new, a.doc, a.main, a.scale)
    diff = [i + 1 for i, (x, y) in enumerate(zip(old, new)) if x != y]
    print(f"{a.doc.name}: old {len(old)} pages, new {len(new)} pages, differing pages: {diff or 'none'}")
    return 0 if len(old) == len(new) and not diff else 1


if __name__ == "__main__":
    sys.exit(main())
