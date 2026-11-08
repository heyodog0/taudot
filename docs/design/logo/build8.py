"""Round 8: a bigger, more important dot, and bold outlines.

Run: uv run --with pillow docs/design/logo/build8.py   (needs `resvg`)
"""

import build
import build2 as b2
import build4 as b4
import build6 as b6

TR = "translate(-40 -20)"


def jelly(bar=196, stem=186, color="url(#fill)", extra=0):
    return (f'<g fill="none" stroke="{color}" stroke-linecap="round" stroke-linejoin="round">'
            f'<path d="{b6.BAR}" stroke-width="{bar + extra}"/><path d="{b6.STEM}" stroke-width="{stem + extra}"/></g>')


def dotdefs(p):
    return ('<radialGradient id="dotg" cx="0.36" cy="0.3" r="0.8">'
            f'<stop offset="0" stop-color="{p["accent_hi"]}"/><stop offset="0.55" stop-color="{p["accent"]}"/>'
            f'<stop offset="1" stop-color="{p["accent_lo"]}"/></radialGradient>')


def dot(p, cx=800, cy=748, r=96, outline=0, flat=False):
    s = ""
    if outline:
        s += f'<circle cx="{cx}" cy="{cy}" r="{r + outline}" fill="{p["line"]}"/>'
    fill = p["accent"] if flat else "url(#dotg)"
    s += f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{fill}"/>'
    if not flat:
        s += (f'<ellipse cx="{cx - r * 0.32}" cy="{cy - r * 0.42}" rx="{r * 0.28}" ry="{r * 0.16}" '
              f'transform="rotate(-30 {cx - r * 0.32} {cy - r * 0.42})" fill="#fff" opacity="0.7"/>')
    return f'<g filter="url(#sh)">{s}</g>'


def base(p):
    defs, bg = b6.tile(p)
    return defs + dotdefs(p), bg


def big(p):
    defs, bg = base(p)
    return defs, [("background", bg), ("tau", b6.obj(jelly(), TR)), ("dot", dot(p))]


def huge(p):
    """The dot overlaps the tail's end, in front of it: the two lock together."""
    defs, bg = base(p)
    return defs, [("background", bg), ("tau", b6.obj(jelly(), TR)), ("dot", dot(p, 772, 736, 118))]


def hero(p):
    """The dot as the hero: a smaller tau, a big dot, about 60/40."""
    defs, bg = base(p)
    tr = "translate(150 170) scale(0.72)"
    return defs, [("background", bg), ("tau", b6.obj(jelly(), tr)), ("dot", dot(p, 748, 720, 118))]


def outlined(p):
    defs, bg = base(p)
    ol = f'<g transform="{TR}" filter="url(#sh)">{jelly(color=p["line"], extra=52)}</g>'
    return defs, [("background", bg), ("outline", ol), ("tau", f'<g transform="{TR}" filter="url(#glass)">{jelly()}</g>'),
                  ("dot", dot(p, outline=26))]


def sticker(p):
    """Flat cream and coral with a bold ink outline: a sticker."""
    defs, bg = base(p)
    ol = f'<g transform="{TR}" filter="url(#sh)">{jelly(color=p["line"], extra=56)}</g>'
    fill = f'<g transform="{TR}">{jelly(color=p["paper"])}</g>'
    shine = (f'<g transform="{TR}" opacity="0.55"><path d="M300 330 C 330 300, 360 296, 420 296 L 600 290" '
             'fill="none" stroke="#fff" stroke-width="26" stroke-linecap="round"/></g>')
    return defs, [("background", bg), ("outline", ol), ("tau", fill), ("shine", shine),
                  ("dot", dot(p, outline=28, flat=True))]


def sticker_white(p):
    """On ink: a white outline round a lime tau."""
    return sticker(p)


def live(p):
    defs, bg = base(p)
    defs += build.rad("halo", p["accent"], p["accent"], cx=0.5, cy=0.5, r=0.5, o1=0.75, o2=0)
    halo = '<circle cx="800" cy="748" r="130" fill="url(#halo)"/>'
    return defs, [("background", bg), ("tau", b6.obj(jelly(), TR)), ("halo", halo), ("dot", dot(p, r=88))]


def hand(p):
    """The hand-made brush tau with an ink outline, and the big dot."""
    defs, bg = b4.base(p)
    defs += b2.mats(p) + dotdefs(p)
    d = b4.wobble(b4.TAU, seed=1, grow=-30)
    tr = "translate(512 512) scale(0.96) translate(-560 -560)"
    tau = (f'<g filter="url(#sh)"><g transform="{tr}"><path d="{d}" fill="{p["paper"]}" stroke="{p["line"]}" '
           'stroke-width="40" stroke-linejoin="round" paint-order="stroke"/></g></g>')
    bl = b4.blot(800, 748, 92, seed=3)
    blo = b4.wobble(bl, amp=0, grow=-22)
    dt = (f'<g filter="url(#sh)"><path d="{blo}" fill="{p["line"]}"/>'
          f'<path d="{bl}" fill="{p["accent"]}"/></g>')
    return defs, [("background", bg), ("tau", tau), ("dot", dt)]


PH = dict(b6.PH, accent_hi="#ffa48a", accent_lo="#e23c30", line="#0b2a30", paper="#fbf8ec")
NIGHT = dict(b6.HOLO, accent_hi="#ffa48a", accent_lo="#e23c30", line="#fbf8ec", paper="#c9f26b")


def pals(light=PH, bg=b2.PHOSPHOR, dark_bg=b2.PHOSPHOR_DARK):
    t = b6.pals(light, bg, dark_bg)
    t["mono"].update(accent_hi="#ffffff", accent_lo="#9a9aa2", line="#1d1d22", paper="#f4f4f6")
    return t


FIT = "translate(512 512) scale(0.84) translate(-500 -512)"  # keep the tau and its dot inside the safe area


def fit(fn):
    def wrapped(p):
        defs, layers = fn(p)
        return defs, [layers[0]] + [(n, f'<g transform="{FIT}">{b}</g>') for n, b in layers[1:]]
    return wrapped


DIRECTIONS = [
    ("big", "Big dot", "The dot at full weight: as wide as the stem.", fit(big), pals()),
    ("huge", "Locked", "A bigger dot in front of the tail's end: the two lock together.", fit(huge), pals()),
    ("hero", "Dot first", "The dot as the hero: a smaller tau, a big glossy dot.", fit(hero), pals()),
    ("live", "Live", "The big dot glowing like a cursor.", fit(live), pals()),
    ("outlined", "Outlined", "Bold ink outline round the glass tau and the dot.", fit(outlined), pals()),
    ("sticker", "Sticker", "Flat cream and coral, bold ink outline, one shine: a sticker.", fit(sticker), pals()),
    ("sticker-night", "Night sticker", "On ink: a lime tau with a cream outline.", fit(sticker_white),
     pals(NIGHT, b2.INK, b2.INK)),
    ("hand", "Hand + outline", "The hand-made brush tau, outlined in ink, with a big hand-made dot.", fit(hand), pals()),
]


if __name__ == "__main__":
    root = build.HERE / "round8"
    root.mkdir(exist_ok=True)
    build.HERE = root
    build.DIRECTIONS = DIRECTIONS
    build.build()
    build.sheet("taudot round 8: a bigger dot, bold outlines")
    print("ok", root / "sheet.png")
