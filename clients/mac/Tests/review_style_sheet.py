# review_style_sheet.py DIR: style-sheet.png from review_style_shots.sh's style-*.png: a row per style, columns
# dark outside / dark inside / light outside / light inside, each cropped to the commented paragraph (rows Y0..Y1 of
# the window, as fractions of its height).
import sys, os
from PIL import Image, ImageDraw, ImageFont
d = sys.argv[1]
y0, y1 = float(sys.argv[2]) if len(sys.argv) > 2 else 0.25, float(sys.argv[3]) if len(sys.argv) > 3 else 0.48
styles = ['tint', 'tint-underline', 'underline', 'bar']
cols = [('dark', 'out'), ('dark', 'in'), ('light', 'out'), ('light', 'in')]
tiles = {}
for s in styles:
    for bg, w in cols:
        im = Image.open(os.path.join(d, f'style-{s}-{bg}-{w}.png')).convert('RGB')
        W, H = im.size
        im = im.crop((0, int(H * y0), int(W * 0.62), int(H * y1)))
        tiles[s, bg, w] = im.resize((im.width // 2, im.height // 2), Image.LANCZOS)
tw, th = next(iter(tiles.values())).size
label, head, pad = 150, 40, 8
sheet = Image.new('RGB', (label + 4 * (tw + pad), head + 4 * (th + pad)), (245, 245, 245))
dr = ImageDraw.Draw(sheet)
try:
    font = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 22)
except Exception:
    font = ImageFont.load_default()
for j, (bg, w) in enumerate(cols):
    dr.text((label + j * (tw + pad) + 10, 8), f'{bg}, cursor {"inside" if w == "in" else "outside"}', fill=(20, 20, 20), font=font)
for i, s in enumerate(styles):
    dr.text((10, head + i * (th + pad) + th // 2 - 12), s.replace('tint-underline', 'tint+underline'), fill=(20, 20, 20), font=font)
    for j, (bg, w) in enumerate(cols):
        sheet.paste(tiles[s, bg, w], (label + j * (tw + pad), head + i * (th + pad)))
sheet.save(os.path.join(d, 'style-sheet.png'))
print(os.path.join(d, 'style-sheet.png'), sheet.size)
