"""The Icon Composer document (final/AppIcon.icon): flat layers that macOS 26 turns into glass, plus Assets.car.

Run: uv run docs/design/logo/build_icon.py   (needs `resvg`, Xcode 26: `actool`, Icon Composer's `ictool`)

The layers are round 14's own art from build_final.py (final/layers/): the teal field lit lime with its grain, the
glass tau with its grain and shading, and the glossy coral dot, each with its own contact shadow. The system's glass
and shadow are off, so the icon looks like the round 14 master in the default look; the system still derives the
dark, tinted and clear looks from the layers. (An earlier version used flat white and coral layers under the
system glass, which lost the texture the user picked; 2026-11-04.) Layer art is cropped to the icon shape (the .icon
canvas is full-bleed: our 824 px squircle at 100 px fills it).

Schema: copied from a real Icon Composer document (doukutsu-rs.icon) and the key names in Icon Composer's
frameworks, then checked by rendering every look with ictool and compiling with actool. The group order is top
first.
"""

import json
import shutil
import subprocess

import build

OUT = build.HERE / "final" / "AppIcon.icon"
ICTOOL = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
CROP = "100 100 824 824"  # the squircle region of our 1024 art = the whole .icon canvas


def layers():
    """build_final's layer SVGs (light palette), re-cropped to the squircle."""
    src = build.HERE / "final" / "layers"
    out = []
    for name, f in (("dot", "2-you.svg"), ("tau", "1-tau.svg"), ("background", "0-background.svg")):
        text = (src / f).read_text()
        assert 'viewBox="0 0 1024 1024"' in text, f
        out.append((name, text.replace('viewBox="0 0 1024 1024"', f'viewBox="{CROP}"', 1)))
    return out


def group(name, glass, shadow=True, scale=1.0, tinted_fill=None):
    layer = {
        "fill": "none", "glass": glass, "image-name": f"{name}.png", "name": name,
        "position-specializations": [{"value": {"scale": scale, "translation-in-points": [0, 0]}}],
    }
    if tinted_fill:
        # In the tinted and clear looks the coral would wash out to a ring: draw the layer solid instead.
        # (fill-specializations replaces the plain "fill" key; ictool ignores it when both are present.)
        del layer["fill"]
        layer["fill-specializations"] = [{"value": "none"}, {"appearance": "tinted", "value": {"solid": tinted_fill}}]
    return {
        "hidden": False,
        "layers": [layer],
        "lighting": "individual",
        "opacity": 1,
        "shadow-specializations": [{"value": {"kind": "neutral" if shadow else "none", "opacity": 0.5}}],
        "specular-specializations": [{"value": glass}],
        "translucency-specializations": [{"value": {"enabled": False, "value": 0.5}}],
    }


def main():
    if OUT.exists():
        shutil.rmtree(OUT)
    (OUT / "Assets").mkdir(parents=True)
    tmp = OUT.parent / "_layers"
    tmp.mkdir(exist_ok=True)
    for name, text in layers():
        src = tmp / f"{name}.svg"
        src.write_text(text)
        build.render(src, OUT / "Assets" / f"{name}.png", 1024)
    shutil.rmtree(tmp)
    doc = {
        "fill": {"automatic-gradient": "display-p3:0.05882,0.35294,0.36078,1.00000"},
        "groups": [group("dot", False, shadow=False, tinted_fill="srgb:1.00000,1.00000,1.00000,1.00000"),
                   group("tau", False, shadow=False), group("background", False, shadow=False)],
        "supported-platforms": {"squares": "shared"},
    }
    (OUT / "icon.json").write_text(json.dumps(doc, indent=2) + "\n")

    # Renders of every look macOS 26 offers, for the sheet and to check the document.
    renders = OUT.parent / "renders"
    renders.mkdir(exist_ok=True)
    for rendition in ("Default", "Dark", "TintedLight", "TintedDark", "ClearLight", "ClearDark"):
        args = [ICTOOL, str(OUT), "--export-image", "--output-file", str(renders / f"icon-{rendition}.png"),
                "--platform", "macOS", "--rendition", rendition, "--width", "512", "--height", "512",
                "--scale", "2"]
        if rendition.startswith("Tinted"):
            args += ["--tint-color", "0.45", "--tint-strength", "0.8"]
        r = subprocess.run(args, capture_output=True, text=True)
        print(f"  {rendition:12s}", "ok" if r.returncode == 0 else f"failed: {r.stderr.strip() or r.stdout.strip()}")

    # Compile with actool, as Xcode would: Assets.car (+ a fallback .icns) for the bundle.
    car = OUT.parent / "car"
    if car.exists():
        shutil.rmtree(car)
    car.mkdir()
    r = subprocess.run(["xcrun", "actool", str(OUT), "--compile", str(car), "--platform", "macosx",
                        "--minimum-deployment-target", "14.0", "--app-icon", "AppIcon",
                        "--output-partial-info-plist", str(car / "partial.plist"), "--output-format",
                        "human-readable-text"], capture_output=True, text=True)
    print(r.stdout.strip()[-800:] or r.stderr.strip()[-800:])
    print("ok", OUT)


if __name__ == "__main__":
    main()
