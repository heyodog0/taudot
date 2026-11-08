"""Round 9: the story. The coral dot is you (your cursor); the tau is TeX, typeset right behind you.
The dot leads, the tau leans forward chasing it, and the gap between them is the lag.

Run: uv run --with pillow docs/design/logo/build9.py   (needs `resvg`)
"""

import build
import build2 as b2
import build4 as b4
import build6 as b6
import build8 as b8

LEAN = "translate(-110 -10) rotate(12 520 760)"
TAIL_EDGE, BASE_Y = 744, 771  # where the leaning tau's tail ends, and its baseline
FIT = "translate(512 500) scale(0.8) translate(-512 -512)"  # keep it all inside the safe area
R = 92


def tau_glass(p):
    return b6.obj(b8.jelly(), LEAN)


def tau_sticker(p):
    ol = f'<g transform="{LEAN}" filter="url(#sh)">{b8.jelly(color=p["line"], extra=56)}</g>'
    fill = f'<g transform="{LEAN}">{b8.jelly(color=p["paper"])}</g>'
    shine = (f'<g transform="{LEAN}" opacity="0.55"><path d="M300 330 C 330 300, 360 296, 420 296 L 600 290" '
             'fill="none" stroke="#fff" stroke-width="26" stroke-linecap="round"/></g>')
    return ol + fill + shine


def tau_hand(p):
    d = b4.wobble(b4.TAU, seed=1, grow=-30)
    tr = LEAN + " translate(-24 -36)"
    return (f'<g filter="url(#sh)"><g transform="{tr}"><path d="{d}" fill="{p["paper"]}" stroke="{p["line"]}" '
            'stroke-width="40" stroke-linejoin="round" paint-order="stroke"/></g></g>')


def you(p, cx, cy, style):
    if style == "glass":
        return b8.dot(p, cx, cy, R)
    if style == "hand":
        bl = b4.blot(cx, cy, R - 4, seed=3)
        return (f'<g filter="url(#sh)"><path d="{b4.wobble(bl, amp=0, grow=-22)}" fill="{p["line"]}"/>'
                f'<path d="{bl}" fill="{p["accent"]}"/></g>')
    return b8.dot(p, cx, cy, R, outline=28, flat=True)


def make(style, gap=28, lift=0, shadow=False):
    def fn(p):
        if style == "hand":
            defs, bg = b4.base(p)
            defs += b2.mats(p) + b8.dotdefs(p)
        else:
            defs, bg = b8.base(p)
        t = {"glass": tau_glass, "sticker": tau_sticker, "hand": tau_hand}[style](p)
        cx, cy = TAIL_EDGE + gap + R, BASE_Y - lift
        layers = [("background", bg), ("tau", t)]
        if shadow:
            layers.append(("contact", f'<ellipse cx="{cx}" cy="{BASE_Y + R - 6}" rx="{R * 0.7}" ry="16" '
                                      f'fill="{p["shadow"]}" opacity="0.35"/>'))
        layers.append(("you", you(p, cx, cy, style)))
        return defs, [layers[0]] + [(n, f'<g transform="{FIT}">{b}</g>') for n, b in layers[1:]]
    return fn


P, NIGHT = b8.pals(), b8.pals(b8.NIGHT, b2.INK, b2.INK)

DIRECTIONS = [
    ("chase", "Chase", "The tau leans in, chasing the dot a hair ahead of it.", make("glass", gap=44), P),
    ("touch", "No lag", "The tau has caught up: tail and dot touch.", make("glass", gap=-40), P),
    ("leap", "Leap", "The dot bounds ahead and up; a shadow marks the baseline.", make("glass", gap=60, lift=170,
                                                                                    shadow=True), P),
    ("cursor", "At the cursor", "The dot at x-height, where your cursor would be on the line.",
     make("glass", gap=40, lift=250), P),
    ("sticker-chase", "Sticker chase", "The chase as a bold outlined sticker.", make("sticker", gap=56), P),
    ("sticker-touch", "Sticker, no lag", "Sticker, tail and dot touching: one outline.", make("sticker", gap=-56),
     P),
    ("night-chase", "Night chase", "On ink: lime tau, cream outline, coral you.", make("sticker", gap=56), NIGHT),
    ("hand-chase", "Hand-made chase", "The hand-made brush tau leaning after a hand-drawn dot.", make("hand", gap=50), P),
]


if __name__ == "__main__":
    root = build.HERE / "round9"
    root.mkdir(exist_ok=True)
    build.HERE = root
    build.DIRECTIONS = DIRECTIONS
    build.build()
    build.sheet("taudot round 9: you lead, TeX keeps up")
    print("ok", root / "sheet.png")
