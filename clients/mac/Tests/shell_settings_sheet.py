# Sheets for shell_settings_shots.sh: sheet.png (every page, light above dark, then the Reduce Transparency
# fallbacks) and family.png (Settings beside the Projects window, light and dark). Args: OUT HOME_SHOTS_DIR.
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

out, home = Path(sys.argv[1]), Path(sys.argv[2])
try:
    F = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 26)
except OSError:
    F = ImageFont.load_default()

def fit(p, w):
    im = Image.open(p).convert("RGB")
    return im.resize((w, round(im.height * w / im.width)), Image.LANCZOS)

def grid(rows, w, path, bg=(232, 236, 234)):
    """rows: [(label, [(caption, path)])]"""
    pad, head = 24, 44
    cells = [[(c, fit(p, w)) for c, p in r] for _, r in rows]
    hs = [max(i.height for _, i in r) for r in cells]
    width = pad + max(len(r) for r in cells) * (w + pad)
    sheet = Image.new("RGB", (width, sum(h + head + pad for h in hs) + pad), bg)
    d = ImageDraw.Draw(sheet)
    y = pad
    for (label, _), r, h in zip(rows, cells, hs):
        for k, (cap, im) in enumerate(r):
            x = pad + k * (w + pad)
            d.text((x, y), f"{label} · {cap}" if label else cap, fill=(40, 50, 50), font=F)
            sheet.paste(im, (x, y + head))
        y += head + h + pad
    sheet.save(path)
    print(path)

pages = ["appearance", "editor", "pdf", "comments", "account"]
grid([(look, [(p, out / f"{p}-{look}.png") for p in pages]) for look in ["light", "dark"]]
     + [("Reduce Transparency", [(f"{p} {look}", out / f"{p}-{look}-solid.png") for look in ["light", "dark"] for p in ["editor", "comments"]])],
     620, out / "sheet.png")
grid([(look, [("Settings", out / f"editor-{look}.png"), ("Projects", home / f"home-list-{look}.png")]) for look in ["light", "dark"]],
     900, out / "family.png")
