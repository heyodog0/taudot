"""The chosen icon (round 14, teal + lime "Bigger still": Lit by you's look, thin tau, bigger ball): masters, PNGs, AppIcon.icns, the flat mark and a favicon.

Run: uv run --with pillow docs/design/logo/build_final.py   (needs `resvg`, `iconutil`, `magick`)
Writes docs/design/logo/final/.
"""

import shutil
import subprocess

import build
import build6 as b6
import build9 as b9
import build14 as b14

OUT = build.HERE / "final"
KEY = "teal-r132"
fn, pals = next((d[3], d[4]) for d in b14.DIRECTIONS if d[0] == KEY)

# The shipped geometry, in round 9's frame (before FIT): tau strokes and the dot. build_icon.py reads these too.
BAR_W, STEM_W = 150, 142
DOT = (836, 628, 132)


def mark_svg(color="#000"):
    cx, cy, r = DOT
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{{vb}}">'
            f'<g transform="{b9.LEAN}" fill="none" stroke="{color}" stroke-linecap="round" stroke-linejoin="round">'
            f'<path d="{b6.BAR}" stroke-width="{BAR_W}"/><path d="{b6.STEM}" stroke-width="{STEM_W}"/></g>'
            f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{color}"/></svg>\n')


def bbox_of(svg_text):
    """Tight bounding box of a 1024-space drawing, measured by rendering it."""
    tmp = OUT / "_probe.svg"
    tmp.write_text(svg_text.replace("{vb}", "0 0 1024 1024"))
    subprocess.run(["resvg", "-w", "1024", str(tmp), str(OUT / "_probe.png")], check=True)
    geo = subprocess.run(["magick", str(OUT / "_probe.png"), "-trim", "-format", "%w %h %X %Y", "info:"],
                         capture_output=True, text=True, check=True).stdout.split()
    tmp.unlink()
    (OUT / "_probe.png").unlink()
    w, h, x, y = (int(v.lstrip("+")) for v in geo)
    pad = 4
    return x - pad, y - pad, w + 2 * pad, h + 2 * pad


def main():
    # Only this script's outputs: final/ also holds AppIcon.icon, car/ and renders/ (build_icon.py) and
    # TaudotMark.swift (by hand).
    shutil.rmtree(OUT / "layers", ignore_errors=True)
    (OUT / "layers").mkdir(parents=True)
    for v in build.VARIANTS:
        defs, layers = fn(pals[v])
        master = OUT / f"icon-{v}.svg"
        master.write_text(build.composite(defs, layers))
        for s in build.SIZES:
            build.render(master, OUT / f"icon-{v}-{s}.png", s)
        if v == "light":
            for i, (name, body) in enumerate(layers):
                (OUT / "layers" / f"{i}-{name}.svg").write_text(build.svg(defs, body))

    # AppIcon.icns from the light master (macOS picks the icon; dark/tinted need an .icon bundle, see notes).
    iconset = OUT / "AppIcon.iconset"
    iconset.mkdir()
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
            build.render(OUT / "icon-light.svg", iconset / name, px)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT / "AppIcon.icns")], check=True)
    shutil.rmtree(iconset)

    # The flat mark, cropped to its shape, in black (template) and in the brand's cream.
    x, y, w, h = bbox_of(mark_svg())
    vb = f"{x} {y} {w} {h}"
    (OUT / "mark.svg").write_text(mark_svg().replace("{vb}", vb))
    (OUT / "mark-cream.svg").write_text(mark_svg("#fbf8ec").replace("{vb}", vb))
    for s in (16, 32, 64, 128):
        subprocess.run(["resvg", "-h", str(s), str(OUT / "mark.svg"), str(OUT / f"mark-{s}.png")], check=True)

    # Favicon: the 1024 icon is too detailed under 32 px, so the favicon is the icon at 64 for browsers to scale.
    shutil.copy(OUT / "icon-light-64.png", OUT / "favicon-64.png")
    shutil.copy(OUT / "icon-light.svg", OUT / "favicon.svg")
    print("ok", OUT, "mark viewBox", vb)


if __name__ == "__main__":
    main()
