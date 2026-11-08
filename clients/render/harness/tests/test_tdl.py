"""tdl.py reads a hand-made version-1 list (dlist.md) into ops and group masks."""

import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
import tdl  # noqa: E402


def rec(kind, payload=b""):
    return struct.pack("<BI", kind, len(payload)) + payload


def make(tmp: Path) -> Path:
    black, red = struct.pack("<4f", 0, 0, 0, 1), struct.pack("<4f", 1, 0, 0, 1)
    b = b"TDL\0" + struct.pack("<I", 1)
    b += rec(0x01, struct.pack("<Iff", 0, 100, 50))
    b += rec(0x02, struct.pack("<IB", 1, 3) + struct.pack("<H", 1) + b"x")   # a font record, skipped
    b += rec(tdl.TEXT, struct.pack("<4f", 10, 10, 20, 20) + b"\0" + black + b"rest")
    b += rec(tdl.RULE, struct.pack("<4f", 30, 10, 40, 12) + red)
    b += rec(tdl.DRAW_IMAGE, struct.pack("<4f", 50, 0, 60, 10) + struct.pack("<f", 0.5) + b"\0" * 28)
    b += rec(tdl.CLIP_PATH, struct.pack("<4f", 0, 0, 100, 50))
    b += rec(tdl.UNSUPPORTED, struct.pack("<4f", 70, 30, 80, 40) + struct.pack("<H", 5) + b"shade")
    b += rec(0x00)
    p = tmp / "p.dlist"
    p.write_bytes(b)
    return p


def test_ops(tmp_path):
    size, ops = tdl.ops(make(tmp_path))
    assert size == (100, 50)
    assert [o["kind"] for o in ops] == [tdl.TEXT, tdl.RULE, tdl.DRAW_IMAGE, tdl.UNSUPPORTED]
    assert ops[1]["rgba"] == (1, 0, 0, 1)


def test_masks(tmp_path):
    m = tdl.masks(make(tmp_path), 2.0, (100, 200), pad=0)
    assert set(m) == {"text", "paths", "images", "colour", "unsupported"}
    assert m["text"][20:40, 20:40].all() and not m["text"][:, 60:].any()
    assert m["colour"][20:24, 60:80].all()      # the red rule
    assert m["colour"][0:20, 100:120].all()     # the half-transparent image
