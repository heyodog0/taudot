"""Round 14: the thin tau with a bigger ball, in Lit by you's look (gradient, glow, grain, glass), on plum + ember
and on the original teal + lime.

Run: uv run --with pillow docs/design/logo/build14.py   (needs `resvg`)
"""

import build
import build2 as b2
import build6 as b6
import build8 as b8
import build9 as b9
import build10 as b10
import build11 as b11
import build13 as b13

FIELD = {k: f for k, _n, _d, f in b13.FIELDS}
PLUM, TEAL = FIELD["plum-coral"], FIELD["teal-lime"]
WARM = dict(f2="#fff1ea", tint="#b84a66", shadow="#1e0f24")  # the tau's glass, warmed for plum
COMPS = [  # (key, name, cx, cy, r, dot behind the tau?)
    ("r112", "Bigger, nearer", 856, 618, 112, False),
    ("r132", "Bigger still", 836, 628, 132, False),
    ("tuck", "Tucked", 790, 560, 118, False),
    ("eclipse", "Eclipse", 800, 470, 150, True),
]


def make(field, cx, cy, r, behind):
    def fn(p):
        defs, back = b2.background(field)
        defs += b2.mats(p) + b8.dotdefs(p)
        t = b6.obj(b11.tau("url(#fill)", b13.BAR, b13.STEM))
        d = b8.dot(p, cx, cy, r)
        layers = [("you", d), ("tau", t)] if behind else [("tau", t), ("you", d)]
        return defs, [("background", back)] + [(n, f'<g transform="{b9.FIT}">{b}</g>') for n, b in layers]
    return fn


DIRECTIONS = []
for fkey, fname, field, extra in (("plum", "Plum + ember", PLUM, WARM), ("teal", "Teal + lime", TEAL, {})):
    for key, name, cx, cy, r, behind in COMPS:
        DIRECTIONS.append((f"{fkey}-{key}", f"{fname}: {name}", f"Thin tau, r {r}" + (", behind the bar." if behind
                           else "."), make(field, cx, cy, r, behind), b10.pal(field, field, **extra)))


if __name__ == "__main__":
    root = build.HERE / "round14"
    root.mkdir(exist_ok=True)
    build.HERE = root
    build.DIRECTIONS = DIRECTIONS
    build.build()
    build.sheet("taudot round 14: thin tau, bigger ball, plum and teal")
    print("ok", root / "sheet.png")
