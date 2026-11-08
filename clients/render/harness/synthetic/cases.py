"""The measure's synthetic cases: page.tex with one small change each, compiled by Tectonic, drawn by MuPDF. Each must
score clearly worse against the base page than the floor (the base page drawn by MuPDF and by Core Graphics)."""

import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import raster  # noqa: E402

HERE = Path(__file__).resolve().parent
CACHE = raster.RESULTS / "synthetic"

CASES = {   # name: (text in page.tex, its replacement)
    "base": None,
    "glyph-0.5pt": ("abc", r"a\kern0.5pt b\kern-0.5pt c"),                                # one glyph 0.5 pt right (1 px at 2x)
    "rule-missing": (r"\rule{4cm}{0.4pt}", r"\phantom{\rule{4cm}{0.4pt}}"),               # the rule gone, same layout
    "colour": (r"\textcolor{red}", r"\textcolor[rgb]{0.75,0,0}"),                       # red → a darker red
    "figure-1px": (r"\noindent\includegraphics", r"\noindent\hspace*{0.5pt}\includegraphics"),  # image 1 px right
}


def source(change: tuple | None) -> str:
    s = (HERE / "page.tex").read_text()
    if change:
        assert s.count(change[0]) == 1, change
        s = s.replace(change[0], change[1])
    return s


def build(name: str) -> Path:
    """The case's PDF (cached by its source)."""
    d = CACHE / name
    src = source(CASES[name])
    pdf = d / "page.pdf"
    if pdf.exists() and (d / "page.tex").read_text() == src:
        return pdf
    d.mkdir(parents=True, exist_ok=True)
    (d / "page.tex").write_text(src)
    shutil.copy(HERE / "blobs.png", d / "blobs.png")
    subprocess.run(["tectonic", "-c", "minimal", "page.tex"], cwd=d, check=True, capture_output=True)
    for sub in ("mu", "cg"):
        shutil.rmtree(d / sub, ignore_errors=True)
    return pdf


def renders(name: str) -> dict:
    """{"mu": png, "cg": png} for the case's one page."""
    pdf = build(name)
    d = pdf.parent
    if not (d / "mu/p0.png").exists():
        raster.mupdf(pdf, d / "mu")
    if not (d / "cg/p0.png").exists():
        raster.coregraphics(pdf, d / "cg")
    return {"mu": d / "mu/p0.png", "cg": d / "cg/p0.png"}
