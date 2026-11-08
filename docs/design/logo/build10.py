"""Round 10: Leap, with the contrast fixed. Round 9's light tau sat on the light top of the Phosphor ramp; these
keep the tau on dark (or make the tau dark) everywhere it sits.

Run: uv run --with pillow docs/design/logo/build10.py   (needs `resvg`)
Prints the worst contrast between the tau and the field under it, for each light variant.
"""

import build
import build2 as b2
import build8 as b8
import build9 as b9

G = 0.4  # grain


def ramp(*stops, glow=None, grain=G):
    return dict(stops=list(stops), glow=glow, grain=(grain, "overlay"))


# Fields. Each keeps the light tau on mid-to-dark green.
DEEP = ramp((0, "#1d8c7c"), (0.55, "#0f5a5c"), (1, "#0a3440"))  # Phosphor without the lime
FLIP = ramp((0, "#0c4752"), (0.55, "#1f9c86"), (1, "#8fdc78"))  # the ramp upside down: dark top, lime floor
DUSK = ramp((0, "#0c3a44"), (1, "#0f6a62"), glow=("#c9f26b", 0.55, 0.78, 0.95))  # dark, lit from below by "you"
DIAG = dict(stops=[(0, "#0e4f58"), (0.6, "#1a9a84"), (1, "#b8ec74")], glow=None, grain=(G, "overlay"), diag=True)
LIGHT = b2.PHOSPHOR  # the original light ramp, for the dark-tau variant
INK = b2.INK


def background(spec):
    if not spec.get("diag"):
        return b2.background(spec)
    defs, body = b2.background(spec)
    return defs.replace('<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">',
                        '<linearGradient id="bg" x1="0" y1="0" x2="0.85" y2="1">'), body


def leap(style="glass", gap=60, lift=170):
    base_fn = b9.make(style, gap=gap, lift=lift, shadow=True)

    def fn(p):
        defs, layers = base_fn(p)
        bdefs, bg = background(p["bg"])
        # Swap in our field (b9 built the default one), keep everything else.
        defs = defs.replace(b2.background(p["bg"])[0], bdefs)
        return defs, [("background", bg)] + layers[1:]
    return fn


def pal(bg, dark_bg=None, **kw):
    light = {**b8.PH, **kw}
    t = b8.pals(light, bg, dark_bg or b2.PHOSPHOR_DARK)
    t["light"].update(kw)
    t["dark"].update({k: v for k, v in kw.items() if k not in ("shadow",)})
    return t


DARK_TAU = dict(f1="#1b5560", f2="#0b2a30", tint="#000000", paper="#0b2a30", line="#0b2a30", eye="#ffffff",
                shadow="#0a3a3a")

DIRECTIONS = [
    ("deep", "Deep", "Phosphor without the lime: the whole field is mid-to-deep green.", leap(), pal(DEEP)),
    ("flip", "Flipped", "The ramp upside down: dark at the top behind the tau, lime at the floor.", leap(),
     pal(FLIP)),
    ("dusk", "Lit by you", "A dark field lit from below, where the dot lands: the glow comes from you.", leap(),
     pal(DUSK)),
    ("diag", "Diagonal", "Dark top-left behind the tau, lime only in the far corner under the dot.", leap(),
     pal(DIAG)),
    ("dark-tau", "Ink tau", "Keep the light ramp, make the tau dark ink glass instead.", leap(),
     {**pal(LIGHT, **DARK_TAU), "dark": b8.pals()["dark"]}),
    ("sticker", "Sticker leap", "Keep the light ramp, give the tau a bold ink outline.", leap("sticker"),
     pal(LIGHT)),
    ("night", "Night leap", "On ink, lime glow tau, cream outline.", leap("sticker"), b8.pals(b8.NIGHT, INK, INK)),
    ("deep-sticker", "Deep sticker", "Deep field and the outline: the most legible.", leap("sticker"), pal(DEEP)),
]


def contrast_report():
    """Worst WCAG contrast between the tau's fill and the field just around it. Meaningless for the outlined
    variants, whose contrast comes from the outline."""
    from PIL import Image

    def lum(c):
        def ch(v):
            v /= 255
            return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
        r, g, b_ = c[:3]
        return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b_)

    for key, name, *_r in DIRECTIONS:
        im = Image.open(build.HERE / key / f"{key}-light-256.png").convert("RGB")
        # Sample the field just above the bar and left of the stem: where round 9 failed.
        field = [im.getpixel((x, 52)) for x in range(70, 190, 6)] + [im.getpixel((44, y)) for y in range(70, 120, 5)]
        tau = (250, 250, 245) if key != "dark-tau" else (20, 60, 66)
        worst = min((max(lum(tau), lum(f)) + 0.05) / (min(lum(tau), lum(f)) + 0.05) for f in field)
        print(f"  {name:14s} worst contrast tau/field {worst:4.1f}:1")


if __name__ == "__main__":
    root = build.HERE / "round10"
    root.mkdir(exist_ok=True)
    build.HERE = root
    build.DIRECTIONS = DIRECTIONS
    build.build()
    build.sheet("taudot round 10: Leap, readable")
    contrast_report()
    print("ok", root / "sheet.png")
