# Side by side: the sidebar half of each direction's shots (rows: designs; columns: top/selected × dark/light).
#   uv run --no-project --with pillow clients/mac/Tests/review_design_sheet.py DIR OUT.png
import sys, os
from PIL import Image, ImageDraw
d, out = sys.argv[1], sys.argv[2]
designs = ["classic", "quiet", "rail", "overleaf"]
cols = [("top", "dark"), ("selected", "dark"), ("top", "light"), ("selected", "light")]
crop = None
tiles = []
for de in designs:
    row = []
    for when, bg in cols:
        im = Image.open(os.path.join(d, f"{de}-{when}-{bg}.png")).convert("RGB")
        w, h = im.size
        crop = crop or (0, 0, int(w * 0.52), h)
        row.append(im.crop(crop).resize((int(crop[2] * 0.4), int(h * 0.4))))
    tiles.append(row)
tw, th = tiles[0][0].size
pad, label = 12, 34
sheet = Image.new("RGB", (len(cols) * (tw + pad) + pad, len(designs) * (th + label + pad) + pad), "white")
dr = ImageDraw.Draw(sheet)
for r, de in enumerate(designs):
    y = pad + r * (th + label + pad)
    for c, (when, bg) in enumerate(cols):
        x = pad + c * (tw + pad)
        dr.text((x, y + 8), f"{de}  ·  {when}  ·  {bg}", fill="black")
        sheet.paste(tiles[r][c], (x, y + label))
sheet.save(out)
print(out)
