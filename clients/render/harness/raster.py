"""PDF → PNG pages two ways, for the floor: MuPDF (`mutool draw`) and Core Graphics (`cgraster.swift`, compiled once
into the results folder). Both at the same scale, white background, RGB, files p<N>.png with N 0-based."""

import hashlib
import shutil
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
RESULTS = Path.home() / "code/lab/taudot-ref/corpus-results"


def cgraster_bin() -> Path:
    src = HERE / "cgraster.swift"
    h = hashlib.sha256(src.read_bytes()).hexdigest()[:12]
    b = RESULTS / "bin" / f"cgraster-{h}"
    if not b.exists():
        b.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-O", "-o", str(b), str(src)], check=True, capture_output=True)
    return b


def mupdf(pdf: Path, out: Path, scale: float = 2.0, pages: list[int] | None = None) -> None:
    out.mkdir(parents=True, exist_ok=True)
    sel = ",".join(str(p + 1) for p in pages) if pages else "1-N"
    tmp = out / "_mu"
    tmp.mkdir(exist_ok=True)
    subprocess.run(["mutool", "draw", "-q", "-r", str(72 * scale), "-c", "rgb", "-o", str(tmp / "p%d.png"), str(pdf), sel],
                   check=True, capture_output=True)
    for f in tmp.iterdir():   # mutool numbers from 1
        n = int(f.stem[1:]) - 1
        f.replace(out / f"p{n}.png")
    shutil.rmtree(tmp)


def coregraphics(pdf: Path, out: Path, scale: float = 2.0, pages: list[int] | None = None) -> None:
    out.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(cgraster_bin()), str(pdf), str(out), str(scale), *map(str, pages or [])], check=True,
                   capture_output=True)


def pdf_pages(pdf: Path) -> int:
    r = subprocess.run(["mutool", "info", str(pdf)], capture_output=True, text=True)
    for line in r.stdout.splitlines():
        if line.startswith("Pages:"):
            return int(line.split()[1])
    return 0
