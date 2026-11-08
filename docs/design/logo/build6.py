"""Round 6: the tau the way Dmitri Litvinov (appicons.store) builds an icon: one chunky inflated shape that is the
character, two pill eyes, soft volume and light, a saturated tile, nothing else.

Run: uv run --with pillow docs/design/logo/build6.py   (needs `resvg`)
"""

import build
import build2 as b2
import build4 as b4

BAR = "M262 420 C 270 330, 320 300, 400 300 L 770 300"
STEM = "M560 330 C 552 480, 552 590, 600 680 C 636 748, 700 760, 760 744"


def jelly(bar=196, stem=186):
    return (f'<g fill="none" stroke="url(#fill)" stroke-linecap="round" stroke-linejoin="round">'
            f'<path d="{BAR}" stroke-width="{bar}"/><path d="{STEM}" stroke-width="{stem}"/></g>')


def pills(p, x=640, y=300, gap=84, w=54, h=100, color=None, shine=True, look=0):
    c = color or p["eye"]
    s = ""
    for cx in (x, x + gap):
        s += f'<rect x="{cx - w / 2 + look}" y="{y - h / 2}" width="{w}" height="{h}" rx="{w / 2}" fill="{c}"/>'
        if shine:
            s += f'<circle cx="{cx + look + w * 0.12}" cy="{y - h * 0.22}" r="{w * 0.17}" fill="#fff" opacity="0.85"/>'
    return s


def tile(p, tr=""):
    defs, bg = b2.background(p["bg"])
    defs += b2.mats(p)
    return defs, bg


def obj(inner, tr=""):
    return b2.obj(inner, tr)


def l_jelly(p):
    defs, bg = tile(p)
    return defs, [("background", bg), ("tau", obj(jelly())), ("eyes", pills(p))]


def l_dot(p):
    defs, bg = tile(p)
    dot = f'<circle cx="868" cy="744" r="44" fill="{p["accent"]}" filter="url(#sh)"/>'
    return defs, [("background", bg), ("tau", obj(jelly(), "translate(-30 0)")),
                  ("eyes", f'<g transform="translate(-30 0)">{pills(p, look=8)}</g>'), ("dot", dot)]


def l_peek(p):
    """Big, cropped by the tile's bottom edge: only the head and the top of the stem show."""
    defs, bg = tile(p)
    tr = "translate(512 560) scale(1.28) translate(-520 -330)"
    return defs, [("background", bg), ("tau", obj(jelly(), tr)),
                  ("eyes", f'<g transform="{tr}">{pills(p, x=628, gap=84, look=-6)}</g>')]


def l_cutout(p):
    """The eyes are holes: you see the tile through them."""
    defs, bg = tile(p)
    defs += ('<mask id="holes" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024"><rect width="1024" height="1024" fill="#fff"/>'
             f'{pills(p, color="#000", shine=False)}</mask>')
    return defs, [("background", bg), ("tau", f'<g mask="url(#holes)">{obj(jelly())}</g>')]


def l_wink(p):
    """One eye a pill, the other the coral dot: the cursor."""
    defs, bg = tile(p)
    eyes = (f'<rect x="613" y="250" width="54" height="100" rx="27" fill="{p["eye"]}"/>'
            f'<circle cx="646" cy="278" r="9" fill="#fff" opacity="0.85"/>'
            f'<circle cx="724" cy="300" r="40" fill="{p["accent"]}"/>')
    return defs, [("background", bg), ("tau", obj(jelly())), ("eyes", eyes)]


def l_hand(p):
    """Round 4's hand-made brush outline, fattened to his weight, with his pill eyes."""
    defs, bg = b4.base(p)
    defs += b2.mats(p)
    hand = b4.wobble(b4.TAU, seed=1, grow=-34)
    tau = b4.g(f'<path d="{hand}" fill="url(#fill)"/>', "glass", "sh")
    eyes = b4.g(pills(p, x=666, y=318, gap=74, w=46, h=86))
    dot = b4.g(f'<path d="{b4.blot(880, 778, 36)}" fill="{p["accent"]}"/>')
    return defs, [("background", bg), ("tau", tau), ("eyes", eyes), ("dot", dot)]


INK = b2.INK
PH = dict(f1="#ffffff", f2="#dcfbec", tint="#1f9c86", eye="#0b2a30", accent="#ff5e4d", shadow="#0a3a3a",
          streak="#ffffff", paper="#fbf8ec")
HOLO = dict(f1="#e8ff8f", f2="#22b496", tint="#0c4752", eye="#ffffff", accent="#ff5e4d", shadow="#000",
            streak="#ffffff", paper="#e8ff8f")


def pals(light=PH, bg=b2.PHOSPHOR, dark_bg=b2.PHOSPHOR_DARK, dark=None):
    L = b2.P(bg, **light)
    D = b2.P(dark_bg, **{**(dark or light), "shadow": "#000"})
    t = b2.trio(L, D)
    t["mono"]["paper"] = "#f4f4f6"
    return t


DIRECTIONS = [
    ("jelly", "Jelly τ", "His construction: one inflated tau, two pill eyes on the bar, soft light.", l_jelly, pals()),
    ("jelly-dot", "Jelly + dot", "The same, glancing at our coral dot.", l_dot, pals()),
    ("peek", "Peek", "Big and cropped by the tile's edge, peeking in: his favourite move.", l_peek, pals()),
    ("cutout", "Cut-out eyes", "The eyes are holes in the tau, the tile shows through.", l_cutout, pals()),
    ("wink", "Wink", "One pill eye, and the coral dot as the other.", l_wink, pals()),
    ("holo", "Night", "His dark-tile look: a glowing lime-to-teal tau with white eyes on ink.", l_dot,
     pals(HOLO, INK, INK)),
    ("holo-peek", "Night peek", "The peek on ink, glowing.", l_peek, pals(HOLO, INK, INK)),
    ("hand", "Hand + eyes", "Our hand-made brush tau at his weight, with his eyes and our dot.", l_hand, pals()),
]


if __name__ == "__main__":
    root = build.HERE / "round6"
    root.mkdir(exist_ok=True)
    build.HERE = root
    build.DIRECTIONS = DIRECTIONS
    build.build()
    build.sheet("taudot round 6: the tau, the Litvinov way")
    print("ok", root / "sheet.png")
