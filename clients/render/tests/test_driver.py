"""driver.c's state (docs/state-machines.md C8-C11) through txp-render's protocol."""

BIBDOC = r"""\documentclass{article}
\begin{document}
See \cite{knuth}.
\bibliographystyle{plain}
\bibliography{%s}
\end{document}
"""
BIB = "@book{knuth, title={%s}, author={D. Knuth}, year=1984, publisher={AW}}\n"


def test_c8_bib_named_with_extension(txp):
    """C8: `\\bibliography{refs.bib}`: a saved .bib reruns BibTeX (the signature stats refs.bib, not refs.bib.bib)."""
    t = txp({"main.tex": BIBDOC % "refs.bib", "refs.bib": BIB % "Old"})
    t.expect(lambda e: e.get("ev") == "bib", what="first bib")
    t.done()
    (t.dir / "refs.bib").write_text(BIB % "A New Title")
    t.send(["rescan"])
    b = t.expect(lambda e: e.get("ev") == "bib", timeout=20, what="bib after the .bib changed")
    assert b["ok"]


def test_c9_failed_bibtex_not_retried_for_same_input(txp):
    """C9: BibTeX failing (a style that doesn't exist) runs once for that input, not again after every run."""
    t = txp({"main.tex": (BIBDOC % "refs").replace("{plain}", "{nosuchstyle}"), "refs.bib": BIB % "T"})
    b = t.expect(lambda e: e.get("ev") == "bib", what="first bib")
    assert not b["ok"]
    t.done()
    got = t.drain(12)  # aux reruns come after 2 s idle each
    assert [e for e in got if e.get("ev") == "bib"] == []
    # a new input (the .bib saved) runs it again
    (t.dir / "refs.bib").write_text(BIB % "Changed")
    t.send(["rescan"])
    t.expect(lambda e: e.get("ev") == "bib", timeout=20, what="bib after a change")


def glyph_text(t, pages, tmp):
    import json
    text = ""
    for p in range(pages):
        path = str(tmp / f"g{p}.json")
        t.send(["glyphs", 900 + p, p, path])
        t.expect(lambda e: e.get("id") == 900 + p, what=f"glyphs {p}")
        text += "".join(g["t"] for g in json.load(open(path))["glyphs"])
    return text


def filler(n):
    return "\n\n".join(f"Paragraph {i}. " + "Words to fill out a line of text here. " * 8 for i in range(n))


def test_c10_more_than_4096_held_edits(txp, tmp_path):
    """C10: edits held while the goal page is typeset are all applied, even past 4096 (a big replace-all)."""
    head = "\\documentclass{article}\n\\begin{document}\n"
    text = head + filler(150) + "\n\\end{document}\n"
    t = txp({"main.tex": text})
    t.send(["goal", 20], ["open", "main.tex", text])
    t.done()
    n = 6000
    t.send(*[["change", "main.tex", len(head), 0, "Q "] for _ in range(n)])
    d = t.expect(lambda e: e.get("ev") == "pages" and e.get("done") and e.get("applied", 0) >= n, timeout=60,
                 what="done with every edit")
    text = glyph_text(t, d["n"], tmp_path)
    assert text.count("Q") == n


def test_c11_bbl_goes_in_while_typing(txp):
    """C11: a .bbl that BibTeX finished while edits are held goes in with them, not only once typing stops. Runs
    here take longer than the gap between keys, so some edit is always held when one ends."""
    import time
    bib = BIB % "Knuth Book" + "@book{lamport, title={Lamport Book}, author={L. Lamport}, year=1994, publisher={AW}}\n"
    head = "\\documentclass{article}\n\\begin{document}\nSee \\cite{knuth}.\n"
    tail = "\n\\bibliographystyle{plain}\n\\bibliography{refs}\n\\end{document}\n"
    text = head + filler(700) + tail
    t = txp({"main.tex": text, "refs.bib": bib})
    t.send(["goal", 400], ["open", "main.tex", text])
    t.expect(lambda e: e.get("ev") == "bib", what="first bib")
    t.drain(5)
    at = len("\\documentclass{article}\n\\begin{document}\nSee ")
    t.send(["change", "main.tex", at, 0, "\\cite{lamport} "])
    pos = len(head) + 20
    got_bib, refs_changed, k = None, False, 0
    end = time.monotonic() + 20
    while time.monotonic() < end and not (got_bib and time.monotonic() - got_bib > 6):
        # length-neutral typing: a key, then its deletion
        t.send(["change", "main.tex", pos, 0, "x"] if k % 2 == 0 else ["change", "main.tex", pos, 1, ""])
        k += 1
        for e in t.drain(0.1):
            if e.get("ev") == "bib" and got_bib is None:
                got_bib = time.monotonic()
            if got_bib and e.get("ev") == "pages" and e["n"] - 1 in e.get("changed", []):
                refs_changed = True
    assert got_bib, "BibTeX didn't run for the new citation"
    assert refs_changed, "the references page didn't change while typing went on"


def glyph_text_page(t, p, tmp):
    import json
    path = str(tmp / f"p{p}.json")
    t.send(["glyphs", 800 + p, p, path])
    t.expect(lambda e: e.get("id") == 800 + p, what=f"glyphs {p}")
    return "".join(g["t"] for g in json.load(open(path))["glyphs"])


def test_c15_rerun_once_with_nothing_to_rerun_is_forgotten(txp):
    """C15: ["rerun-once"] when the aux is settled does nothing, and isn't kept to fire later in the middle of typing
    (an aux rerun waits for 2 s without edits)."""
    import time
    head = "\\documentclass{article}\n\\begin{document}\n"
    text = head + "\\section{A}\\label{a} See \\ref{a}.\n\\end{document}\n"
    t = txp({"main.tex": text}, trace=True)
    t.send(["open", "main.tex", text])
    t.done()
    t.drain(5)  # converged
    t.send(["rerun-once"])
    t.drain(1)
    n0 = sum("rerun pass" in l for l in t.err)
    # typing that changes the aux: a new label, then keys every 0.3 s
    t.send(["change", "main.tex", len(head), 0, "\\section{B}\\label{b}"])
    for _ in range(4):
        time.sleep(0.3)
        t.send(["change", "main.tex", len(head), 0, " "])
    assert sum("rerun pass" in l for l in t.err) == n0, "a rerun started while typing"


def test_c17_bibtex_temp_dirs_removed(txp, tmp_path):
    """C17: BibTeX's temp folders are removed, after a run and when the driver quits mid-run."""
    import os
    tmpdir = tmp_path / "tmp"
    tmpdir.mkdir()
    t = txp({"main.tex": BIBDOC % "refs", "refs.bib": BIB % "T"}, env={"TMPDIR": str(tmpdir)})
    t.expect(lambda e: e.get("ev") == "bib", what="bib")
    t.done()
    left = [p for p in os.listdir(tmpdir) if p.startswith("txs-bib-")]
    assert left == [], [os.listdir(tmpdir / p) for p in left]


def test_c17_no_engine_process_left_after_quit(txp):
    """C17: when the driver quits (stdin closed), no TeX process or snapshot it made is left."""
    import subprocess, time
    t = txp({"main.tex": "\\documentclass{article}\\begin{document}" + "Hello. " * 3000 + "\\end{document}\n"})
    t.done()
    pg = t.p.pid
    t.p.stdin.close()
    t.p.wait(timeout=10)
    time.sleep(0.5)
    out = subprocess.run(["ps", "-A", "-o", "pid=,pgid=,command="], capture_output=True, text=True).stdout
    left = [l for l in out.splitlines() if l.split()[1] == str(pg)]
    assert left == []
