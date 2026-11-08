"""Round 5: iterations on the brush tau with one coral dot (round 4's "brush-dot").

Run: uv run --with pillow docs/design/logo/build5.py   (needs `resvg`)
"""

import build
import build2 as b2
import build4 as b4

HAND, g, blot = b4.HAND, b4.g, b4.blot


def tau(p, fill=None, tr=b4.CENTER):
    return g(f'<path d="{HAND}" fill="{fill or p["paper"]}"/>', "sh", tr=tr)


def dot(p, cx, cy, r, tr=b4.CENTER, color=None, seed=2):
    return g(f'<path d="{blot(cx, cy, r, seed=seed)}" fill="{color or p["accent"]}"/>', tr=tr)


def d_stop(p):
    defs, bg = b4.base(p)
    return defs, [("background", bg), ("tau", tau(p)), ("dot", dot(p, 872, 772, 38))]


def d_tucked(p):
    defs, bg = b4.base(p)
    return defs, [("background", bg), ("tau", tau(p)), ("dot", dot(p, 712, 640, 44))]


def d_tittle(p):
    defs, bg = b4.base(p)
    return defs, [("background", bg), ("tau", tau(p)), ("dot", dot(p, 764, 204, 38))]


def d_glow(p):
    defs, bg = b4.base(p)
    defs += build.rad("halo", p["accent"], p["accent"], cx=0.5, cy=0.5, r=0.5, o1=0.85, o2=0)
    halo = g('<circle cx="872" cy="772" r="140" fill="url(#halo)"/>')
    return defs, [("background", bg), ("tau", tau(p)), ("halo", halo), ("dot", dot(p, 872, 772, 36))]


def d_dab(p):
    """The dot as one press of the brush: wider than tall, pointed where the brush lifted."""
    defs, bg = b4.base(p)
    cx, cy = 872, 770
    dab = g(f'<g transform="translate({cx} {cy}) rotate(-28) scale(1.55 0.85) translate({-cx} {-cy})">'
            f'<path d="{blot(cx, cy, 34, seed=6)}" fill="{p["accent"]}"/></g>'
            f'<path d="{blot(cx + 52, cy - 28, 9, seed=7)}" fill="{p["accent"]}"/>')
    return defs, [("background", bg), ("tau", tau(p)), ("dot", dab)]


def d_splat(p):
    defs, bg = b4.base(p)
    drops = (dot(p, 866, 766, 38) + dot(p, 922, 712, 10, seed=8) + dot(p, 916, 822, 7, seed=9)
             + dot(p, 820, 830, 6, seed=10))
    return defs, [("background", bg), ("tau", tau(p)), ("dot", drops)]


def d_lean(p):
    defs, bg = b4.base(p)
    tr = b4.CENTER + " rotate(8 536 548)"
    trail = (f'<g opacity="0.55">{dot(p, 806, 812, 14, tr=tr, seed=12)}</g>'
             f'<g opacity="0.3">{dot(p, 760, 838, 9, tr=tr, seed=13)}</g>')
    return defs, [("background", bg), ("tau", tau(p, tr=tr)), ("trail", trail),
                  ("dot", dot(p, 866, 770, 38, tr=tr))]


def d_paper(p):
    """Turned around: a phosphor tau on cream paper."""
    defs, bg = b4.base(p)
    defs += ('<linearGradient id="taug" x1="0" y1="0" x2="0.3" y2="1"><stop offset="0" stop-color="#9fe37a"/>'
             f'<stop offset="0.5" stop-color="#2fbf9f"/><stop offset="1" stop-color="{p["deep"]}"/></linearGradient>')
    return defs, [("background", bg), ("tau", tau(p, fill="url(#taug)")), ("dot", dot(p, 872, 772, 38))]


PAPER = dict(stops=[(0, "#fdfbf2"), (1, "#ece5cf")], glow=None, grain=(0.16, "multiply"))
INKBG = dict(stops=[(0, "#15302f"), (1, "#081215")], glow=("#2fbf9f", 0.25, 0.3, 0.0), grain=(0.4, "overlay"))


def paper_pals():
    t = b4.pals()
    t["light"] = {**t["light"], "bg": PAPER, "shadow": "#6b5a2a", "deep": "#0c4752"}
    t["dark"] = {**t["dark"], "bg": INKBG, "deep": "#127a6a"}
    t["mono"] = {**t["mono"], "deep": "#2a2a30"}
    return t


DIRECTIONS = [
    ("stop", "Full stop", "Round 4's pick, kept as the reference: the dot ends the stroke like a full stop.",
     d_stop, b4.pals()),
    ("tucked", "Tucked", "A bigger dot nested in the tail's curl, closer to the tau: one shape, not two.", d_tucked,
     b4.pals()),
    ("tittle", "Tittle", "The dot sits above the bar's end, like the dot on an i: playful.", d_tittle, b4.pals()),
    ("glow", "Live", "The dot glows like a blinking cursor: it's live.", d_glow, b4.pals()),
    ("dab", "Brush dab", "The dot as one press of the brush, with a small fleck where it lifted.", d_dab,
     b4.pals()),
    ("splat", "Ink splat", "The dot with a few droplets around it: wet ink, just written.", d_splat, b4.pals()),
    ("lean", "Lean", "The tau leans forward 8°, the dot trailing two smaller ones: fast.", d_lean, b4.pals()),
    ("paper", "On paper", "Turned around: a phosphor-gradient tau on cream paper, same coral dot.", d_paper,
     paper_pals()),
]


if __name__ == "__main__":
    root = build.HERE / "round5"
    root.mkdir(exist_ok=True)
    build.HERE = root
    build.DIRECTIONS = DIRECTIONS
    build.build()
    build.sheet("taudot round 5: the tau and its dot")
    print("ok", root / "sheet.png")
