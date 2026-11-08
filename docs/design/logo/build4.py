"""Round 4: back to the tau, minimal, and made to look hand-made (brush, nib, letterpress, cut paper, stamp).

Run: uv run --with pillow docs/design/logo/build4.py   (needs `resvg`)
"""

import build
import build2 as b2

# A hand-drawn brush tau as one filled outline: a bar whose left end hooks down, a stem that kicks right.
TAU = ("M236 430 C 236 360, 280 318, 360 312 C 480 302, 640 292, 800 280 C 830 278, 836 300, 806 312 "
       "C 700 330, 620 338, 590 340 C 580 450, 576 580, 600 680 C 620 760, 680 790, 760 770 "
       "C 790 762, 796 790, 770 800 C 660 840, 510 790, 490 660 C 476 560, 486 440, 494 352 "
       "C 440 360, 390 370, 340 390 C 300 408, 290 440, 280 470 C 270 490, 236 470, 236 430 Z")
# The same with a rounder, heavier right end on the bar: a head, for the one-eye variant.
TAU_HEAD = ("M236 430 C 236 360, 280 318, 360 312 C 480 302, 640 286, 770 266 C 840 256, 872 330, 806 346 "
            "C 700 352, 620 344, 590 346 C 580 450, 576 580, 600 680 C 620 760, 680 790, 760 770 "
            "C 790 762, 796 790, 770 800 C 660 840, 510 790, 490 660 C 476 560, 486 440, 494 356 "
            "C 440 362, 390 372, 340 392 C 300 408, 290 440, 280 470 C 270 490, 236 470, 236 430 Z")
# Centre line, for the monoline pencil and the nib.
SPINE = "M262 452 C 262 380, 300 338, 380 334 L 800 304 M 548 336 C 532 470, 530 600, 560 690 C 590 770, 680 790, 770 772"
CENTER = "translate(512 512) scale(1.0) translate(-536 -548)"  # centre the tau and enlarge it


# ---------- hand wobble, in the geometry (resvg's noise filters come out jagged, not hand-made) ----------

import math
import random
import re


def _subpaths(d):
    """Parse an absolute M/C/L/Z path into lists of points (cubics flattened)."""
    toks = re.findall(r"[MCLZ]|-?\d+(?:\.\d+)?", d)
    subs, cur, pen, i, cmd = [], None, (0, 0), 0, None
    while i < len(toks):
        t = toks[i]
        if t in "MCLZ":
            cmd = t
            i += 1
            if t == "Z":
                cur.append(cur[0])
                cur = None
            continue
        if cmd == "M":
            pen = (float(toks[i]), float(toks[i + 1]))
            cur = [pen]
            subs.append(cur)
            i += 2
            cmd = "L"
        elif cmd == "L":
            pen = (float(toks[i]), float(toks[i + 1]))
            cur.append(pen)
            i += 2
        elif cmd == "C":
            x1, y1, x2, y2, x, y = map(float, toks[i:i + 6])
            x0, y0 = pen
            for k in range(1, 25):
                u = k / 24
                a, b, c, e = (1 - u) ** 3, 3 * u * (1 - u) ** 2, 3 * u * u * (1 - u), u ** 3
                cur.append((a * x0 + b * x1 + c * x2 + e * x, a * y0 + b * y1 + c * y2 + e * y))
            pen = (x, y)
            i += 6
    return subs


def wobble(d, amp=3.6, seed=1, waves=((190, 1.0), (80, 0.5), (36, 0.14)), grow=0.0):
    """Push each point along its normal by a smooth, seeded sum of waves: a steady hand, not a machine."""
    rnd = random.Random(seed)
    phases = [rnd.uniform(0, 2 * math.pi) for _ in waves]
    out = []
    for pts in _subpaths(d):
        closed = pts[0] == pts[-1]
        s, res = 0.0, []
        for j, (x, y) in enumerate(pts):
            if j:
                s += math.dist(pts[j - 1], (x, y))
            a = pts[max(j - 1, 0)]
            b = pts[min(j + 1, len(pts) - 1)]
            dx, dy = b[0] - a[0], b[1] - a[1]
            n = math.hypot(dx, dy) or 1
            w = grow + amp * sum(m * math.sin(2 * math.pi * s / L + ph) for (L, m), ph in zip(waves, phases))
            res.append((x - dy / n * w, y + dx / n * w))
        if closed:
            res[-1] = res[0]
        out.append("M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in res) + (" Z" if closed else ""))
    return " ".join(out)


def blot(cx, cy, r, seed=2):
    """A hand-drawn dot: a circle with a slight wobble."""
    k = 0.5523 * r
    d = (f"M{cx} {cy - r} C {cx + k} {cy - r}, {cx + r} {cy - k}, {cx + r} {cy} C {cx + r} {cy + k}, {cx + k} {cy + r}, "
         f"{cx} {cy + r} C {cx - k} {cy + r}, {cx - r} {cy + k}, {cx - r} {cy} C {cx - r} {cy - k}, {cx - k} {cy - r}, "
         f"{cx} {cy - r} Z")
    return wobble(d, amp=r * 0.04, seed=seed, waves=((r * 3.0, 1.0), (r * 1.6, 0.4)))


def gaps(seed=4, n=46):
    """Where a stamp didn't take: small irregular specks, mostly along the stroke."""
    rnd = random.Random(seed)
    pts = [pt for sub in _subpaths(TAU) for pt in sub]
    out = []
    for _ in range(n):
        x, y = rnd.choice(pts)
        cx, cy = 512 + (x - 512) * 0.93 + rnd.uniform(-14, 14), 545 + (y - 545) * 0.93 + rnd.uniform(-14, 14)
        out.append(blot(round(cx), round(cy), rnd.uniform(3, 11), seed=rnd.randint(0, 999)))
    return " ".join(out)


GROW = -22  # thicken every stroke of the outline by this much on each side
HAND = wobble(TAU, seed=1, grow=GROW)
NIBLINE = wobble(SPINE, amp=3, seed=2)


def rough(id, scale=9, freq=0.035, seed=3):
    """Wobbly, ink-on-paper edges."""
    return (f'<filter id="{id}" x="-10%" y="-10%" width="120%" height="120%">'
            f'<feTurbulence type="fractalNoise" baseFrequency="{freq}" numOctaves="2" seed="{seed}" result="n"/>'
            f'<feDisplacementMap in="SourceGraphic" in2="n" scale="{scale}" xChannelSelector="R" '
            'yChannelSelector="G"/></filter>')


def ink(id, seed=5):
    """Uneven coverage: a stamp or a dry brush, mostly solid with small gaps, plus rough edges."""
    return (f'<filter id="{id}" x="-10%" y="-10%" width="120%" height="120%">'
            f'<feTurbulence type="fractalNoise" baseFrequency="0.05" numOctaves="3" seed="{seed}" result="n"/>'
            '<feColorMatrix in="n" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 -9 5.3" result="m"/>'
            '<feComposite in="SourceGraphic" in2="m" operator="in" result="s"/>'
            f'<feTurbulence type="fractalNoise" baseFrequency="0.03" numOctaves="2" seed="{seed + 1}" result="d"/>'
            '<feDisplacementMap in="s" in2="d" scale="12" xChannelSelector="R" yChannelSelector="G"/></filter>')


def fibre(id):
    """Paper fibre: fine noise multiplied over the shape."""
    return (f'<filter id="{id}"><feTurbulence type="fractalNoise" baseFrequency="1.4" numOctaves="2" result="n"/>'
            '<feColorMatrix in="n" type="matrix" values="0 0 0 0 0.92  0 0 0 0 0.9  0 0 0 0 0.84  0 0 0 0.9 -0.25" '
            'result="f"/><feComposite in="f" in2="SourceAlpha" operator="in" result="fi"/>'
            '<feMerge><feMergeNode in="SourceGraphic"/><feMergeNode in="fi"/></feMerge></filter>')


def press(id, light, dark):
    """Letterpress: the shape is pressed into the field, shadow at top-left, light at bottom-right."""
    return f"""<filter id="{id}" x="-10%" y="-10%" width="120%" height="120%">
  <feGaussianBlur in="SourceAlpha" stdDeviation="7" result="b"/>
  <feOffset in="b" dx="9" dy="12" result="o1"/><feComposite in="SourceAlpha" in2="o1" operator="out" result="e1"/>
  <feFlood flood-color="{dark}" flood-opacity="0.7"/><feComposite in2="e1" operator="in" result="sh"/>
  <feOffset in="b" dx="-5" dy="-7" result="o2"/><feComposite in="SourceAlpha" in2="o2" operator="out" result="e2"/>
  <feFlood flood-color="{light}" flood-opacity="0.55"/><feComposite in2="e2" operator="in" result="hi"/>
  <feMerge><feMergeNode in="SourceGraphic"/><feMergeNode in="sh"/><feMergeNode in="hi"/></feMerge>
</filter>"""


def base(p):
    defs, bg = b2.background(p["bg"])
    defs += build.shadow("sh", dy=16, sd=18, c=p["shadow"], o=0.3)
    return defs, bg


def g(inner, *filters, tr=CENTER):
    s = f'<g transform="{tr}">{inner}</g>'
    for f in filters:
        s = f'<g filter="url(#{f})">{s}</g>'
    return s


def v_brush(p):
    defs, bg = base(p)
    return defs, [("background", bg), ("tau", g(f'<path d="{HAND}" fill="{p["paper"]}"/>', "sh"))]


def v_dot(p):
    defs, bg = base(p)
    tau = g(f'<path d="{HAND}" fill="{p["paper"]}"/>', "sh")
    dot = g(f'<path d="{blot(872, 772, 38)}" fill="{p["accent"]}"/>')
    return defs, [("background", bg), ("tau", tau), ("dot", dot)]


def v_eye(p):
    defs, bg = base(p)
    tau = g(f'<path d="{wobble(TAU_HEAD, seed=7, grow=GROW)}" fill="{p["paper"]}"/>', "sh")
    eye = g(f'<path d="{blot(804, 304, 15)}" fill="{p["ink"]}"/>')
    return defs, [("background", bg), ("tau", tau), ("eye", eye)]


def v_nib(p):
    """Broad-nib pen: thick downstrokes, thin across, as a calligrapher would write it."""
    defs, bg = base(p)
    # A nib held at 30 degrees: draw the spine many times along the nib's edge.
    strokes = "".join(f'<path d="{NIBLINE}" transform="translate({i * 3.2:.1f} {-i * 1.85:.1f})"/>' for i in range(-22, 23))
    tau = g(f'<g fill="none" stroke="{p["paper"]}" stroke-width="7" stroke-linecap="round">{strokes}</g>',
            "sh")
    return defs, [("background", bg), ("tau", tau)]


def v_pencil(p):
    """One wobbly monoline, like a confident pencil sketch, with a coral caret."""
    defs, bg = base(p)
    tau = g(f'<path d="{wobble(SPINE, amp=4, seed=5)}" fill="none" stroke="{p["paper"]}" stroke-width="112" stroke-linecap="round" '
            'stroke-linejoin="round"/>', "sh")
    caret = g(f'<rect x="866" y="610" width="34" height="170" rx="17" fill="{p["accent"]}"/>')
    return defs, [("background", bg), ("tau", tau), ("caret", caret)]


def v_press(p):
    defs, bg = base(p)
    defs += press("press", p["press_hi"], p["press_sh"])
    tau = g(f'<path d="{HAND}" fill="{p["press_fill"]}"/>', "press")
    dot = g(f'<path d="{blot(872, 772, 34)}" fill="{p["accent"]}"/>', "press")
    return defs, [("background", bg), ("tau", tau), ("dot", dot)]


def v_paper(p):
    """Cut paper: a lime sheet and a cream sheet, a little out of register."""
    defs, bg = base(p)
    under = g(f'<path d="{HAND}" fill="{p["under"]}" transform="translate(18 16) rotate(1.5 512 512)"/>', "sh")
    top = g(f'<path d="{HAND}" fill="{p["paper"]}"/>', "sh")
    return defs, [("background", bg), ("under", under), ("tau", top)]


def v_stamp(p):
    defs, bg = base(p)
    defs += f'<mask id="gaps"><rect width="1024" height="1024" fill="#fff"/><path d="{gaps()}" fill="#000"/></mask>'
    tau = g(f'<path d="{wobble(TAU, amp=7, seed=9, grow=GROW)}" fill="{p["paper"]}" mask="url(#gaps)"/>')
    return defs, [("background", bg), ("tau", tau)]


def pals(**kw):
    light = b2.P(b2.PHOSPHOR, **{**b2.PH, "paper": "#fbf8ec", "ink": "#0b2a30", "under": "#d6f78a",
                                 "press_fill": "#1fa58a", "press_hi": "#e8ffd0", "press_sh": "#053a3f", **kw})
    dark = b2.P(b2.PHOSPHOR_DARK, **{**b2.PH, "paper": "#f3efe0", "ink": "#0b2a30", "under": "#2fbf9f",
                                     "shadow": "#000", "press_fill": "#0e2a2e", "press_hi": "#5fd8b8",
                                     "press_sh": "#000", **kw})
    t = b2.trio(light, dark)
    t["mono"].update(paper="#f4f4f6", ink="#1d1d22", under="#8e8e96", press_fill="#38383e", press_hi="#a0a0a8",
                     press_sh="#000")
    return t


DIRECTIONS = [
    ("brush", "Brush", "One loaded brush stroke, rough at the edges. Nothing else.", v_brush, pals()),
    ("brush-dot", "Brush + dot", "The brush tau and a single coral dot: the cursor, the full stop.", v_dot, pals()),
    ("brush-eye", "One eye", "The bar's end swells into a head with one tiny eye: the mascot, barely.", v_eye,
     pals()),
    ("nib", "Broad nib", "Written with a broad-nib pen: thick downstroke, thin crossbar.", v_nib, pals()),
    ("pencil", "Pencil line", "One confident wobbly line and a coral caret.", v_pencil, pals()),
    ("press", "Letterpress", "Pressed into the green, no ink, one coral dot.", v_press, pals()),
    ("paper", "Cut paper", "Cream paper over lime paper, a little out of register.", v_paper, pals()),
    ("stamp", "Stamp", "A rubber stamp: uneven ink, gaps and all.", v_stamp, pals()),
]


if __name__ == "__main__":
    root = build.HERE / "round4"
    root.mkdir(exist_ok=True)
    build.HERE = root
    build.DIRECTIONS = DIRECTIONS
    build.build()
    build.sheet("taudot round 4: a hand-made tau")
    print("ok", root / "sheet.png")
