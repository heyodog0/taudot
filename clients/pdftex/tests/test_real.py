"""The --serve driver on the real live engine (skipped without the pdftex agent's build)."""
import os

ART = r"""\documentclass{article}
\begin{document}
%s
\end{document}
"""


def paras(n):
    return "\n\n".join(f"Paragraph {i}. " + "Some words to fill a line or two of text. " * 6 for i in range(n))


def test_real_smoke(serve, real):
    s = serve({"main.tex": ART % paras(40)}, engine=real["engine"], env=real["env"], args=real["args"])
    d = s.done(1, timeout=60)
    assert d["code"] == 0 and d["pages"] >= 2 and os.path.exists(d["path"])
    pos = (ART % paras(40)).index("Paragraph 20")
    s.send(["change", "main.tex", pos, 0, "Edited. "])
    d = s.done(2, timeout=30)
    assert d["code"] == 0
    assert s.close() == 0


def test_real_c1_rollbacks_back_to_back(serve, real):
    """C1 on the real engine: edits at the top in consecutive commands, each its own batch."""
    import time
    s = serve({"main.tex": ART % paras(40)}, engine=real["engine"], env=real["env"], args=real["args"])
    s.done(1, timeout=60)
    for i in range(20):
        s.send(["change", "main.tex", 0, 0, "%\n"])
        time.sleep(0.002)
    d = s.done(timeout=30)
    s.drain(1.0)
    assert s.alive()
    assert s.close() == 0


BIB = r"""\documentclass{article}
\begin{document}
See \cite{knuth}.
\bibliographystyle{plain}
\bibliography{refs}
\end{document}
"""


def test_real_c3_reopen_with_changed_bib(serve, real, tmp_path):
    from conftest import Serve
    state = tmp_path / "state"
    args = real["args"] + ["--state", str(state)]
    s = serve({"main.tex": BIB, "refs.bib": "@book{knuth, title={Old Title}, author={D. Knuth}, year=1984}\n"},
              engine=real["engine"], env=real["env"], args=args)
    s.done(timeout=60)
    s.drain(0.5)
    assert "Old Title" in open(os.path.join(s.out, "work", "main.bbl")).read()
    assert s.close() == 0
    (s.proj / "refs.bib").write_text("@book{knuth, title={New Title}, author={D. Knuth}, year=1984}\n")
    s2 = Serve({"driver": s.p.args[0]}, s.proj, tmp_path / "out2", engine=real["engine"], env=real["env"], args=args)
    s2.done(timeout=60)
    s2.drain(0.5)
    assert "New Title" in open(os.path.join(s2.out, "work", "main.bbl")).read()
    assert s2.close() == 0


def engine_retires(engine):
    import subprocess
    return b" retire" in subprocess.run(["strings", engine], capture_output=True).stdout


def test_real_c4_thinned_rollbacks(serve, real, tmp_path):
    """C4 on the real engine (patch 0010): with the table capped at 16, a long run keeps few processes, and edits
    that roll back into the thinned table give the same PDF as a fresh compile of the final text."""
    import pytest
    from conftest import Serve
    if not engine_retires(real["engine"]):
        pytest.skip("engine without patch 0010 (TAUDOT_TEST_ENGINE)")
    text = ART % paras(150)
    env = dict(real["env"], TAUDOT_MAX_SNAPSHOTS="16")
    args = real["args"] + ["--snapshot-ms", "1"]
    s = serve({"main.tex": text}, engine=real["engine"], env=env, args=args)
    peak = 0
    while not any(e["ev"] == "done" for e in s.drain(0.01)):
        peak = max(peak, s.nprocs())
        assert len(s.events) < 5000
    assert peak <= 16 + 8, peak
    for n, para in enumerate([100, 10, 140, 60, 2]):
        pos = text.index(f"Paragraph {para}.")
        s.send(["change", "main.tex", pos, 0, f"Edit {n}. "])
        text = text[:pos] + f"Edit {n}. " + text[pos:]
        d = s.done(timeout=30)
        assert d["code"] == 0
        peak = max(peak, s.nprocs())
    assert peak <= 16 + 8, peak
    got = open(d["path"], "rb").read()
    assert s.close() == 0
    (tmp_path / "fresh").mkdir()
    (tmp_path / "fresh" / "main.tex").write_text(text)
    f = Serve({"driver": s.p.args[0]}, tmp_path / "fresh", tmp_path / "out-fresh", engine=real["engine"],
              env=real["env"], args=real["args"])
    d2 = f.done(timeout=60)
    assert d2["pages"] == d["pages"]
    assert open(d2["path"], "rb").read() == got
    assert f.close() == 0
