"""Round 11: cleaner versions of the final icon ("Lit by you"): fewer effects, simpler shapes.

Run: uv run --with pillow docs/design/logo/build11.py   (needs `resvg`)
"""

import build
import build2 as b2
import build6 as b6
import build8 as b8
import build9 as b9
import build10 as b10

DOT = (b9.TAIL_EDGE + 60 + b9.R, b9.BASE_Y - 170, b9.R)


def field(stops, glow=None, grain=0.0):
    return dict(stops=stops, glow=glow, grain=(grain, "overlay"))


def tau(color, bar=196, stem=186, lean=True):
    tr = b9.LEAN if lean else "translate(-110 -10)"
    return (f'<g transform="{tr}" fill="none" stroke="{color}" stroke-linecap="round" stroke-linejoin="round">'
            f'<path d="{b6.BAR}" stroke-width="{bar}"/><path d="{b6.STEM}" stroke-width="{stem}"/></g>')


def make(bg, tau_color="#ffffff", dot_color="#ff5e4d", glass=False, shadow=False, contact=False, lean=True,
         bar=196, stem=186, dot_r=None, lift=170, soft=True):
    def fn(p):
        defs, back = b2.background(bg)
        defs += b2.mats(p)
        cx, cy, r = DOT
        r = dot_r or r
        cy = b9.BASE_Y - lift
        if not lean:
            cx -= 40
        t = tau("url(#fill)" if glass else tau_color, bar, stem, lean)
        t = b6.obj(t) if glass else (f'<g filter="url(#sh)">{t}</g>' if soft else t)
        d = f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{dot_color}"' + (' filter="url(#sh)"/>' if soft else '/>')
        layers = [("background", back), ("tau", t)]
        if contact:
            layers.append(("contact", f'<ellipse cx="{cx}" cy="{b9.BASE_Y + r - 6}" rx="{r * 0.7}" ry="16" '
                                      'fill="#032a2e" opacity="0.35"/>'))
        layers.append(("you", d))
        return defs, [layers[0]] + [(n, f'<g transform="{b9.FIT}">{b}</g>') for n, b in layers[1:]]
    return fn


DUSK_CLEAN = field([(0, "#0c3a44"), (1, "#0f6a62")], glow=("#c9f26b", 0.45, 0.78, 0.95))
TWO_TONE = field([(0, "#0d4049"), (1, "#127064")])
SOLID = field([(0, "#0f5a5c"), (1, "#0f5a5c")])
INKF = field([(0, "#0b2a30"), (1, "#0b2a30")])
CREAM = field([(0, "#fbf8ec"), (1, "#f1ecda")])

P = b8.pals()
PALE = {**P, "light": {**P["light"], "shadow": "#0a3a3a"}}

DIRECTIONS = [
    ("final", "Final (reference)", "The icon as it ships: glow, grain, glass, contact shadow.", b10.DIRECTIONS[2][3],
     b10.DIRECTIONS[2][4]),
    ("no-grain", "No grain", "The same without the grain or the contact shadow.",
     make(DUSK_CLEAN, glass=True), P),
    ("two-tone", "Two-tone", "No glow either: a plain two-tone field, flat white tau, coral dot.",
     make(TWO_TONE), P),
    ("solid", "Solid", "One flat green, one flat white, one coral. No shadows at all.", make(SOLID, soft=False), P),
    ("upright", "Upright", "Clean and calm: the tau stands straight, the dot beside it.",
     make(TWO_TONE, lean=False, lift=120), P),
    ("light", "Lighter tau", "Thinner strokes: lighter, more elegant, more like type.",
     make(TWO_TONE, bar=150, stem=142, dot_r=76), P),
    ("ink", "Ink", "Flat on near-black ink: the most minimal.", make(INKF, soft=False), P),
    ("paper", "Paper", "Inverted: deep green tau and coral dot on cream.", make(CREAM, tau_color="#0f5a5c",
                                                                             soft=False), P),
]


if __name__ == "__main__":
    root = build.HERE / "round11"
    root.mkdir(exist_ok=True)
    build.HERE = root
    build.DIRECTIONS = DIRECTIONS
    build.build()
    build.sheet("taudot round 11: cleaner")
    print("ok", root / "sheet.png")
