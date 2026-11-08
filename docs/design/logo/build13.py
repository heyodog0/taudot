"""Round 13: (a) round 12's compositions with a thinner tau; (b) "Lit by you" (gradient, glow, grain) in other colours.
The dot stays coral everywhere: coral is "you".

Run: uv run --with pillow docs/design/logo/build13.py   (needs `resvg`)
Writes round13a/ (thin) and round13b/ (colours), each with its own sheet.
"""

import build
import build2 as b2
import build8 as b8
import build9 as b9
import build10 as b10
import build11 as b11
import build12 as b12

BAR, STEM = 150, 142


def thin(cx, cy, r, tau_tr="", behind=False):
    def fn(p):
        defs, back = b2.background(b11.TWO_TONE)
        defs += b2.mats(p)
        t = f'<g filter="url(#sh)"><g transform="{tau_tr}">{b11.tau("#ffffff", BAR, STEM)}</g></g>'
        d = f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="#ff5e4d" filter="url(#sh)"/>'
        layers = [("you", d), ("tau", t)] if behind else [("tau", t), ("you", d)]
        return defs, [("background", back)] + [(n, f'<g transform="{b9.FIT}">{b}</g>') for n, b in layers]
    return fn


P = b8.pals()
THIN = [
    ("ref", "Reference", "Round 11's lighter tau, the dot at r 92.", thin(896, 601, 92), P),
    ("r112", "Bigger, nearer", "r 112, moved in towards the tail.", thin(856, 618, 112), P),
    ("r132", "Bigger still", "r 132, closer again.", thin(836, 628, 132), P),
    ("tuck", "Tucked", "r 118 under the bar's end, right of the stem.", thin(790, 560, 118), P),
    ("balance", "Balanced", "A smaller thin tau and a big dot, centred as a pair.",
     thin(836, 600, 140, b12.SMALL), P),
    ("eclipse", "Eclipse", "r 150 behind the bar's end.", thin(800, 470, 150, behind=True), P),
    ("overlap", "In front", "r 130 overlapping the stem.", thin(744, 640, 130), P),
    ("centre", "Centre", "r 150 at the centre, behind the tau.", thin(640, 600, 150, behind=True), P),
]


def lit(top, bottom, glow, grain=0.4):
    return dict(stops=[(0, top), (1, bottom)], glow=(glow, 0.55, 0.78, 0.95), grain=(grain, "overlay"))


FIELDS = [
    ("teal-lime", "Teal + lime", "The shipped one: deep teal lit lime from below.", lit("#0c3a44", "#0f6a62", "#c9f26b")),
    ("forest-amber", "Forest + amber", "Deep forest green lit amber: warmer, like a desk lamp.",
     lit("#0d2f24", "#1d5a3c", "#ffc35a")),
    ("ink-mint", "Ink + mint", "Near-black ink lit mint: the quietest.", lit("#0a1518", "#14302f", "#7fe3c0")),
    ("ocean-aqua", "Ocean + aqua", "Deep ocean blue-green lit aqua: cool and clear.",
     lit("#071f33", "#0b4a5c", "#4fe0d2")),
    ("plum-coral", "Plum + ember", "Aubergine lit a soft ember: warm, the dot glows into it.",
     lit("#1e0f24", "#43183a", "#ff8a5c")),
    ("moss-cream", "Moss + cream", "Olive-moss lit warm cream: paper and ink, hand-made.",
     lit("#1d2410", "#3d4a1f", "#f2e6b8")),
    ("pine-chartreuse", "Pine + chartreuse", "Pine green lit chartreuse: the brightest green.",
     lit("#0a2a22", "#12503e", "#d8ff3a")),
    ("slate-sky", "Slate + teal", "Blue-grey slate lit teal: calm, neutral, techy.",
     lit("#141c24", "#2a3d48", "#2fbf9f")),
]
COLORS = [(k, n, d, b10.leap(), b10.pal(f, f)) for k, n, d, f in FIELDS]


def run(name, title, dirs):
    root = build.HERE.parent / name if build.HERE.name.startswith("round13") else build.HERE / name
    root.mkdir(exist_ok=True)
    build.HERE = root
    build.DIRECTIONS = dirs
    build.build()
    build.sheet(title)
    print("ok", root / "sheet.png")


if __name__ == "__main__":
    run("round13a", "taudot round 13a: the round 12 dots, thinner tau", THIN)
    run("round13b", "taudot round 13b: Lit by you, other colours", COLORS)
