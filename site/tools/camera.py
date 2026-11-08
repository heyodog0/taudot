# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow==11.3.0"]
# ///
"""A camera over a raw window recording: eased zooms and pans between keyframes, rendered at 1280x720 into
public/clips/<id>.mp4 (H.264, plays everywhere) and .jpg (the first frame, as the poster). The raw recording is Retina (2400 px wide), so
a 2x zoom is still sharp. Silent, 30 fps.

  uv run site/tools/camera.py RAW.mov ID SHOT.json            render
  uv run site/tools/camera.py RAW.mov ID SHOT.json --preview  one PNG per keyframe with its rectangle drawn

SHOT.json: {"start": 0.5, "length": 9, "keys": [[t, cx, cy, w], ...]}: at time t (seconds from start) the frame shows
the 16:9 rectangle of width w centred on (cx, cy), in raw pixels. Between keys the camera eases (smootherstep); two
keys with the same rectangle hold it. The rectangle is kept inside the frame.

"pointer": {"log": ACTLOG, "t0": EPOCH, "origin": [X, Y]} draws the pointer from act.swift's log over a take recorded
without one: large, pressed in while the button is down, with a coral ring at each click (coral is "you"). t0 is the
epoch record.swift printed when it started; origin is the window's top-left in screen points (raw = 2x points).
"""
import json, subprocess, sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

raw, cid, shot_path = sys.argv[1:4]
preview = "--preview" in sys.argv
shot = json.loads(Path(shot_path).read_text())
start, length, keys = shot["start"], shot["length"], shot["keys"]
TOP = 56  # the window's title bar, never shown
OUT_W, OUT_H, FPS = 1280, 720, 30
# "labels": [[t0, t1, text], ...]: a key badge at the bottom centre ("labels_at": "top" puts it at the top) while t0 <= t < t1 (e.g. a shortcut being pressed)
LABELS = shot.get("labels", [])
FONT = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 30)


def badge(im, text):
    d = ImageDraw.Draw(im, "RGBA")
    w = int(FONT.getlength(text)) + 44
    x, y = (OUT_W - w) // 2, 32 if shot.get("labels_at") == "top" else OUT_H - 86
    d.rounded_rectangle([x, y, x + w, y + 54], 27, fill=(11, 42, 48, 225))
    d.text((x + 22, y + 9), text, font=FONT, fill=(232, 243, 239, 255))
out = Path(__file__).resolve().parent.parent / "public" / "clips"

PTR = shot.get("pointer")
CORAL = (255, 94, 77)
if PTR:
    ox, oy = PTR["origin"]
    EV = []  # (t from the clip's start, raw x, raw y, kind)
    for line in Path(PTR["log"]).read_text().splitlines():
        e, x, y, kind = line.split()
        EV.append((float(e) - PTR["t0"] - start, (float(x) - ox) * 2, (float(y) - oy) * 2, kind))
    DOWNS = [e[0] for e in EV if e[3] == "down"]
    UPS = [e[0] for e in EV if e[3] == "up"]
    # The arrow, in units of the sprite (a macOS-like pointer, black with a white rim), drawn 4x and scaled down.
    ARROW = [(0, 0), (0, 16.5), (3.9, 12.8), (6.6, 19.2), (9.2, 18.1), (6.6, 11.9), (11.8, 11.9)]
    U, SS = 3.0, 4  # output px per unit (about twice the system pointer at this size), supersampling

    def sprite(scale):
        k = U * SS * scale
        pad = 3 * SS
        img = Image.new("RGBA", (int(13 * k) + 2 * pad, int(21 * k) + 2 * pad), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        pts = [(pad + x * k, pad + y * k) for x, y in ARROW]
        sh = Image.new("RGBA", img.size, (0, 0, 0, 0))
        ImageDraw.Draw(sh).polygon([(x + 1.5 * SS, y + 2.5 * SS) for x, y in pts], fill=(0, 0, 0, 70))
        img = Image.alpha_composite(sh, img); d = ImageDraw.Draw(img)
        d.polygon(pts, fill=(255, 255, 255, 255))
        inner = [(pad + x * k, pad + y * k) for x, y in [(1.6, 3.9), (1.6, 12.7), (4.3, 10.2), (7.2, 16.9), (8.0, 16.5), (5.1, 9.9), (8.4, 9.9)]]
        d.polygon(inner, fill=(0, 0, 0, 255))
        img = img.resize((img.width // SS, img.height // SS), Image.LANCZOS)
        return img, pad // SS
    SPRITES = {False: sprite(1.0), True: sprite(0.86)}

    def pointer_at(t):
        """Raw position at t (linear between logged samples) and whether the button is down."""
        if not EV or t < EV[0][0]:
            return None
        prev = EV[0]
        for e in EV:
            if e[0] > t:
                f = (t - prev[0]) / (e[0] - prev[0]) if e[0] > prev[0] else 1
                x, y = prev[1] + (e[1] - prev[1]) * f, prev[2] + (e[2] - prev[2]) * f
                break
            prev = e
        else:
            x, y = prev[1], prev[2]
        down = any(d <= t and not any(d <= u <= t for u in UPS) for d in DOWNS)
        return x, y, down

    def draw_pointer(im, t, rect):
        p = pointer_at(t)
        if not p:
            return im
        rx, ry, rw, rh = rect
        s = OUT_W / rw
        px, py = (p[0] - rx) * s, (p[1] - ry) * s
        if not (-40 < px < OUT_W + 40 and -40 < py < OUT_H + 40):
            return im
        im = im.convert("RGBA")
        ov = Image.new("RGBA", im.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(ov)
        for td in DOWNS:  # a ring grows out of each press and fades
            a = (t - td) / 0.6
            if 0 <= a < 1:
                r = 10 + 42 * (1 - (1 - a) ** 3)
                d.ellipse([px - r, py - r, px + r, py + r], outline=CORAL + (int(255 * (1 - a) ** 1.5),), width=5)
        if p[2]:
            d.ellipse([px - 11, py - 11, px + 11, py + 11], fill=CORAL + (150,))
        im = Image.alpha_composite(im, ov)
        spr, pad = SPRITES[p[2]]
        im.alpha_composite(spr, (int(px) - pad, int(py) - pad))
        return im.convert("RGB")

probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                        "-of", "csv=p=0", raw], capture_output=True, text=True, check=True).stdout.strip().split(",")
W, H = int(probe[0]), int(probe[1])


def ease(x):
    return x * x * x * (x * (x * 6 - 15) + 10)


def rect_at(t):
    if t <= keys[0][0]:
        k = keys[0]
    elif t >= keys[-1][0]:
        k = keys[-1]
    else:
        for a, b in zip(keys, keys[1:]):
            if a[0] <= t <= b[0]:
                f = ease((t - a[0]) / (b[0] - a[0])) if b[0] > a[0] else 1
                k = [t] + [a[i] + (b[i] - a[i]) * f for i in (1, 2, 3)]
                break
    _, cx, cy, w = k
    w = min(w, W, (H - TOP) * 16 / 9)
    h = w * 9 / 16
    x = min(max(cx - w / 2, 0), W - w)
    y = min(max(cy - h / 2, TOP), H - h)
    return x, y, w, h


def frame_at(t):
    r = subprocess.run(["ffmpeg", "-loglevel", "error", "-ss", str(start + t), "-i", raw, "-frames:v", "1",
                        "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True, check=True).stdout
    return Image.frombytes("RGB", (W, H), r)


if preview:
    for i, k in enumerate(keys):
        im = frame_at(k[0])
        x, y, w, h = rect_at(k[0])
        d = ImageDraw.Draw(im)
        d.rectangle([x, y, x + w, y + h], outline=(255, 60, 60), width=6)
        im.resize((W // 2, H // 2)).save(f"/tmp/td/cam-{cid}-{i}.png")
        print(f"/tmp/td/cam-{cid}-{i}.png", k)
    sys.exit(0)

dec = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-ss", str(start), "-t", str(length), "-i", raw,
                        "-vf", f"fps={FPS}", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
src = ["-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{OUT_W}x{OUT_H}", "-r", str(FPS), "-i", "-"]
enc = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-y", *src,
                        "-c:v", "libx264", "-preset", "slow", "-crf", "24", "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-an", str(out / f"{cid}.mp4")],
                       stdin=subprocess.PIPE)
n, size = 0, W * H * 3
while True:
    buf = dec.stdout.read(size)
    if len(buf) < size:
        break
    x, y, w, h = rect_at(n / FPS)
    im = Image.frombytes("RGB", (W, H), buf).crop((round(x), round(y), round(x + w), round(y + h)))
    im = im.resize((OUT_W, OUT_H), Image.LANCZOS)
    if PTR:
        im = draw_pointer(im, n / FPS, (x, y, w, h))
    for t0, t1, text in LABELS:
        if t0 <= n / FPS < t1:
            badge(im, text)
    if n == 0:
        im.save(out / f"{cid}.jpg", quality=82)
    enc.stdin.write(im.tobytes())
    n += 1
enc.stdin.close(); enc.wait(); dec.wait()
print(f"{cid}: {n} frames", *(f"{p.name} {p.stat().st_size // 1024} kB" for p in sorted(out.glob(f"{cid}.*"))))
