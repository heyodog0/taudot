"""Round 7: round 6's chunky Litvinov-weight tau without the eyes.

Run: uv run --with pillow docs/design/logo/build7.py   (needs `resvg`)
"""

import build
import build2 as b2
import build4 as b4
import build6 as b6


def dot(p, cx=868, cy=744, r=44):
    return f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{p["accent"]}" filter="url(#sh)"/>'


def plain(p):
    defs, bg = b6.tile(p)
    return defs, [("background", bg), ("tau", b6.obj(b6.jelly()))]


def with_dot(p):
    defs, bg = b6.tile(p)
    return defs, [("background", bg), ("tau", b6.obj(b6.jelly(), "translate(-30 0)")), ("dot", dot(p))]


def glow_dot(p):
    defs, bg = b6.tile(p)
    defs += build.rad("halo", p["accent"], p["accent"], cx=0.5, cy=0.5, r=0.5, o1=0.8, o2=0)
    return defs, [("background", bg), ("tau", b6.obj(b6.jelly(), "translate(-30 0)")),
                  ("halo", '<circle cx="868" cy="744" r="92" fill="url(#halo)"/>'), ("dot", dot(p, r=40))]


def heavy(p):
    """Even chunkier: a shorter, fatter stem, like a jelly sweet."""
    defs, bg = b6.tile(p)
    inner = ('<g fill="none" stroke="url(#fill)" stroke-linecap="round" stroke-linejoin="round">'
             '<path d="M270 430 C 278 340, 326 316, 404 316 L 760 316" stroke-width="230"/>'
             '<path d="M556 350 C 550 470, 556 560, 604 640 C 640 700, 700 712, 752 700" stroke-width="214"/></g>')
    return defs, [("background", bg), ("tau", b6.obj(inner, "translate(-24 20)")), ("dot", dot(p, 860, 760, 42))]


def hand(p):
    defs, bg = b4.base(p)
    defs += b2.mats(p)
    tau = b4.g(f'<path d="{b4.wobble(b4.TAU, seed=1, grow=-34)}" fill="url(#fill)"/>', "glass", "sh")
    d = b4.g(f'<path d="{b4.blot(884, 780, 38)}" fill="{p["accent"]}"/>')
    return defs, [("background", bg), ("tau", tau), ("dot", d)]


def holo(**kw):
    return b6.pals(b6.HOLO, b2.INK, b2.INK)


DIRECTIONS = [
    ("plain", "Jelly τ", "Round 6's inflated tau, no eyes, nothing else.", plain, b6.pals()),
    ("dot", "Jelly + dot", "The inflated tau and the coral dot.", with_dot, b6.pals()),
    ("glow", "Jelly + live dot", "The coral dot glowing like a live cursor.", glow_dot, b6.pals()),
    ("heavy", "Jelly sweet", "Chunkier still: a shorter, fatter stem.", heavy, b6.pals()),
    ("night", "Night", "Glowing lime-to-teal tau on ink.", plain, holo()),
    ("night-dot", "Night + dot", "The same with the coral dot.", with_dot, holo()),
    ("night-glow", "Night + live dot", "On ink, the dot glowing.", glow_dot, holo()),
    ("hand", "Hand-made", "The hand-made brush tau at this weight, in soft glass, with the dot.", hand, b6.pals()),
]


if __name__ == "__main__":
    root = build.HERE / "round7"
    root.mkdir(exist_ok=True)
    build.HERE = root
    build.DIRECTIONS = DIRECTIONS
    build.build()
    build.sheet("taudot round 7: the tau, no eyes")
    print("ok", root / "sheet.png")
