"""The paragraph preview (`para` events) on the real live engine with patch 0011 (skipped without it).

    TAUDOT_TEST_ENGINE=<a build with 0011>/live/texk/web2c/pdflatex uv run --no-project --with pytest pytest tests/test_para.py
"""
import os
import struct

import pytest

FILL = "Some words to fill the line and then a few more. " * 5
DOC = r"""\documentclass{article}
\begin{document}
%s

FOOTNOTE paragraph with a note\footnote{The note.} and then %s

DISPLAY paragraph before %s
\[ a^2 + b^2 = c^2 \]
after the display %s
\end{document}
"""


def doc(n=12):
    return DOC % ("\n\n".join(f"Paragraph {i}. {FILL}" for i in range(n)), FILL, FILL, FILL)


def has_para(real):
    """Patch 0011 is in the engine (it names the paragraph-preview procedure)."""
    try:
        return b"para-%d.out" in open(os.path.realpath(real["engine"]), "rb").read()
    except OSError:
        return False


def typing(s, text, mark, n, gap=0.4):
    """n keys after `mark`; the para events they bring."""
    pos = text.index(mark) + len(mark)
    got = []
    for i in range(n):
        s.send(["change", "main.tex", pos + i, 0, "x"])
        got += [e for e in s.drain(gap) if e["ev"] == "para"]
    return got


def tdl_ok(path):
    b = open(path, "rb").read()
    assert b[:4] == b"TDL\0" and struct.unpack("<I", b[4:8])[0] == 2
    kinds, i = [], 8
    while i < len(b):
        k, n = b[i], struct.unpack("<I", b[i + 1:i + 5])[0]
        kinds.append(k)
        i += 5 + n
    assert kinds[-1] == 0 and 0x10 in kinds  # glyphs, then END
    return kinds


def test_para_typing_gives_exact_previews(serve, real):
    if not has_para(real):
        pytest.skip("engine without patch 0011")
    text = doc()
    s = serve({"main.tex": text}, engine=real["engine"], env=real["env"], args=real["args"])
    s.done(1, timeout=60)
    ev = typing(s, text, "Paragraph 7. Some", 4)
    shown = [e for e in ev if e["state"] != "none"]
    assert len(shown) >= 2, ev  # the first key leaves the paragraph snapshot; the next ones are previewed
    for e in shown:
        assert e["state"] == "exact" and e["lines"] == e["old_lines"]
        assert os.path.exists(e["overlay"]) and open(e["overlay"], "rb").read(5) == b"%PDF-"
        tdl_ok(e["path"])
        assert len(e["erase"]) == 2 * e["lines"] and all(r[0] < r[2] and r[1] < r[3] for r in e["erase"])
        assert e["applied"] >= 2 and e["engine_us"] > 0
    assert [e["go"] for e in ev] == sorted(e["go"] for e in ev)
    assert s.close() == 0


def test_para_falls_back(serve, real):
    if not has_para(real):
        pytest.skip("engine without patch 0011")
    text = doc(4)
    s = serve({"main.tex": text}, engine=real["engine"], env=real["env"], args=real["args"])
    s.done(1, timeout=60)
    foot = typing(s, text, "FOOTNOTE paragraph", 3)
    assert foot and all(e["state"] == "none" and e["why"] == "insert" for e in foot[1:]), foot
    disp = typing(s, text.replace("FOOTNOTE paragraph", "FOOTNOTE paragraphxxx"), "a^2 + b", 3)
    assert disp and all(e["state"] == "none" and e["why"] == "display" for e in disp[1:]), disp
    assert s.close() == 0


def test_para_off(serve, real):
    if not has_para(real):
        pytest.skip("engine without patch 0011")
    text = doc(6)
    s = serve({"main.tex": text}, engine=real["engine"], env=dict(real["env"], TAUDOT_PARA="0"), args=real["args"])
    s.done(1, timeout=60)
    assert typing(s, text, "Paragraph 3. Some", 3) == []
    assert s.close() == 0
