"""The Taudot wordmark: directions on a contact sheet.

The hand-drawn ones are round-capped monoline strokes in the mark's hand: the T is the mark's tau (same curves),
the lowercase is geometric with the t's foot curling like the tau's stem. The set ones use open fonts (OFL) for
comparison; Apple's SF and New York aren't licensed for logos, so they're not used.

Run: uv run --with pillow --with fonttools --with uharfbuzz docs/design/logo/build_wordmark.py   (needs `resvg`)
Fonts (OFL, from github.com/google/fonts) are read from ~/code/lab/taudot-ref/fonts/, outside the repo.
"""

import io
import math
import re
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw

import build

HERE = Path(__file__).parent
OUT = HERE / "wordmark"
FONTS = Path.home() / "code/lab/taudot-ref/fonts"

CORAL = "#ff5e4d"
INK_LIGHT, INK_DARK = "#14181c", "#f4f1e6"  # near-black on light, the brand's cream on dark
BG_LIGHT, BG_DARK = "#fbf8ec", "#0c1d22"  # cream paper; the icon's deep teal, darkened

XH, ASC, CAP = 500, 740, 700  # x-height, ascender (d, t is shorter), cap height; baseline is y = 0, y down
OV = 10  # overshoot for round letters


# ---------------------------------------------------------------- hand-drawn letters (centre lines, round caps)

def letters(w):
    """Each letter as (centre-line paths, advance width), drawn from x = 0 at its left outer edge."""
    h = w / 2
    rc = XH / 2 + OV - h  # bowl radius on the centre line
    cy = -XH / 2
    cx = h + rc
    bowl = f"M{cx - rc} {cy} a{rc} {rc} 0 1 0 {2 * rc} 0 a{rc} {rc} 0 1 0 {-2 * rc} 0"
    wide = 2 * (rc + h)
    top, foot = -XH + h, -h
    out = {
        "o": ([bowl], wide),
        "a": ([bowl, f"M{cx + rc} {top} V{foot}"], wide),
        "d": ([bowl, f"M{cx + rc} {-ASC + h} V{foot}"], wide),
    }
    # u: the bowl's bottom half, open at the top, with a full right stem.
    ucy = foot + OV - rc
    out["u"] = ([f"M{h} {top} V{ucy} a{rc} {rc} 0 0 0 {2 * rc} 0", f"M{h + 2 * rc} {top} V{foot}"], wide)
    # t: a stem whose foot curls right like the tau's, and a crossbar at the x-height.
    la, ra, rt = 0.18 * XH, 0.30 * XH, 0.26 * XH
    sx = h + la
    out["t"] = ([f"M{sx} {-0.86 * ASC + h} V{foot - rt} a{rt} {rt} 0 0 0 {rt} {rt} h{0.10 * XH}",
                 f"M{h} {top} H{sx + ra}"], sx + max(ra, rt + 0.10 * XH) + h)
    return out


# The mark's tau (build6's BAR and STEM, before the lean), refitted to the cap height.
TAU_BAR = [(262, 420), (270, 330), (320, 300), (400, 300), (770, 300)]
TAU_STEM = [(560, 330), (552, 480), (552, 590), (600, 680), (636, 748), (700, 760), (760, 744)]


def tau(w):
    """The T: the mark's two curves, scaled so the bar's top and the stem's foot sit on the cap line and baseline."""
    wb, ws = w * 150 / 142, w  # the mark's bar is a touch heavier than its stem
    top, low = 300, 753  # the curves' centre-line extremes in the 1024 grid
    k = (CAP - wb / 2 - ws / 2) / (low - top)
    x0 = 262 - wb / 2 / k  # the bar's left outer edge
    f = lambda p: (round((p[0] - x0) * k, 1), round((p[1] - top) * k - CAP + wb / 2, 1))
    b = [f(p) for p in TAU_BAR]
    s = [f(p) for p in TAU_STEM]
    bar = f"M{b[0][0]} {b[0][1]} C{b[1][0]} {b[1][1]} {b[2][0]} {b[2][1]} {b[3][0]} {b[3][1]} L{b[4][0]} {b[4][1]}"
    stem = (f"M{s[0][0]} {s[0][1]} C{s[1][0]} {s[1][1]} {s[2][0]} {s[2][1]} {s[3][0]} {s[3][1]} "
            f"C{s[4][0]} {s[4][1]} {s[5][0]} {s[5][1]} {s[6][0]} {s[6][1]}")
    right = max(b[4][0] + wb / 2, s[6][0] + ws / 2)
    return [(bar, wb), (stem, ws)], right


def hand(w=112, slant=0, ball=False, track=0.0, period=True):
    """Returns (svg body with fill/stroke tokens INK and DOT, bbox (x0, y0, x1, y1))."""
    L = letters(w)
    gap = 0.11 * XH + track * XH  # space between letters' outer edges
    parts, x = [], 0
    strokes, right = tau(w)
    for d, sw in strokes:
        parts.append(f'<path d="{d}" stroke-width="{sw:.1f}"/>')
    x = right + gap - 0.02 * XH
    dots = []
    for ch in "audot":
        paths, adv = L[ch]
        if ch == "o" and ball:
            r = 0.92 * (XH / 2 + OV)
            dots.append((x + adv / 2, -XH / 2, r))
        else:
            for d in paths:
                parts.append(f'<path transform="translate({x:.1f} 0)" d="{d}" stroke-width="{w}"/>')
        x += adv + gap
        if ch == "t":
            x -= gap
    if not ball and period:  # the coral period: you, at the end of the word
        r = 0.62 * w
        x += 0.10 * XH
        dots.append((x + r, -r, r))
        x += 2 * r
    ink = f'<g fill="none" stroke="INK" stroke-linecap="round" stroke-linejoin="round">{"".join(parts)}</g>'
    return skewed(ink, dots, (0, -ASC, x, OV), slant)


def skewed(ink, dots, bbox, slant):
    """Slants the letters (a shear about the baseline) but keeps the dots round, moving only their centres."""
    t = math.tan(math.radians(slant))
    x0, y0, x1, y1 = bbox
    if slant:
        ink = f'<g transform="skewX({-slant})">{ink}</g>'
    circles = "".join(f'<circle cx="{cx - cy * t:.1f}" cy="{cy:.1f}" r="{r:.1f}" fill="DOT"/>' for cx, cy, r in dots)
    return ink + circles, (x0 - y1 * t, y0, x1 - y0 * t, y1)


# ---------------------------------------------------------------- set in an open font

def instance(name, axes):
    from fontTools.ttLib import TTFont
    from fontTools.varLib import instancer
    f = instancer.instantiateVariableFont(TTFont(FONTS / f"{name}.ttf"), axes)
    buf = io.BytesIO()
    f.save(buf)
    return TTFont(io.BytesIO(buf.getvalue())), buf.getvalue()


def typeset(name, axes, text="Taudot", track=-0.02, dot=0.19, period=True):
    """Text as outlines, cap height = CAP, with a coral period sized like the font's stem."""
    import uharfbuzz as hb
    from fontTools.pens.svgPathPen import SVGPathPen
    from fontTools.pens.boundsPen import BoundsPen
    font, data = instance(name, axes)
    upm = font["head"].unitsPerEm
    k = CAP / font["OS/2"].sCapHeight
    hf = hb.Font(hb.Face(data))
    buf = hb.Buffer()
    buf.add_str(text)
    buf.guess_segment_properties()
    hb.shape(hf, buf, {"kern": True, "liga": True})
    gs = font.getGlyphSet()
    order = font.getGlyphOrder()
    x, paths, x1 = 0.0, [], 0.0
    for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
        g = order[info.codepoint]
        pen = SVGPathPen(gs)
        gs[g].draw(pen)
        bp = BoundsPen(gs)
        gs[g].draw(bp)
        paths.append(f'<path transform="translate({x * k:.1f} 0) scale({k:.4f} {-k:.4f})" d="{pen.getCommands()}"/>')
        if bp.bounds:
            x1 = x * k + bp.bounds[2] * k
        x += pos.x_advance + track * upm
    body = f'<g fill="INK">{"".join(paths)}</g>'
    if not period:
        return body, (0, -ASC, x1, OV + 0.03 * CAP)
    r = dot * CAP / 2
    cx = x1 + 0.06 * CAP + r
    body += f'<circle cx="{cx:.1f}" cy="{-r:.1f}" r="{r:.1f}" fill="DOT"/>'
    return body, (0, -ASC, cx + r, OV + 0.03 * CAP)


# ---------------------------------------------------------------- directions

DIRECTIONS = [
    ("hand", "Hand", "The mark's T and round-capped geometric lowercase. The t's foot curls like the tau's stem; you "
     "are the coral period.", lambda **o: hand(**o)),
    ("hand-lean", "Hand, leaning", "The same, slanted 10°: the mark's lean, and a word that moves.",
     lambda **o: hand(**o, slant=10)),
    ("ball", "Ball o", "The o is the coral ball from the icon: the dot is in the name.", lambda **o: hand(**o, ball=True)),
    ("ball-lean", "Ball o, leaning", "Ball o, slanted 10°.", lambda **o: hand(**o, ball=True, slant=10)),
    ("thin", "Hand, light", "A lighter stroke: calmer, more editorial, for long headers.",
     lambda **o: hand(**o, w=78, track=0.02)),
    ("inter", "Inter", "Set in Inter Semibold (OFL), tight. The neutral baseline: clean, but anyone's.",
     lambda **o: typeset("Inter", {"wght": 620, "opsz": 32}, track=-0.025, **o)),
    ("fraunces", "Fraunces soft", "Fraunces (OFL) with its soft axis up: a friendly serif with TeX's bookish roots.",
     lambda **o: typeset("Fraunces", {"wght": 620, "opsz": 72, "SOFT": 100, "WONK": 0}, track=-0.01, **o)),
    ("newsreader", "Newsreader", "Newsreader (OFL): a text serif for papers. Academic and quiet.",
     lambda **o: typeset("Newsreader", {"wght": 600, "opsz": 72}, track=-0.015, **o)),
]


def svg(body, bbox, ink, dot, bg=None, pad=0.12):
    x0, y0, x1, y1 = bbox
    p = pad * (y1 - y0)
    vb = (x0 - p, y0 - p, x1 - x0 + 2 * p, y1 - y0 + 2 * p)
    back = f'<rect x="{vb[0]}" y="{vb[1]}" width="{vb[2]}" height="{vb[3]}" fill="{bg}"/>' if bg else ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{" ".join(f"{v:.1f}" for v in vb)}">'
            f'{back}{body.replace("INK", ink).replace("DOT", dot)}</svg>'), vb


def render(svg_text, path, height):
    src = path.with_suffix(".svg")
    src.write_text(svg_text)
    subprocess.run(["resvg", "-h", str(height), str(src), str(path)], check=True)
    return Image.open(path).convert("RGBA")


def sheet(rendered):
    big_h, small = 200, 420
    pad = 30
    max_w = max(im["light"].width for im in rendered.values())
    W = 340 + 2 * (max_w + pad) + small + 40
    row = big_h + 2 * pad
    H = 130 + len(DIRECTIONS) * row
    im = Image.new("RGBA", (W, H), (255, 255, 255, 255))
    d = ImageDraw.Draw(im)
    d.text((40, 30), "Taudot wordmark directions", font=build.font(44, True), fill=(20, 20, 28))
    d.text((40, 84), "On cream and on deep teal at 140 px cap height · at 28 and 15 px beside the app icon · "
           "beside the flat mark", font=build.font(22), fill=(90, 90, 100))
    title, sub = build.font(30, True), build.font(20)
    for r, (key, name, desc, _f) in enumerate(DIRECTIONS):
        y = 130 + r * row
        if r % 2:
            d.rectangle([0, y - 10, W, y + row - 10], fill=(246, 246, 249))
        d.text((40, y + 10), f"{r + 1}. {name}", font=title, fill=(20, 20, 28))
        words, line, ly = desc.split(), "", y + 56
        for w_ in words:
            if d.textlength(line + " " + w_, font=sub) > 270:
                d.text((40, ly), line.strip(), font=sub, fill=(90, 90, 100))
                line, ly = "", ly + 26
            line += " " + w_
        d.text((40, ly), line.strip(), font=sub, fill=(90, 90, 100))
        x = 340
        for v in ("light", "dark"):
            t = rendered[key][v]
            tile = Image.new("RGBA", (max_w, big_h + 2 * pad - 20), BG_LIGHT if v == "light" else BG_DARK)
            tile.alpha_composite(t, ((max_w - t.width) // 2, (tile.height - t.height) // 2))
            im.alpha_composite(tile, (x, y))
            x += max_w + pad
        panel = Image.new("RGBA", (small, big_h + 2 * pad - 20), (236, 236, 242, 255))
        py = 18
        for s, k in ((44, "lock44"), (24, "lock24")):
            ic = Image.open(HERE / "final" / "icon-light-256.png").convert("RGBA").resize((s, s), Image.LANCZOS)
            panel.alpha_composite(ic, (16, py))
            wm = rendered[key][k]
            panel.alpha_composite(wm, (16 + s + s // 4, py + (s - wm.height) // 2 + s // 14))
            py += s + 22
        panel.alpha_composite(rendered[key]["mark"], (16, py))
        im.alpha_composite(panel, (x, y))
    im.convert("RGB").save(OUT / "sheet.png")
    return im


def mark_lockup(body, bbox, height):
    """The flat mark (mark.svg) beside the wordmark, sharing a baseline."""
    mark = (HERE / "final" / "mark.svg").read_text()
    inner = mark[mark.index(">") + 1:mark.rindex("</svg>")].replace("#000", "INK")
    inner = re.sub(r'(<circle[^>]*fill=")INK', r"\1DOT", inner)
    x0, y0, x1, y1 = bbox
    # mark.svg's box is 823 x 670 at (149, 190); make it 1.15x the cap height, its bottom on the baseline.
    s = 1.15 * CAP / 670
    mx = -823 * s - 0.25 * CAP
    m = f'<g transform="translate({mx:.1f} {-670 * s + OV:.1f}) scale({s:.4f}) translate(-149 -190)">{inner}</g>'
    return m + body, (mx, min(y0, -670 * s + OV), x1, y1)


def main():
    OUT.mkdir(exist_ok=True)
    rendered = {}
    for key, _n, _d, fn in DIRECTIONS:
        body, bbox = fn()
        out = {}
        for v, ink, bg in (("light", INK_LIGHT, None), ("dark", INK_DARK, None)):
            s, _vb = svg(body, bbox, ink, CORAL, pad=0.04)
            out[v] = render(s, OUT / f"{key}-{v}.png", 170)
        s, _ = svg(body, bbox, INK_LIGHT, CORAL, pad=0.02)
        out["lock44"] = render(s, OUT / f"_{key}-44.png", 30)
        out["lock24"] = render(s, OUT / f"_{key}-24.png", 17)
        mb, mbb = mark_lockup(*fn(period=False), 60)  # the mark carries the dot, so the word drops its period
        s, _ = svg(mb, mbb, INK_LIGHT, CORAL, pad=0.04)
        out["mark"] = render(s, OUT / f"_{key}-mark.png", 56)
        rendered[key] = out
    sheet(rendered)
    for p in OUT.glob("_*"):
        p.unlink()
    print("ok", OUT / "sheet.png")


if __name__ == "__main__":
    main()
