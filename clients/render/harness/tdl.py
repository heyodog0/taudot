"""Reads a Taudot display list (clients/render/dlist.md, version 1) just far enough for the harness: each op's kind,
ink bbox and colour, turned into per-feature-group pixel masks for scoring."""

import struct
from pathlib import Path

import numpy as np

TEXT, FILL, STROKE, RULE, DRAW_IMAGE, IMAGE_MASK = 0x10, 0x11, 0x12, 0x13, 0x14, 0x15
CLIP_PATH, CLIP_STROKE, CLIP_IMAGE_MASK, POP_CLIP = 0x20, 0x21, 0x22, 0x2F
BEGIN_GROUP, END_GROUP, BEGIN_MASK, END_MASK, BEGIN_TILE, END_TILE, UNSUPPORTED = 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x3F

GROUPS = ["text", "paths", "images", "colour", "unsupported"]   # "figures" comes from paper tags until a FIGURE op


def ops(path: Path) -> tuple[tuple[float, float] | None, list[dict]]:
    """((w, h) in points, [{kind, bbox, rgba?, alpha?}]) for the ops that draw or group (clips are skipped)."""
    b = Path(path).read_bytes()
    if b[:4] != b"TDL\0":
        raise ValueError("not a TDL file")
    (version,) = struct.unpack_from("<I", b, 4)
    if version != 1:
        raise ValueError(f"TDL version {version}")
    i, size, out = 8, None, []
    while i + 5 <= len(b):
        kind, n = struct.unpack_from("<BI", b, i)
        p = i + 5
        i = p + n
        if kind == 0x00:
            break
        if kind == 0x01:
            size = struct.unpack_from("<ff", b, p + 4)
            continue
        if kind < 0x10 or kind in (CLIP_PATH, CLIP_STROKE, CLIP_IMAGE_MASK, POP_CLIP, END_GROUP, END_MASK, END_TILE):
            continue
        op = {"kind": kind, "bbox": struct.unpack_from("<4f", b, p)}
        q = p + 16
        if kind in (TEXT, FILL):
            op["mode"] = b[q]
            op["rgba"] = struct.unpack_from("<4f", b, q + 1)
        elif kind in (STROKE, RULE, IMAGE_MASK):
            op["rgba"] = struct.unpack_from("<4f", b, q)
        elif kind == DRAW_IMAGE:
            op["alpha"] = struct.unpack_from("<f", b, q)[0]
        elif kind == BEGIN_GROUP:
            op["alpha"] = struct.unpack_from("<f", b, q + 3)[0]
            op["blend"] = b[q + 2]
        out.append(op)
    return size, out


def groups_of(op: dict) -> list[str]:
    k = op["kind"]
    g = []
    if k == TEXT:
        if op.get("mode") == 4:   # invisible text draws nothing
            return []
        g.append("text")
    elif k in (FILL, STROKE, RULE):
        g.append("paths")
    elif k in (DRAW_IMAGE, IMAGE_MASK):
        g.append("images")
    elif k == UNSUPPORTED:
        g.append("unsupported")
    rgba = op.get("rgba")
    if rgba and (max(rgba[:3]) - min(rgba[:3]) > 0.02 or rgba[3] < 0.999):
        g.append("colour")
    if k in (BEGIN_GROUP, BEGIN_MASK) or op.get("alpha", 1.0) < 0.999:
        g.append("colour")   # transparency counts with colour
    return g


def masks(path: Path, scale: float, shape: tuple[int, int], pad: int = 3) -> dict:
    """{group: bool array of `shape` (h, w)}: the union of the group's op bboxes at `scale`, grown by `pad` px (the
    measure's blur reaches past the ink)."""
    _, oplist = ops(path)
    h, w = shape
    m = {g: np.zeros((h, w), bool) for g in GROUPS}
    for op in oplist:
        x0, y0, x1, y1 = op["bbox"]
        if not (x1 > x0 and y1 > y0):
            continue
        a, b_ = max(0, int(x0 * scale) - pad), max(0, int(y0 * scale) - pad)
        c, d = min(w, int(x1 * scale + 1) + pad), min(h, int(y1 * scale + 1) + pad)
        if c <= a or d <= b_:
            continue
        for g in groups_of(op):
            m[g][b_:d, a:c] = True
    return {g: v for g, v in m.items() if v.any()}
