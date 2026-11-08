"""The chosen wordmark (round 1's "Hand"), outlined, with its lockups. Writes final/wordmark/.

Strokes are expanded and unioned into one filled outline (skia-pathops), so the files render the same everywhere and
translucent inks never double up. The dot stays a circle.

Run: uv run --with pillow --with fonttools --with uharfbuzz --with skia-pathops docs/design/logo/build_wordmark_final.py
"""

import re
import subprocess

import pathops
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.svgLib.path import parse_path

import build_wordmark as wm

OUT = wm.HERE / "final" / "wordmark"
INKS = {  # name: (ink, dot, background for the preview PNG)
    "light": (wm.INK_LIGHT, wm.CORAL, wm.BG_LIGHT),
    "dark": (wm.INK_DARK, wm.CORAL, wm.BG_DARK),
    "mono": ("#000", "#000", "#ffffff"),  # one colour: templates, embossing, single-ink print
}


def outline(body):
    """The stroked <path>s of a hand() body as one union, plus the body's circles, untouched."""
    union = pathops.Path()
    for m in re.finditer(r'<path(?: transform="translate\(([-\d.]+) 0\)")? d="([^"]+)" stroke-width="([\d.]+)"/>', body):
        dx, d, w = float(m.group(1) or 0), m.group(2), float(m.group(3))
        p = pathops.Path()
        parse_path(d, p.getPen())
        p.stroke(w, pathops.LineCap.ROUND_CAP, pathops.LineJoin.ROUND_JOIN, 4)
        p.convertConicsToQuads()
        p = p.transform(1, 0, 0, 1, dx, 0)
        union = pathops.op(union, p, pathops.PathOp.UNION)
    pen = SVGPathPen(None)
    union.draw(pen)
    circles = re.findall(r"<circle [^>]*/>", body)
    return f'<path fill="INK" d="{pen.getCommands()}"/>' + "".join(circles)


def lockup(word, bbox):
    """The flat mark beside the word (no period: the mark carries the dot)."""
    return wm.mark_lockup(word, bbox, 0)


def write(name, body, bbox, height=None):
    for v, (ink, dot, bg) in INKS.items():
        s, _ = wm.svg(body, bbox, ink, dot, pad=0.06)
        (OUT / f"{name}-{v}.svg").write_text(s)
        for h in height or (64, 256):
            png = OUT / f"{name}-{v}-{h}.png"
            subprocess.run(["resvg", "-h", str(h), str(OUT / f"{name}-{v}.svg"), str(png)], check=True)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for p in OUT.glob("*"):
        p.unlink()
    body, bbox = wm.hand()
    word = outline(body)
    write("wordmark", word, bbox, (32, 64, 256))
    nb, nbb = wm.hand(period=False)
    mb, mbb = lockup(outline(nb), nbb)
    write("lockup", mb, mbb, (32, 64, 256))
    # A preview of everything, for the log and notes.
    from PIL import Image
    tiles = []
    for v, (_i, _d, bg) in INKS.items():
        for n in ("wordmark", "lockup"):
            im = Image.open(OUT / f"{n}-{v}-256.png").convert("RGBA")
            t = Image.new("RGBA", (im.width + 80, im.height + 60), bg)
            t.alpha_composite(im, (40, 30))
            tiles.append(t)
    W = max(t.width for t in tiles)
    sheet = Image.new("RGBA", (W, sum(t.height for t in tiles)), (255, 255, 255, 255))
    y = 0
    for t in tiles:
        sheet.alpha_composite(t, (0, y))
        y += t.height
    sheet.convert("RGB").save(OUT / "preview.png")
    print("ok", OUT)


if __name__ == "__main__":
    main()
