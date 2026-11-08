"""Round 3: a small, quiet blob character, on the Phosphor green. Some wear a wizard hat.

Run: uv run --with pillow docs/design/logo/build3.py   (needs `resvg`)
"""

import build
import build2 as b2

BLOB = ("M300 780 C 250 780, 228 740, 236 680 C 256 520, 370 420, 512 420 "
        "C 654 420, 768 520, 788 680 C 796 740, 774 780, 724 780 Z")
DROP = ("M512 300 C 560 400, 760 520, 760 640 C 760 740, 650 800, 512 800 "
        "C 374 800, 264 740, 264 640 C 264 520, 464 400, 512 300 Z")


def dots(p, y=630, gap=52, r=22, x=512):
    return (f'<g fill="{p["eye"]}"><circle cx="{x - gap}" cy="{y}" r="{r}"/>'
            f'<circle cx="{x + gap}" cy="{y}" r="{r}"/></g>')


def blush(p, y=672, gap=110, x=512):
    return (f'<g fill="{p["accent"]}" opacity="0.35"><ellipse cx="{x - gap}" cy="{y}" rx="30" ry="16"/>'
            f'<ellipse cx="{x + gap}" cy="{y}" rx="30" ry="16"/></g>')


def sparkle(cx, cy, r, color):
    k = r * 0.28
    return (f'<path d="M{cx} {cy - r} Q {cx + k} {cy - k} {cx + r} {cy} Q {cx + k} {cy + k} {cx} {cy + r} '
            f'Q {cx - k} {cy + k} {cx - r} {cy} Q {cx - k} {cy - k} {cx} {cy - r} Z" fill="{color}"/>')


def hat(p, tilt=-12, base_y=452, tip=(600, 150)):
    tx, ty = tip
    cone = (f'<path d="M396 {base_y} C 440 360, {tx - 90} {ty + 120}, {tx} {ty} '
            f'C {tx - 10} {ty + 110}, 600 330, 632 {base_y} Z" fill="url(#hat)"/>')
    brim = f'<ellipse cx="514" cy="{base_y}" rx="176" ry="40" fill="url(#hat)"/>'
    band = (f'<path d="M418 {base_y - 26} Q 514 {base_y - 2} 612 {base_y - 26}" fill="none" '
            f'stroke="{p["accent"]}" stroke-width="16" stroke-linecap="round"/>')
    return f'<g transform="rotate({tilt} 514 {base_y})">{brim}{cone}{band}</g>', (tx, ty)


def mats(p):
    return b2.mats(p) + build.lin("hat", p["hat1"], p["hat2"], 0, 0, 0.4, 1)


def obj(inner, tr=""):
    return b2.obj(inner, tr)


def c_wizard(p):
    defs, bg = b2.background(p["bg"])
    defs += mats(p)
    h, _ = hat(p)
    return defs, [("background", bg), ("blob", obj(f'<path d="{BLOB}" fill="url(#fill)"/>')),
                  ("hat", obj(h)), ("face", dots(p) + blush(p)),
                  ("sparkle", sparkle(706, 236, 46, p["accent"]))]


def c_wand(p):
    defs, bg = b2.background(p["bg"])
    defs += mats(p)
    h, _ = hat(p, tilt=-6, tip=(560, 160))
    wand = (f'<g transform="rotate(28 760 560)"><rect x="740" y="470" width="40" height="230" rx="20" '
            f'fill="{p["accent"]}"/></g>' + sparkle(800, 420, 52, p["spark"]))
    body = obj(f'<path d="{BLOB}" fill="url(#fill)" transform="translate(-40 0)"/>')
    return defs, [("background", bg), ("blob", body), ("hat", obj(h, "translate(-40 0)")),
                  ("face", dots(p, x=472)), ("wand", wand)]


def c_drop(p):
    defs, bg = b2.background(p["bg"])
    defs += mats(p)
    return defs, [("background", bg), ("drop", obj(f'<path d="{DROP}" fill="url(#fill)"/>')),
                  ("face", dots(p, y=640, gap=48) + blush(p, y=684, gap=104))]


def c_quill(p):
    defs, bg = b2.background(p["bg"])
    defs += mats(p)
    feather = ('<path d="M520 440 C 500 330, 560 220, 700 170 C 690 280, 640 380, 540 446 Z" fill="url(#hat)"/>'
               f'<path d="M524 440 C 570 340, 620 260, 690 186" fill="none" stroke="{p["f1"]}" stroke-width="8" '
               'stroke-linecap="round" opacity="0.8"/>')
    return defs, [("background", bg), ("feather", obj(feather)),
                  ("blob", obj(f'<path d="{BLOB}" fill="url(#fill)"/>')), ("face", dots(p) + blush(p))]


def c_scholar(p):
    defs, bg = b2.background(p["bg"])
    defs += mats(p)
    glasses = (f'<g fill="none" stroke="{p["eye"]}" stroke-width="12"><circle cx="452" cy="622" r="52"/>'
               '<circle cx="572" cy="622" r="52"/><path d="M504 618 Q 512 608 520 618"/></g>')
    return defs, [("background", bg), ("blob", obj(f'<path d="{BLOB}" fill="url(#fill)"/>')),
                  ("face", dots(p, y=626, gap=60, r=18) + glasses)]


def c_blink(p):
    defs, bg = b2.background(p["bg"])
    defs += mats(p)
    face = (f'<circle cx="456" cy="630" r="24" fill="{p["eye"]}"/>'
            f'<rect x="548" y="590" width="26" height="82" rx="13" fill="{p["accent"]}"/>')
    return defs, [("background", bg), ("blob", obj(f'<path d="{BLOB}" fill="url(#fill)"/>')), ("face", face)]


def c_sleepy(p):
    defs, bg = b2.background(p["bg"])
    defs += mats(p)
    h, _ = hat(p, tilt=14, tip=(470, 170))
    face = (f'<g fill="none" stroke="{p["eye"]}" stroke-width="14" stroke-linecap="round">'
            '<path d="M436 628 Q 460 648 484 628"/><path d="M540 628 Q 564 648 588 628"/></g>' + blush(p))
    return defs, [("background", bg), ("blob", obj(f'<path d="{BLOB}" fill="url(#fill)"/>')),
                  ("hat", obj(h)), ("face", face), ("sparkle", sparkle(320, 250, 30, p["spark"]))]


def c_dash(p):
    defs, bg = b2.background(p["bg"])
    defs += mats(p)
    tr = "translate(60 0) rotate(10 512 780)"
    h, _ = hat(p, tilt=-30, tip=(640, 190))
    trail = b2.streaks(p, [(110, 560, 170, 0.85), (80, 630, 220, 0.65), (130, 700, 140, 0.5)])
    return defs, [("background", bg), ("trail", trail),
                  ("blob", obj(f'<path d="{BLOB}" fill="url(#fill)"/>', tr)),
                  ("hat", obj(h, tr)), ("face", f'<g transform="{tr}">{dots(p, x=540)}</g>')]


PH = dict(b2.PH, hat1="#11606a", hat2="#062a31", spark="#e8ff9a")


def pals(**kw):
    light = b2.P(b2.PHOSPHOR, **{**PH, **kw})
    dark = b2.P(b2.PHOSPHOR_DARK, **{**PH, "shadow": "#000", "hat1": "#2fbf9f", "hat2": "#0e6f63", **kw})
    t = b2.trio(light, dark)
    t["mono"].update(hat1="#5a5a62", hat2="#2a2a30", spark="#ffffff")
    return t


DIRECTIONS = [
    ("wizard", "Wizard", "A small quiet blob in a floppy wizard hat, a spark at the tip.", c_wizard, pals()),
    ("wand", "Caret wand", "The wizard's wand is a text caret, sparking.", c_wand, pals()),
    ("sleepy", "Dozy wizard", "Eyes closed, hat tipped: calm while the PDF types itself.", c_sleepy, pals()),
    ("dash", "Dash", "The wizard blob leaning into a run: the fast one.", c_dash, pals()),
    ("drop", "Ink drop", "A drop of ink with two dots for eyes.", c_drop, pals()),
    ("quill", "Quill tuft", "A blob with a quill feather growing from its head.", c_quill, pals()),
    ("scholar", "Scholar", "Round glasses, small eyes: the paper-writer.", c_scholar, pals()),
    ("blink", "Blink", "One eye a dot, the other a blinking coral caret.", c_blink, pals()),
]


if __name__ == "__main__":
    root = build.HERE / "round3"
    root.mkdir(exist_ok=True)
    build.HERE = root
    build.DIRECTIONS = DIRECTIONS
    build.build()
    build.sheet("taudot round 3: a quiet blob, on Phosphor")
    print("ok", root / "sheet.png")
