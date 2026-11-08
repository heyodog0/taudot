"""Round 12: the ball bigger and closer to the centre. Round 11's two-tone style, so only the composition changes.

Run: uv run --with pillow docs/design/logo/build12.py   (needs `resvg`)
Coordinates are in round 9's frame (before FIT), where the tau leans and its tail ends at (744, 771).
"""

import build
import build2 as b2
import build8 as b8
import build9 as b9
import build11 as b11


def make(cx, cy, r, tau_tr="", behind=False):
    def fn(p):
        defs, back = b2.background(b11.TWO_TONE)
        defs += b2.mats(p)
        t = f'<g filter="url(#sh)"><g transform="{tau_tr}">{b11.tau("#ffffff")}</g></g>'
        d = f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="#ff5e4d" filter="url(#sh)"/>'
        layers = [("you", d), ("tau", t)] if behind else [("tau", t), ("you", d)]
        return defs, [("background", back)] + [(n, f'<g transform="{b9.FIT}">{b}</g>') for n, b in layers]
    return fn


P = b8.pals()
SMALL = "translate(520 560) scale(0.86) translate(-520 -560)"
DIRECTIONS = [
    ("ref", "Round 11 two-tone", "For comparison: r 92, out at the right edge.", make(896, 601, 92), P),
    ("r112", "Bigger, nearer", "r 112, moved in towards the tail.", make(862, 618, 112), P),
    ("r132", "Bigger still", "r 132, closer again: the dot starts to rival the tau.", make(846, 628, 132), P),
    ("tuck", "Tucked", "r 118, nestled under the bar's end, right of the stem: hugging the tau.",
     make(800, 560, 118), P),
    ("balance", "Balanced", "A smaller tau and a big dot (r 140), side by side, centred as a pair.",
     make(846, 600, 140, SMALL), P),
    ("eclipse", "Eclipse", "A big dot (r 150) behind the bar's end: the tau passes in front of you.",
     make(800, 470, 150, behind=True), P),
    ("overlap", "In front", "A big dot (r 130) overlapping the stem, in front of it.", make(760, 640, 130), P),
    ("centre", "Centre", "The dot at the tile's centre (r 150), the tau leaning over it from behind.",
     make(640, 600, 150, behind=True), P),
]


if __name__ == "__main__":
    root = build.HERE / "round12"
    root.mkdir(exist_ok=True)
    build.HERE = root
    build.DIRECTIONS = DIRECTIONS
    build.build()
    build.sheet("taudot round 12: a bigger, more central dot")
    print("ok", root / "sheet.png")
