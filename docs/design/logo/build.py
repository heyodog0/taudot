"""Build the logo directions: layered SVG masters, PNG renders, and the contact sheet.

Run: uv run --with pillow docs/design/logo/build.py   (needs `resvg` on PATH)

Each direction is a background layer plus 1-3 foreground layers on a 1024 canvas, in the order Icon Composer wants
(background first). The composite clips them to the macOS icon shape (824 px rounded square, 100 px margin) and adds
a rim and specular highlight that stand in for the system's glass.
"""

import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
SIZES = [1024, 256, 64, 32, 16]
VARIANTS = ["light", "dark", "mono"]


# ---------- the icon shape ----------

SHAPE = "M286 100 H738 C841 100 924 183 924 286 V738 C924 841 841 924 738 924 H286 C183 924 100 841 100 738 V286 C100 183 183 100 286 100 Z"  # 824 square, ~186 corner

SHADOW = """<filter id="{id}" x="-30%" y="-30%" width="160%" height="160%">
  <feDropShadow dx="0" dy="{dy}" stdDeviation="{sd}" flood-color="{c}" flood-opacity="{o}"/></filter>"""


def shadow(id, dy=14, sd=16, c="#000", o=0.28):
    return SHADOW.format(id=id, dy=dy, sd=sd, c=c, o=o)


def lin(id, c1, c2, x1=0, y1=0, x2=0, y2=1, o1=1, o2=1):
    return (f'<linearGradient id="{id}" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">'
            f'<stop offset="0" stop-color="{c1}" stop-opacity="{o1}"/>'
            f'<stop offset="1" stop-color="{c2}" stop-opacity="{o2}"/></linearGradient>')


def rad(id, c1, c2, cx=0.5, cy=0.3, r=0.8, o1=1, o2=1):
    return (f'<radialGradient id="{id}" cx="{cx}" cy="{cy}" r="{r}">'
            f'<stop offset="0" stop-color="{c1}" stop-opacity="{o1}"/>'
            f'<stop offset="1" stop-color="{c2}" stop-opacity="{o2}"/></radialGradient>')


def bg_layer(c1, c2, glow=None):
    """Full-bleed background: a vertical gradient and an optional soft glow."""
    d = lin("bg", c1, c2)
    body = '<rect width="1024" height="1024" fill="url(#bg)"/>'
    if glow:
        d += rad("bgglow", glow, glow, cx=0.5, cy=0.25, r=0.6, o1=0.55, o2=0)
        body += '<rect width="1024" height="1024" fill="url(#bgglow)"/>'
    return d, body


# ---------- palettes ----------
# Every direction reads colours from a palette, so dark and mono are the same drawing with other colours.

MONO = dict(bg1="#3a3a3e", bg2="#1d1d20", glow=None, paper="#f2f2f5", paper2="#c9c9cf", ink="#1d1d20",
            line="#8e8e96", a1="#ffffff", a2="#d8d8de", a3="#b0b0b8", a4="#8e8e96",
            ed1="#2a2a2e", ed2="#141416", shadow="#000")


def pal(light, dark):
    return {"light": light, "dark": dark, "mono": {**MONO, **{k: v for k, v in light.items() if k not in MONO}}}


# ---------- directions ----------
# Each returns (defs, [(layer name, svg body)...]) for a palette p. Layer 0 is the background.

def d_cursor(p):
    """A page with a live cursor: the caret is the only colour on it."""
    defs, bg = bg_layer(p["bg1"], p["bg2"], p["glow"])
    defs += shadow("sh", c=p["shadow"]) + lin("paper", p["paper"], p["paper2"])
    defs += lin("caret", p["a1"], p["a2"])
    page = ('<g transform="rotate(-7 512 512)" filter="url(#sh)">'
            '<rect x="282" y="214" width="460" height="596" rx="64" fill="url(#paper)"/>'
            f'<g fill="{p["line"]}"><rect x="352" y="318" width="250" height="40" rx="20"/>'
            '<rect x="352" y="408" width="320" height="40" rx="20"/>'
            '<rect x="352" y="498" width="140" height="40" rx="20"/></g></g>')
    caret = ('<g transform="rotate(-7 512 512)" filter="url(#sh)">'
             '<rect x="522" y="430" width="52" height="290" rx="26" fill="url(#caret)"/>'
             '<circle cx="548" cy="420" r="50" fill="url(#caret)"/></g>')
    return defs, [("background", bg), ("page", page), ("caret", caret)]


def d_twin(p):
    """Two collaborators' carets side by side, overlapping where they meet."""
    defs, bg = bg_layer(p["bg1"], p["bg2"], p["glow"])
    defs += shadow("sh", c=p["shadow"]) + lin("ca", p["a1"], p["a2"]) + lin("cb", p["a3"], p["a4"])
    a = ('<g filter="url(#sh)"><rect x="350" y="250" width="120" height="520" rx="60" fill="url(#ca)"/>'
         '</g>')
    b = ('<g filter="url(#sh)" opacity="0.94"><rect x="554" y="250" width="120" height="520" rx="60" fill="url(#cb)"/>'
         '</g>')
    # The link between them: a short bar that crosses both, the "sync".
    link = (f'<rect x="300" y="470" width="424" height="84" rx="42" fill="{p["paper"]}" opacity="0.92" '
            'filter="url(#sh)"/>')
    return defs, [("background", bg), ("you", a), ("them", b), ("link", link)]


def d_tau(p):
    """A TeX tau on glass."""
    defs, bg = bg_layer(p["bg1"], p["bg2"], p["glow"])
    defs += shadow("sh", c=p["shadow"]) + lin("g", p["paper"], p["paper2"])
    tau = ('<g filter="url(#sh)" fill="none" stroke="url(#g)" stroke-linecap="round" stroke-linejoin="round">'
           '<path d="M250 420 C 270 340, 320 318, 400 318 L 790 318" stroke-width="112"/>'
           '<path d="M540 330 L 520 620 C 514 716, 560 760, 650 742" stroke-width="112"/></g>')
    dot = f'<circle cx="760" cy="720" r="58" fill="{p["a1"]}" filter="url(#sh)"/>'
    return defs, [("background", bg), ("tau", tau), ("dot", dot)]


def d_fold(p):
    """A folded sheet; the dog-ear turns into a loop around the corner."""
    defs, bg = bg_layer(p["bg1"], p["bg2"], p["glow"])
    defs += shadow("sh", c=p["shadow"]) + lin("paper", p["paper"], p["paper2"]) + lin("ear", p["a1"], p["a2"])
    page = ('<g filter="url(#sh)"><path d="M330 230 H 590 L 730 370 V 750 Q 730 800 680 800 H 330 '
            'Q 280 800 280 750 V 280 Q 280 230 330 230 Z" fill="url(#paper)"/>'
            f'<g fill="{p["line"]}"><rect x="350" y="470" width="300" height="38" rx="19"/>'
            '<rect x="350" y="560" width="300" height="38" rx="19"/><rect x="350" y="650" width="180" height="38" rx="19"/>'
            '</g></g>')
    ear = '<path d="M590 230 V 330 Q 590 370 630 370 H 730 Z" fill="url(#ear)" filter="url(#sh)"/>'
    loop = (f'<g filter="url(#sh)" fill="none" stroke="{p["a1"]}" stroke-width="56" stroke-linecap="round">'
            '<path d="M660 206 A 140 140 0 0 1 792 330"/></g>'
            f'<path d="M750 318 L 834 318 L 792 388 Z" fill="{p["a1"]}" stroke="{p["a1"]}" stroke-width="18" '
            'stroke-linejoin="round" filter="url(#sh)"/>')
    return defs, [("background", bg), ("page", page), ("ear", ear), ("loop", loop)]


def d_split(p):
    """The window itself: your editor on the left, the typeset page on the right, a caret at the seam."""
    defs, bg = bg_layer(p["bg1"], p["bg2"], p["glow"])
    defs += shadow("sh", c=p["shadow"]) + lin("paper", p["paper"], p["paper2"]) + lin("ed", p["ed1"], p["ed2"])
    editor = ('<g filter="url(#sh)"><path d="M300 230 H 512 V 794 H 300 Q 236 794 236 730 V 294 Q 236 230 300 230 Z" '
              'fill="url(#ed)"/>'
              f'<rect x="290" y="330" width="150" height="36" rx="18" fill="{p["a1"]}"/>'
              f'<rect x="330" y="410" width="130" height="36" rx="18" fill="{p["a3"]}"/>'
              f'<rect x="330" y="490" width="90" height="36" rx="18" fill="{p["a2"]}"/>'
              f'<rect x="290" y="570" width="170" height="36" rx="18" fill="{p["a3"]}"/></g>')
    page = ('<g filter="url(#sh)"><path d="M512 230 H 724 Q 788 230 788 294 V 730 Q 788 794 724 794 H 512 Z" '
            'fill="url(#paper)"/>'
            f'<g fill="{p["line"]}"><rect x="572" y="330" width="160" height="30" rx="15"/>'
            '<rect x="572" y="400" width="160" height="30" rx="15"/><rect x="572" y="470" width="110" height="30" rx="15"/>'
            '<rect x="572" y="570" width="160" height="30" rx="15"/></g></g>')
    seam = f'<rect x="490" y="196" width="44" height="632" rx="22" fill="{p["a1"]}" filter="url(#sh)"/>'
    return defs, [("background", bg), ("editor", editor), ("page", page), ("seam", seam)]


def d_buddy(p):
    """A page with a face: one eye is a dot, the other is the blinking caret."""
    defs, bg = bg_layer(p["bg1"], p["bg2"], p["glow"])
    defs += shadow("sh", c=p["shadow"], o=0.32) + lin("paper", p["paper"], p["paper2"])
    defs += lin("ear", p["a2"], p["a1"])
    body = ('<g transform="rotate(-8 512 540)" filter="url(#sh)">'
            '<path d="M330 236 H 600 L 760 396 V 730 Q 760 820 670 820 H 354 Q 264 820 264 730 V 302 '
            'Q 264 236 330 236 Z" fill="url(#paper)"/></g>')
    ear = ('<g transform="rotate(-8 512 540)">'
           '<path d="M600 236 V 346 Q 600 396 650 396 H 760 Z" fill="url(#ear)"/></g>')
    face = (f'<g transform="rotate(-8 512 540)" fill="{p["ink"]}">'
            '<circle cx="430" cy="560" r="44"/>'
            f'<rect x="560" y="494" width="50" height="134" rx="25" fill="{p["a1"]}"/></g>')
    return defs, [("background", bg), ("page", body), ("ear", ear), ("face", face)]


def d_nib(p):
    """A pen nib whose slit is a text caret."""
    defs, bg = bg_layer(p["bg1"], p["bg2"], p["glow"])
    defs += shadow("sh", c=p["shadow"]) + lin("nib", p["paper"], p["paper2"], 0, 0, 1, 1)
    nib = ('<g filter="url(#sh)"><path d="M512 832 L 330 560 Q 300 512 340 470 L 430 236 Q 440 210 470 210 '
           'H 554 Q 584 210 594 236 L 684 470 Q 724 512 694 560 Z" fill="url(#nib)"/></g>')
    slit = (f'<g fill="{p["ink"]}"><circle cx="512" cy="430" r="46"/>'
            '<path d="M496 470 H 528 L 516 800 H 508 Z"/></g>')
    caret = f'<rect x="486" y="236" width="52" height="150" rx="26" fill="{p["a1"]}"/>'
    return defs, [("background", bg), ("nib", nib), ("slit", slit), ("caret", caret)]


def d_braces(p):
    """LaTeX's braces holding a caret: { | }."""
    defs, bg = bg_layer(p["bg1"], p["bg2"], p["glow"])
    defs += shadow("sh", c=p["shadow"]) + lin("g", p["paper"], p["paper2"]) + lin("c", p["a1"], p["a2"])
    left = ("M396 262 C 316 262, 316 300, 316 360 L 316 444 C 316 488, 294 512, 246 512 "
            "C 294 512, 316 536, 316 580 L 316 664 C 316 724, 316 762, 396 762")
    braces = ('<g filter="url(#sh)" fill="none" stroke="url(#g)" stroke-width="84" stroke-linecap="round" '
              f'stroke-linejoin="round"><path d="{left}"/><path d="{left}" transform="translate(1024 0) scale(-1 1)"/></g>')
    caret = '<rect x="484" y="300" width="56" height="424" rx="28" fill="url(#c)" filter="url(#sh)"/>'
    return defs, [("background", bg), ("braces", braces), ("caret", caret)]


DIRECTIONS = [
    ("cursor", "Live page", "A page with one coloured caret: the paper is being written right now.", d_cursor, pal(
        dict(bg1="#5b5cff", bg2="#3a2fd0", glow="#9a8cff", paper="#ffffff", paper2="#e7e9f5", line="#c3c7dc",
             a1="#ff7a59", a2="#ff4d6d", shadow="#1a1060"),
        dict(bg1="#24243a", bg2="#0b0b14", glow="#4a3fb0", paper="#f4f5fb", paper2="#cfd2e6", line="#a7abc4",
             a1="#ff7a59", a2="#ff4d6d", shadow="#000"))),
    ("twin", "Twin carets", "Two collaborators' cursors joined by one bar: the sync.", d_twin, pal(
        dict(bg1="#1d2140", bg2="#0b0d1f", glow="#3b3f99", paper="#ffffff", a1="#ff8a5c", a2="#ff5e7e",
             a3="#5cc8ff", a4="#6d5bff", shadow="#000"),
        dict(bg1="#16182c", bg2="#06070f", glow="#2a2d70", paper="#f2f2f8", a1="#ff8a5c", a2="#ff5e7e",
             a3="#5cc8ff", a4="#6d5bff", shadow="#000"))),
    ("tau", "Tau on glass", "TeX's tau as one bold glass stroke, with a coloured cursor dot.", d_tau, pal(
        dict(bg1="#3f7bff", bg2="#2346d8", glow="#8fb4ff", paper="#ffffff", paper2="#dbe6ff", a1="#ffb547",
             shadow="#0c1f6b"),
        dict(bg1="#1f2436", bg2="#090b12", glow="#2d4aa8", paper="#eef3ff", paper2="#a9c0ff", a1="#ffb547",
             shadow="#000"))),
    ("fold", "Folded sheet", "A sheet whose dog-ear turns into a sync arrow round the corner.", d_fold, pal(
        dict(bg1="#19c39a", bg2="#0a8f78", glow="#7ff0cf", paper="#ffffff", paper2="#e2f3ee", line="#bcd8d0",
             a1="#0b3b33", a2="#14594d", shadow="#04463a"),
        dict(bg1="#1c2a28", bg2="#080d0c", glow="#14725f", paper="#f1f7f5", paper2="#c6dcd5", line="#9fbab2",
             a1="#3ee0b5", a2="#19c39a", shadow="#000"))),
    ("split", "Split window", "Your editor and the typeset page as one tile, a caret at the seam.", d_split, pal(
        dict(bg1="#f3f3f7", bg2="#dcdce6", glow=None, paper="#ffffff", paper2="#eef0f6", line="#c9ccd8",
             ed1="#22243a", ed2="#11121f", a1="#7b6bff", a2="#ff7a59", a3="#5cc8ff", shadow="#30324a"),
        dict(bg1="#26262e", bg2="#0c0c10", glow=None, paper="#f4f5fa", paper2="#d6d8e4", line="#a9acbd",
             ed1="#2e3150", ed2="#191b2e", a1="#8f80ff", a2="#ff7a59", a3="#5cc8ff", shadow="#000"))),
    ("buddy", "Page buddy", "A friendly page: one eye a dot, the other a blinking caret.", d_buddy, pal(
        dict(bg1="#ff9b5e", bg2="#ff5a5f", glow="#ffd29a", paper="#ffffff", paper2="#f1e9ea", ink="#1b1530",
             a1="#6d5bff", a2="#d9d0ff", shadow="#7a1f2a"),
        dict(bg1="#2b2230", bg2="#0e0a10", glow="#8a3448", paper="#fbf7f8", paper2="#ddd1d4", ink="#1b1530",
             a1="#7b6bff", a2="#d9d0ff", shadow="#000"))),
    ("nib", "Caret nib", "A fountain-pen nib whose slit ends in a live caret.", d_nib, pal(
        dict(bg1="#fbfaf7", bg2="#e6e3dc", glow=None, paper="#2b2d3a", paper2="#0d0e14", ink="#e6e3dc",
             a1="#ff7a3d", shadow="#3a3424"),
        dict(bg1="#2a2a30", bg2="#0a0a0d", glow="#3a3a48", paper="#f0eee8", paper2="#b9b5aa", ink="#141418",
             a1="#ff7a3d", shadow="#000"))),
    ("braces", "Braces", "LaTeX's braces holding a caret: { | }.", d_braces, pal(
        dict(bg1="#7a5cff", bg2="#4b2fd6", glow="#c3b2ff", paper="#ffffff", paper2="#e4ddff", a1="#ffcf5a",
             a2="#ff9d3d", shadow="#1f0f6b"),
        dict(bg1="#221f33", bg2="#0a0910", glow="#4a35a8", paper="#efeaff", paper2="#b9a9ff", a1="#ffcf5a",
             a2="#ff9d3d", shadow="#000"))),
]


# ---------- SVG assembly ----------

def svg(defs, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
            f'<defs>{defs}</defs>{body}</svg>\n')


def composite(defs, layers):
    """Layers clipped to the icon shape, with a rim and a top specular standing in for the system's glass."""
    defs += f'<clipPath id="shape"><path d="{SHAPE}"/></clipPath>'
    defs += shadow("iconsh", dy=10, sd=12, c="#000", o=0.3)
    defs += lin("spec", "#fff", "#fff", o1=0.32, o2=0)
    defs += lin("rim", "#fff", "#fff", o1=0.55, o2=0.08)
    inner = "".join(b for _, b in layers)
    body = (f'<path d="{SHAPE}" fill="#000" filter="url(#iconsh)" opacity="0.6"/>'
            f'<g clip-path="url(#shape)">{inner}'
            f'<ellipse cx="512" cy="150" rx="520" ry="260" fill="url(#spec)"/></g>'
            f'<path d="{SHAPE}" fill="none" stroke="url(#rim)" stroke-width="4"/>')
    return svg(defs, body)


def render(src, dst, size):
    subprocess.run(["resvg", "-w", str(size), "-h", str(size), str(src), str(dst)], check=True)


def build():
    for key, *_rest, fn, pals in DIRECTIONS:
        out = HERE / key
        if out.exists():
            shutil.rmtree(out)
        (out / "layers").mkdir(parents=True)
        for v in VARIANTS:
            defs, layers = fn(pals[v])
            master = out / f"{key}-{v}.svg"
            master.write_text(composite(defs, layers))
            for s in SIZES:
                render(master, out / f"{key}-{v}-{s}.png", s)
            if v == "light":
                for i, (name, body) in enumerate(layers):
                    (out / "layers" / f"{i}-{name}.svg").write_text(svg(defs, body))


# ---------- contact sheet ----------

FONT = "/System/Library/Fonts/SFNS.ttf"


def font(px, bold=False):
    f = ImageFont.truetype(FONT, px)
    try:
        f.set_variation_by_name("Semibold" if bold else "Regular")
    except Exception:
        pass
    return f


def icon(key, v, s):
    return Image.open(HERE / key / f"{key}-{v}-{s}.png").convert("RGBA")


def wallpaper(w, h, dark):
    im = Image.new("RGBA", (w, h))
    d = ImageDraw.Draw(im)
    top, bot = ((40, 44, 92), (10, 10, 22)) if dark else ((180, 200, 255), (246, 214, 232))
    for y in range(h):
        t = y / max(1, h - 1)
        d.line([(0, y), (w, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bot)) + (255,))
    return im


def dock(dark):
    n = len(DIRECTIONS)
    s, gap, pad = 112, 18, 22
    w = n * s + (n - 1) * gap + 2 * pad + 160
    h = s + 2 * pad + 120
    im = wallpaper(w, h, dark)
    bar = Image.new("RGBA", (w - 160, s + 2 * pad), (0, 0, 0, 0))
    ImageDraw.Draw(bar).rounded_rectangle([0, 0, bar.width - 1, bar.height - 1], radius=34,
                                          fill=(30, 30, 40, 120) if dark else (255, 255, 255, 110),
                                          outline=(255, 255, 255, 70 if dark else 160), width=2)
    bx, by = 80, h - bar.height - 30
    im.alpha_composite(bar, (bx, by))
    lab = font(22)
    d = ImageDraw.Draw(im)
    for i, (key, name, *_r) in enumerate(DIRECTIONS):
        x = bx + pad + i * (s + gap)
        im.alpha_composite(icon(key, "dark" if dark else "light", 256).resize((s, s), Image.LANCZOS), (x, by + pad))
        tw = d.textlength(name, font=lab)
        d.text((x + s / 2 - tw / 2, by - 40), name, font=lab, fill=(255, 255, 255) if dark else (30, 30, 40))
    return im


def sidebar(dark):
    """Rex-style sidebar rows at 2x: 40 px icon (the 20 pt row), label beside it."""
    rows = len(DIRECTIONS)
    w, rh = 520, 64
    im = Image.new("RGBA", (w, rows * rh + 40), (12, 12, 28, 255) if dark else (240, 240, 245, 255))
    d = ImageDraw.Draw(im)
    f = font(30)
    for i, (key, name, *_r) in enumerate(DIRECTIONS):
        y = 20 + i * rh
        if i == 0:
            d.rounded_rectangle([10, y + 2, w - 10, y + rh - 2], radius=26,
                                fill=(36, 36, 56) if dark else (220, 220, 230),
                                outline=(70, 70, 96) if dark else (200, 200, 212))
        im.alpha_composite(icon(key, "dark" if dark else "light", 64).resize((40, 40), Image.LANCZOS),
                           (34, y + 12))
        d.text((92, y + 13), f"taudot · {name}", font=f, fill=(235, 235, 245) if dark else (25, 25, 35))
    return im


def sheet(title="taudot icon directions"):
    big, col = 240, 30
    mag = 4
    cols = [("light", "1024"), ("dark", "1024"), ("mono", "1024")]
    small_w = 16 + 32 * mag + 16 * mag + 64 + 32 + 16 + 5 * 24
    row_h = big + 70
    W = 360 + len(cols) * (big + col) + 2 * small_w + 2 * col + 40
    H = 120 + len(DIRECTIONS) * row_h
    im = Image.new("RGBA", (W, H), (255, 255, 255, 255))
    d = ImageDraw.Draw(im)
    d.text((40, 30), title, font=font(44, True), fill=(20, 20, 28))
    d.text((40, 84), "1024 master shown at 240 (light, dark, mono/tinted) · actual 64/32/16 px and 4x pixel view on "
           "light and dark", font=font(22), fill=(90, 90, 100))
    title, sub = font(30, True), font(20)
    for r, (key, name, desc, *_x) in enumerate(DIRECTIONS):
        y = 130 + r * row_h
        if r % 2:
            d.rectangle([0, y - 15, W, y + row_h - 15], fill=(246, 246, 249))
        d.text((40, y + 10), f"{r + 1}. {name}", font=title, fill=(20, 20, 28))
        words, line, ly = desc.split(), "", y + 56
        for w_ in words:
            if d.textlength(line + " " + w_, font=sub) > 280:
                d.text((40, ly), line.strip(), font=sub, fill=(90, 90, 100))
                line, ly = "", ly + 26
            line += " " + w_
        d.text((40, ly), line.strip(), font=sub, fill=(90, 90, 100))
        x = 360
        for v, _s in cols:
            tile = Image.new("RGBA", (big, big), (255, 255, 255, 255) if v == "light" else (22, 22, 28, 255))
            tile.alpha_composite(icon(key, v, 256).resize((big, big), Image.LANCZOS))
            im.alpha_composite(tile, (x, y))
            x += big + col
        for dark in (False, True):
            panel = Image.new("RGBA", (small_w, big), (22, 22, 28, 255) if dark else (236, 236, 242, 255))
            px = 16
            v = "dark" if dark else "light"
            for s in (64, 32, 16):
                panel.alpha_composite(icon(key, v, s), (px, big // 2 - s // 2))
                px += s + 24
            for s in (32, 16):
                m = icon(key, v, s).resize((s * mag, s * mag), Image.NEAREST)
                panel.alpha_composite(m, (px, big // 2 - s * mag // 2))
                px += s * mag + 24
            im.alpha_composite(panel, (x, y))
            x += small_w + col
    docks = [dock(False), dock(True)]
    bars = [sidebar(False), sidebar(True)]
    W2 = max(W, docks[0].width + 40)
    H2 = H + 60 + sum(dk.height + 30 for dk in docks) + 60 + bars[0].height + 40
    out = Image.new("RGBA", (W2, H2), (255, 255, 255, 255))
    out.alpha_composite(im, (0, 0))
    d = ImageDraw.Draw(out)
    y = H + 20
    d.text((40, y), "In the Dock (112 px, light and dark wallpaper)", font=title, fill=(20, 20, 28))
    y += 50
    for dk in docks:
        out.alpha_composite(dk, (40, y))
        y += dk.height + 30
    d.text((40, y), "In a Rex-style sidebar row (2x: 40 px icon = 20 pt)", font=title, fill=(20, 20, 28))
    y += 50
    x = 40
    for b in bars:
        out.alpha_composite(b, (x, y))
        x += b.width + 40
    out.convert("RGB").save(HERE / "sheet.png", optimize=True)


if __name__ == "__main__":
    build()
    sheet()
    print("ok", HERE / "sheet.png")
