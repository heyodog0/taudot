"""Comparing two renders of a page: the oracle (MuPDF) and ours (Core Graphics). Tolerates antialiasing, catches a
misplaced or missing glyph, a missing rule, a wrong colour, a shifted figure.

MuPDF and Core Graphics antialias differently: on the same PDF, edges differ by up to ~100 levels at single pixels,
spread over every glyph. Those differences are local and conserve ink, so they vanish under a small blur; a real defect
doesn't. A pixel is *bad* when either blurred difference (max over RGB) is over its threshold:

  fine:   Gaussian sigma 1.5 px, > 28 levels   a glyph moved 0.5 pt, a missing rule, a shifted figure
  coarse: Gaussian sigma 3 px,   > 10 levels   a wrong colour, a faint or missing thin thing

Chosen by test (harness log, 2026-11-03): at 2x on text pages the floor (one PDF, MuPDF vs Core Graphics) scores
0–20 bad px; each synthetic defect drawn by Core Graphics scores 100+ (tests/test_measure.py)."""

import numpy as np
from PIL import Image
from scipy import ndimage as nd

FINE = (1.5, 28.0)
COARSE = (3.0, 10.0)
MARGIN = 25   # bad px a page may exceed its floor by and still count as within it


def load(png) -> np.ndarray:
    return np.asarray(Image.open(png).convert("RGB"), dtype=np.float32)


def _blur(a: np.ndarray, s: float) -> np.ndarray:
    return nd.gaussian_filter(a, (s, s, 0), mode="nearest")


def bad_masks(a: np.ndarray, b: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """(fine, coarse) boolean masks of bad pixels. Images of different sizes are compared on their common area and the
    rest counts as bad."""
    if a.shape != b.shape:
        h, w = max(a.shape[0], b.shape[0]), max(a.shape[1], b.shape[1])
        pa, pb = np.full((h, w, 3), -255, np.float32), np.full((h, w, 3), 510, np.float32)
        pa[:a.shape[0], :a.shape[1]] = a
        pb[:b.shape[0], :b.shape[1]] = b
        a, b = pa, pb
    fine = np.abs(_blur(a, FINE[0]) - _blur(b, FINE[0])).max(axis=2) > FINE[1]
    coarse = np.abs(_blur(a, COARSE[0]) - _blur(b, COARSE[0])).max(axis=2) > COARSE[1]
    return fine, coarse


def ssim(a: np.ndarray, b: np.ndarray) -> float:
    """Mean SSIM on luminance (Gaussian window, sigma 1.5): a perceptual score for the report, not the pass rule."""
    if a.shape != b.shape:
        return 0.0
    x, y = a.mean(axis=2), b.mean(axis=2)
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    f = lambda v: nd.gaussian_filter(v, 1.5)  # noqa: E731
    mx, my = f(x), f(y)
    vx, vy, cxy = f(x * x) - mx * mx, f(y * y) - my * my, f(x * y) - mx * my
    s = ((2 * mx * my + c1) * (2 * cxy + c2)) / ((mx * mx + my * my + c1) * (vx + vy + c2))
    return float(s.mean())


def compare(a_png, b_png, masks: dict | None = None, heatmap=None) -> dict:
    """{bad, fine, coarse, ssim, size, groups: {name: bad}} for one page. masks: {group: boolean array} areas (from the
    display list's op bboxes) scored on their own. heatmap: a PNG path for a picture of the bad pixels over the oracle."""
    a, b = load(a_png), load(b_png)
    fine, coarse = bad_masks(a, b)
    bad = fine | coarse
    r = {"bad": int(bad.sum()), "fine": int(fine.sum()), "coarse": int(coarse.sum()), "ssim": round(ssim(a, b), 5),
         "size": [int(a.shape[1]), int(a.shape[0])]}
    if a.shape != b.shape:
        r["size_ours"] = [int(b.shape[1]), int(b.shape[0])]
    if masks:
        r["groups"] = {g: int((bad[:m.shape[0], :m.shape[1]] & m[:bad.shape[0], :bad.shape[1]]).sum())
                       for g, m in masks.items()}
    if heatmap is not None:
        write_heatmap(a, fine, coarse, heatmap)
    return r


def write_heatmap(a: np.ndarray, fine: np.ndarray, coarse: np.ndarray, path) -> None:
    """The oracle faded to light grey; coarse-only bad pixels in amber, fine ones in red, grown so single pixels show."""
    h, w = fine.shape
    g = np.full((h, w, 3), 255.0, np.float32)
    g[:a.shape[0], :a.shape[1]] = 255 - (255 - a[:h, :w].mean(axis=2, keepdims=True)) * 0.35
    grow = np.ones((5, 5), bool)
    c = nd.binary_dilation(coarse, grow)
    f = nd.binary_dilation(fine, grow)
    g[c] = (245, 166, 35)
    g[f] = (220, 30, 30)
    Image.fromarray(g.astype(np.uint8)).save(path, compress_level=1)


def within_floor(ours: int, floor: int | None) -> bool | None:
    return None if floor is None else ours <= floor + MARGIN
