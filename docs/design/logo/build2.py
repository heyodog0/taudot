"""Round 2: tau as a character, and a hummingbird, in taudot's own palettes (Phosphor, Hot type), with grain and milky glass.

Run: uv run --with pillow docs/design/logo/build2.py   (needs `resvg`)
Writes round2/<key>/... and round2/sheet.png, reusing build.py's composite, renders and sheet.
"""

import build

# ---------- backgrounds ----------

# taudot's own palettes (not Glideshow's sky, not Superlogical's lavender-amber ramp).
# Phosphor: lime light from above, through teal, down to ink: the terminal's glow on paper.
PHOSPHOR = dict(stops=[(0, "#d6f78a"), (0.5, "#2fbf9f"), (1, "#0c4752")], glow=None, grain=(0.45, "overlay"))
PHOSPHOR_DARK = dict(stops=[(0, "#17403f"), (0.6, "#0d2328"), (1, "#081418")], glow=("#9be15d", 0.35, 0.85, 1.1),
                     grain=(0.4, "overlay"))
# Hot type: molten metal, after hot-metal typesetting: gold, vermilion, plum.
HOTTYPE = dict(stops=[(0, "#ffd27a"), (0.5, "#f0533f"), (1, "#5c1342")], glow=None, grain=(0.45, "overlay"))
HOTTYPE_DARK = dict(stops=[(0, "#3a1230"), (0.6, "#1d0b19"), (1, "#120710")], glow=("#f0533f", 0.4, 0.85, 1.1),
                    grain=(0.4, "overlay"))
INK = dict(stops=[(0, "#11303a"), (1, "#070f14")], glow=("#2fbf9f", 0.35, 0.2, 0.0), grain=(0.4, "overlay"))
GREY = dict(stops=[(0, "#4a4a50"), (1, "#1c1c20")], glow=None, grain=(0.25, "overlay"))


def background(spec):
    stops = "".join(f'<stop offset="{o}" stop-color="{c}"/>' for o, c in spec["stops"])
    defs = f'<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">{stops}</linearGradient>'
    body = '<rect width="1024" height="1024" fill="url(#bg)"/>'
    if spec["glow"]:
        c, o, cx, cy = spec["glow"]
        defs += build.rad("bgglow", c, c, cx=cx, cy=cy, r=0.75, o1=o, o2=0)
        body += '<rect width="1024" height="1024" fill="url(#bgglow)"/>'
    go, blend = spec["grain"]
    defs += ('<filter id="grain" x="0" y="0" width="1" height="1"><feTurbulence type="fractalNoise" '
             'baseFrequency="0.8" numOctaves="2" stitchTiles="stitch"/>'
             '<feColorMatrix type="matrix" values="0.33 0.33 0.33 0 0 0.33 0.33 0.33 0 0 0.33 0.33 0.33 0 0 0 0 0 0 1"/>'
             '<feComponentTransfer><feFuncR type="linear" slope="2.2" intercept="-0.6"/>'
             '<feFuncG type="linear" slope="2.2" intercept="-0.6"/><feFuncB type="linear" slope="2.2" intercept="-0.6"/>'
             '</feComponentTransfer>'
             '</filter>')
    body += (f'<rect width="1024" height="1024" filter="url(#grain)" opacity="{go}" '
             f'style="mix-blend-mode:{blend}"/>')
    return defs, body


# ---------- materials ----------

def glass(tint):
    """Milky glass: a soft tinted edge on the bottom-right, a bright rim on the top-left."""
    return f"""<filter id="glass" x="-40%" y="-40%" width="180%" height="180%">
  <feGaussianBlur in="SourceAlpha" stdDeviation="20" result="b"/>
  <feOffset in="b" dx="-14" dy="-22" result="o1"/>
  <feComposite in="SourceAlpha" in2="o1" operator="out" result="e1"/>
  <feFlood flood-color="{tint}" flood-opacity="0.75"/><feComposite in2="e1" operator="in" result="t1"/>
  <feGaussianBlur in="t1" stdDeviation="8" result="t1b"/>
  <feComposite in="t1b" in2="SourceAlpha" operator="in" result="shade"/>
  <feGaussianBlur in="SourceAlpha" stdDeviation="6" result="c"/>
  <feOffset in="c" dx="6" dy="10" result="o2"/>
  <feComposite in="SourceAlpha" in2="o2" operator="out" result="e2"/>
  <feFlood flood-color="#fff" flood-opacity="0.95"/><feComposite in2="e2" operator="in" result="rim"/>
  <feMerge><feMergeNode in="SourceGraphic"/><feMergeNode in="shade"/><feMergeNode in="rim"/></feMerge>
</filter>"""


def flat():
    return '<filter id="glass"><feMerge><feMergeNode in="SourceGraphic"/></feMerge></filter>'


def mats(p):
    d = build.lin("fill", p["f1"], p["f2"], 0, 0, 0.6, 1)
    d += glass(p["tint"]) if p.get("glass", True) else flat()
    d += build.shadow("sh", dy=22, sd=26, c=p["shadow"], o=0.35)
    return d


def eye(cx, cy, p, rx=30, ry=38):
    return (f'<ellipse cx="{cx}" cy="{cy}" rx="{rx}" ry="{ry}" fill="{p["eye"]}"/>'
            f'<circle cx="{cx + rx * 0.3}" cy="{cy - ry * 0.4}" r="{rx * 0.28}" fill="#fff" opacity="0.9"/>')


def streaks(p, rows):
    return "".join(f'<rect x="{x}" y="{y}" width="{w}" height="30" rx="15" fill="{p["streak"]}" '
                   f'opacity="{o}"/>' for x, y, w, o in rows)


def obj(inner, transform=""):
    return f'<g filter="url(#sh)"><g transform="{transform}" filter="url(#glass)">{inner}</g></g>'


# ---------- tau ----------

TAU_BAR = "M250 400 C 262 320, 310 300, 390 300 L 780 300"
TAU_STEM = "M560 320 C 552 480, 548 600, 600 700 C 640 770, 700 780, 770 760"


def tau_strokes(bar=150, stem=140):
    return (f'<g fill="none" stroke="url(#fill)" stroke-linecap="round" stroke-linejoin="round">'
            f'<path d="{TAU_BAR}" stroke-width="{bar}"/><path d="{TAU_STEM}" stroke-width="{stem}"/></g>')


def t_sprinter(p):
    defs, bg = background(p["bg"])
    defs += mats(p)
    tr = "translate(40 10) rotate(9 512 512)"
    body = obj(tau_strokes(), tr)
    face = (f'<g transform="{tr}">{eye(700, 282, p)}'
            f'<path d="M646 336 Q 700 362 752 330" fill="none" stroke="{p["eye"]}" stroke-width="15" '
            'stroke-linecap="round"/></g>')
    trail = streaks(p, [(150, 520, 200, 0.85), (110, 590, 270, 0.65), (180, 660, 170, 0.5)])
    return defs, [("background", bg), ("trail", trail), ("tau", body), ("face", face)]


def t_glider(p):
    defs, bg = background(p["bg"])
    defs += mats(p)
    tr = "rotate(-10 512 512) translate(-10 20)"
    body = obj(tau_strokes(140, 132), tr)
    face = f'<g transform="{tr}" fill="{p["eye"]}"><circle cx="640" cy="300" r="26"/><circle cx="720" cy="300" r="26"/></g>'
    return defs, [("background", bg), ("tau", body), ("face", face)]


def t_comet(p):
    defs, bg = background(p["bg"])
    defs += mats(p)
    tr = "translate(20 40) rotate(6 512 512)"
    bar = ('<path d="M110 312 C 240 300, 320 228, 430 226 L 780 226 Q 856 226 856 300 Q 856 374 780 374 L 430 374 '
           'C 320 372, 240 326, 110 318 Z" fill="url(#fill)"/>')
    stem = (f'<path d="M590 330 C 582 480, 578 590, 630 690 C 668 760, 726 770, 790 750" fill="none" '
            'stroke="url(#fill)" stroke-width="136" stroke-linecap="round"/>')
    body = obj(bar + stem, tr)
    face = (f'<g transform="{tr}">{eye(760, 284, p)}'
            f'<path d="M706 336 Q 756 360 806 330" fill="none" stroke="{p["eye"]}" stroke-width="15" '
            'stroke-linecap="round"/></g>')
    return defs, [("background", bg), ("tau", body), ("face", face)]


def t_caret(p):
    defs, bg = background(p["bg"])
    defs += mats(p)
    tr = "translate(0 30)"
    body = obj(tau_strokes(150, 140), tr)
    face = (f'<g transform="{tr}"><rect x="684" y="242" width="40" height="116" rx="20" fill="{p["accent"]}"/></g>')
    return defs, [("background", bg), ("tau", body), ("caret", face)]


# ---------- hummingbird ----------

BIRD = "translate(512 532) scale(0.8) translate(-552 -512)"


def bird_body(beak=True):
    s = ('<ellipse cx="480" cy="560" rx="200" ry="122" transform="rotate(-35 480 560)" fill="url(#fill)"/>'
         '<circle cx="640" cy="412" r="102" fill="url(#fill)"/>'
         '<path d="M360 640 L 205 772 Q 222 800 252 790 L 300 760 L 262 834 Q 290 852 314 830 L 430 690 Z" '
         'fill="url(#fill)"/>')
    if beak:
        s += '<path d="M712 372 L 922 268 Q 932 268 928 280 L 728 410 Z" fill="url(#fill)"/>'
    return s


WING = 'M530 470 C 470 320, 320 236, 130 250 C 220 370, 340 480, 440 550 Z'
WING2 = 'M550 460 C 548 310, 470 196, 320 140 C 336 280, 400 400, 476 520 Z'


def wings(p, tr):
    return (f'<g filter="url(#sh)"><g transform="{tr}" filter="url(#glass)">'
            f'<path d="{WING2}" fill="url(#fill)" opacity="0.55"/><path d="{WING}" fill="url(#fill)"/></g></g>')


def h_hover(p):
    defs, bg = background(p["bg"])
    defs += mats(p)
    body = obj(bird_body(), BIRD)
    face = f'<g transform="{BIRD}">{eye(668, 396, p, 22, 26)}</g>'
    caret = (f'<g transform="{BIRD}"><rect x="950" y="176" width="44" height="200" rx="22" '
             f'fill="{p["accent"]}" filter="url(#sh)"/></g>')
    return defs, [("background", bg), ("wings", wings(p, BIRD)), ("bird", body), ("face", face), ("caret", caret)]


def h_nib(p):
    defs, bg = background(p["bg"])
    defs += mats(p)
    nib = ('<path d="M718 360 L 816 316 Q 880 296 940 284 Q 900 330 856 372 L 742 418 Z" fill="url(#fill)"/>')
    body = obj(bird_body(beak=False) + nib, BIRD)
    face = (f'<g transform="{BIRD}">{eye(668, 396, p, 22, 26)}'
            f'<path d="M936 288 L 832 346" stroke="{p["eye"]}" stroke-width="9" stroke-linecap="round"/>'
            f'<circle cx="826" cy="350" r="14" fill="{p["eye"]}"/></g>')
    return defs, [("background", bg), ("wings", wings(p, BIRD)), ("bird", body), ("face", face)]


def h_dive(p):
    defs, bg = background(p["bg"])
    defs += mats(p)
    tr = "translate(512 512) scale(0.86) translate(-512 -512) translate(40 40) rotate(24 552 512)"
    body = obj(bird_body(), tr)
    face = f'<g transform="{tr}">{eye(668, 396, p, 22, 26)}</g>'
    trail = streaks(p, [(130, 610, 190, 0.85), (100, 680, 250, 0.6), (170, 750, 140, 0.45)])
    return defs, [("background", bg), ("trail", trail), ("wings", wings(p, tr)), ("bird", body), ("face", face)]


def h_geo(p):
    """Built from exact pieces: two circles, a lens wing, a triangle beak and tail."""
    defs, bg = background(p["bg"])
    defs += mats(p)
    tr = "translate(512 520) scale(0.86) translate(-512 -512)"
    parts = ('<circle cx="470" cy="580" r="170" fill="url(#fill)"/><circle cx="650" cy="400" r="100" fill="url(#fill)"/>'
             '<path d="M720 380 L 930 300 L 734 430 Z" fill="url(#fill)"/>'
             '<path d="M330 680 L 170 820 L 400 740 Z" fill="url(#fill)"/>')
    wing = ('<g filter="url(#sh)"><g transform="' + tr + '" filter="url(#glass)">'
            '<path d="M480 520 A 340 340 0 0 1 200 150 A 340 340 0 0 1 480 520 Z" fill="url(#fill)"/>'
            '<path d="M480 520 A 340 340 0 0 1 200 150 A 520 520 0 0 0 480 520 Z" fill="url(#fill)"/></g></g>')
    body = obj(parts, tr)
    face = f'<g transform="{tr}">{eye(676, 384, p, 22, 22)}</g>'
    return defs, [("background", bg), ("wing", wing), ("bird", body), ("face", face)]


# ---------- palettes ----------

def P(bg, **kw):
    base = dict(bg=bg, f1="#ffffff", f2="#f4e9ff", tint="#c9a3ff", eye="#2a1846", accent="#ff7a3d",
                shadow="#7a3a50", streak="#ffffff", glass=True)
    base.update(kw)
    return base


def trio(light, dark):
    mono = {**light, "bg": GREY, "f1": "#f6f6f8", "f2": "#d9d9de", "tint": "#8d8d96", "eye": "#1d1d22",
            "accent": "#ffffff", "shadow": "#000", "streak": "#ffffff"}
    return {"light": light, "dark": dark, "mono": mono}


PH = dict(f2="#e4fff2", tint="#1f9c86", eye="#0b2a30", accent="#ff5e4d", shadow="#0a3a3a")
HT = dict(f2="#fff0e2", tint="#e0543e", eye="#3a0c2a", accent="#21d4b4", shadow="#5c1342")
DIRECTIONS = [
    ("tau-sprinter", "τ sprinter", "Tau leaning into a run, one eye, a smile and speed streaks. Phosphor.",
     t_sprinter, trio(P(PHOSPHOR, **PH), P(PHOSPHOR_DARK, **{**PH, "shadow": "#000"}))),
    ("tau-dots", "τ two-dot", "Flat white tau with a tilt and two dots, the plainest one. Hot type.",
     t_glider, trio(P(HOTTYPE, glass=False, **{**HT, "f2": "#ffffff"}),
                    P(HOTTYPE_DARK, glass=False, **{**HT, "f2": "#f3ece8", "shadow": "#000"}))),
    ("tau-comet", "τ comet", "The tau's bar trails off into a comet tail: typeset as you type. Hot type.", t_comet,
     trio(P(HOTTYPE, **HT), P(HOTTYPE_DARK, **{**HT, "shadow": "#000"}))),
    ("tau-caret", "τ caret-eye", "Upright glass tau whose one eye is a blinking coral caret. Phosphor.", t_caret,
     trio(P(PHOSPHOR, **PH), P(PHOSPHOR_DARK, **{**PH, "shadow": "#000"}))),
    ("bird-hover", "Hummingbird", "Glass hummingbird hovering at a caret: precise, fast, live. Phosphor.", h_hover,
     trio(P(PHOSPHOR, **PH), P(PHOSPHOR_DARK, **{**PH, "shadow": "#000"}))),
    ("bird-nib", "Nib-beak", "The beak is a fountain-pen nib. Hot type.", h_nib,
     trio(P(HOTTYPE, **HT), P(HOTTYPE_DARK, **{**HT, "shadow": "#000"}))),
    ("bird-dart", "Dart", "A flat white hummingbird darting forward with speed streaks. Phosphor.", h_dive,
     trio(P(PHOSPHOR, glass=False, **{**PH, "f2": "#ffffff"}),
          P(PHOSPHOR_DARK, glass=False, **{**PH, "f2": "#eef6f2", "shadow": "#000"}))),
    ("bird-geo", "Exact bird", "Drawn from exact circles, arcs and triangles, in lime-to-teal glass on ink.", h_geo,
     trio(P(INK, f1="#e2ff8a", f2="#2fbf9f", tint="#0c4752", eye="#06222a", shadow="#000"),
          P(INK, f1="#e2ff8a", f2="#2fbf9f", tint="#0c4752", eye="#06222a", shadow="#000"))),
]

if __name__ == "__main__":
    root = build.HERE / "round2"
    root.mkdir(exist_ok=True)
    build.HERE = root
    build.DIRECTIONS = DIRECTIONS
    build.build()
    build.sheet("taudot round 2: τ and hummingbird")
    print("ok", root / "sheet.png")
