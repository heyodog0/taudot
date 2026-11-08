# /// script
# requires-python = ">=3.11"
# dependencies = ["playwright==1.55.0"]
# ///
"""Screenshots of the local site (wrangler dev on :8790) at desktop and phone width, light and dark, in headless
Chrome (the installed one, channel="chrome"): never on screen. Usage: uv run site/tools/shots.py OUT_DIR [/path ...]"""
import sys
from pathlib import Path
from playwright.sync_api import sync_playwright

out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
paths = sys.argv[2:] or ["/"]
SIZES = {"desktop": dict(viewport={"width": 1440, "height": 1000}, device_scale_factor=1),
         "phone": dict(viewport={"width": 390, "height": 844}, device_scale_factor=2, is_mobile=True, has_touch=True)}
with sync_playwright() as p:
    b = p.chromium.launch(channel="chrome", headless=True)
    for path in paths:
        name = path.strip("/").replace("/", "-") or "landing"
        for size, opts in SIZES.items():
            for scheme in ("light", "dark"):
                ctx = b.new_context(color_scheme=scheme, **opts)
                pg = ctx.new_page()
                pg.goto(f"http://127.0.0.1:8790{path}", wait_until="networkidle"); pg.wait_for_timeout(1800)   # the icon draws itself in
                over = pg.evaluate("document.documentElement.scrollWidth - innerWidth")
                if over > 0: print(f"{name} {size} {scheme}: {over}px horizontal overflow")
                # full_page draws fixed elements (the ground) at the first viewport's height: grow the viewport instead
                pg.set_viewport_size({"width": opts["viewport"]["width"], "height": max(opts["viewport"]["height"], pg.evaluate("document.documentElement.scrollHeight"))})
                pg.screenshot(path=out / f"{name}-{size}-{scheme}.png")
                ctx.close()
    b.close()
