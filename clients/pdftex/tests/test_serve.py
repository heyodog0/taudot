"""The --serve driver's state machine against the fake engine (docs/state-machines.md, C items)."""
import os
import time

from conftest import Serve


def doc(n=60):
    return "".join(f"line {i}\n" for i in range(n))


def test_smoke(serve):
    s = serve({"main.tex": doc()}, env={"FAKE_LINE_MS": "2"})
    s.expect(lambda e: e["ev"] == "hello")
    d = s.done(1)
    assert d["pages"] == 15 and d["code"] == 0
    s.send(["change", "main.tex", 0, 0, "x"])
    d = s.done(2)
    assert d["code"] == 0
    assert s.close() == 0


def _double_rollback(serve, pos):
    s = serve({"main.tex": doc()}, env={"FAKE_LINE_MS": "3", "FAKE_R_DELAY_MS": "300"})
    s.done(1)
    s.send(["change", "main.tex", pos, 0, "x"])
    s.expect(lambda e: e["ev"] == "run" and e["seq"] == 2)
    time.sleep(0.05)  # the snapshot hasn't sent R yet
    s.send(["change", "main.tex", pos, 0, "y"])
    s.expect(lambda e: e["ev"] == "run" and e["seq"] == 3)
    d = s.done(3, timeout=10)
    assert d["code"] == 0
    # the same snapshot again: it must still be alive and in the table
    s.send(["change", "main.tex", pos, 0, "z"])
    d = s.done(4, timeout=10)
    assert d["code"] == 0
    assert s.alive()
    assert s.close() == 0


def test_c1_second_rollback_before_R_at_root(serve):
    """C1: a second rollback to snapshot 0 before its R: the driver must not kill the engine root."""
    _double_rollback(serve, 0)


def test_c1_second_rollback_before_R_mid(serve):
    """C1: a second rollback to the same middle snapshot before its R: the driver must not stall."""
    _double_rollback(serve, len(doc(30)))


def test_c2_command_over_1mb(serve):
    """C2: one command line over the 1 MB input buffer (opening a big .bib) must not read as EOF."""
    s = serve({"main.tex": doc(), "refs.bib": "@misc{a,}\n"})
    s.done(1)
    big = "".join(f"@misc{{k{i}, title={{{'x' * 60}}}}}\n" for i in range(25000))
    assert len(big) > 1.5e6
    s.send(["open", "refs.bib", big])
    s.send(["change", "main.tex", 0, 0, "x"])
    s.done(2, timeout=10)
    assert open(os.path.join(s.out, "work", "refs.bib")).read() == big
    assert s.alive()
    assert s.close() == 0


BIBDOC = "\\aux{\\bibdata{refs}}\n\\aux{\\citation{a}}\n" + doc(20) + "\\input{main.bbl}\n" + doc(8)


def fake_bibtex(build):
    b = build["dir"] / "fake-bibtex"
    b.write_text('#!/bin/sh\ncp refs.bib "$1.bbl" && echo "fake bibtex" > "$1.blg"\n')
    b.chmod(0o755)
    return str(b)


def test_c3_reopen_with_changed_bib(serve, build, tmp_path):
    """C3: a .bib changed between two sessions on the same --state reruns BibTeX on reopen."""
    state = tmp_path / "state"
    args = ["--bibtex", fake_bibtex(build), "--state", str(state)]
    s = serve({"main.tex": BIBDOC, "refs.bib": "old entries\n"}, args=args)
    s.done(1)
    assert open(os.path.join(s.out, "work", "main.bbl")).read() == "old entries\n"
    assert s.close() == 0
    (s.proj / "refs.bib").write_text("new entries\n")
    s2 = Serve(build, s.proj, tmp_path / "out-reopen", args=args)  # a new session, same project and state
    d = s2.done(1)
    assert open(os.path.join(s2.out, "work", "main.bbl")).read() == "new entries\n"
    assert s2.close() == 0


def test_c3_state_saved_when_driver_killed(serve, build, tmp_path):
    """C3: the state is saved when a compile settles, not only on a clean EOF."""
    state = tmp_path / "state"
    s = serve({"main.tex": BIBDOC, "refs.bib": "entries\n"}, args=["--bibtex", fake_bibtex(build), "--state", str(state)])
    s.done(1)
    s.drain(0.2)
    s.p.kill()
    s.p.wait()
    assert (state / "main.bbl").read_text() == "entries\n"
    assert (state / "main.aux").exists()




def test_c4_snapshot_table_thinned(serve, tmp_path):
    """C4: a long run keeps a bounded number of snapshots (live processes), and rollbacks into the thinned table work."""
    text = doc(200)
    log = tmp_path / "engine.log"
    s = serve({"main.tex": text}, args=["--snapshot-ms", "1"],
              env={"FAKE_LINE_MS": "3", "TAUDOT_MAX_SNAPSHOTS": "16", "FAKE_LOG": str(log)})
    peak = 0
    while True:
        peak = max(peak, s.nprocs())
        got = s.drain(0.02)
        if any(e["ev"] == "done" for e in got):
            break
        assert len(s.events) < 1000
    assert peak <= 16 + 6, peak
    for n, pos in enumerate([len(doc(100)), len(doc(10)), len(doc(190)), 0, len(doc(150))]):
        s.send(["change", "main.tex", pos, 0, f"edit{n} "])
        text = text[:pos] + f"edit{n} " + text[pos:]
        d = s.done(2 + n, timeout=20)
        assert d["code"] == 0
        with open(d["path"], "rb") as f:
            assert text.encode() in f.read(), f"edit {n} not in the PDF"
        assert s.nprocs() <= 16 + 6
    assert s.close() == 0
    events = log.read_text()
    assert " childless" in events and " woken" in events  # rollbacks reached snapshots whose child was retired



def test_p1_done_without_pdf(serve):
    """P1 (driver side): a run that writes no PDF announces no PDF; `done` names its log and no path."""
    s = serve({"main.tex": "line\n\\fatal\n" + doc(10)})
    d = s.done(1)
    pdfs = [e for e in s.events if e["ev"] == "pdf"]
    assert all(os.path.exists(e["path"]) for e in pdfs), pdfs
    assert "path" not in d and d["code"] == 1
    assert "Emergency stop" in open(d["log"]).read()
    # fixed: a PDF again, and done names it with its log
    s.send(["change", "main.tex", 5, len("\\fatal\n"), ""])
    d = s.done(2)
    assert os.path.exists(d["path"]) and d["code"] == 0
    assert "Emergency stop" not in open(d["log"]).read()
    # broken again after a good PDF: done must not name the old PDF
    s.send(["change", "main.tex", 5, 0, "\\fatal\n"])
    d = s.done(3)
    assert "path" not in d and "Emergency stop" in open(d["log"]).read()
    assert s.close() == 0


def test_c4_old_engine_not_thinned(serve):
    """C4: an engine without patch 0010 (no `V ... retire`) would take a retired child as a crash: never thinned."""
    s = serve({"main.tex": doc(60)}, args=["--snapshot-ms", "1"],
              env={"FAKE_LINE_MS": "2", "TAUDOT_MAX_SNAPSHOTS": "8", "FAKE_NO_RETIRE": "1"})
    s.done(1)
    assert s.nprocs() > 20
    s.send(["change", "main.tex", len(doc(30)), 0, "x"])
    assert s.done(2)["code"] == 0
    assert s.close() == 0


def test_c5_engine_crash_restarts(serve):
    """C5: a crashed engine (every engine process gone) doesn't end the driver: the compile settles with an error,
    and the next edit typesets on a new engine."""
    text = doc(20) + "\\crash\n" + doc(20)
    s = serve({"main.tex": text})
    s.allow_errors = True
    d = s.done(1)
    assert "path" not in d
    assert any(e["ev"] == "error" and e["what"] == "engine" for e in s.events)
    pos = text.index("\\crash")
    s.send(["change", "main.tex", pos, len("\\crash\n"), ""])
    d = s.done(timeout=10)
    assert d["code"] == 0 and os.path.exists(d["path"])
    s.send(["change", "main.tex", len(doc(30)), 0, "x"])  # and rollbacks work on the new engine
    d2 = s.done(d["seq"] + 1, timeout=10)
    assert d2["code"] == 0
    assert s.close() == 0


def tool(build, name, body):
    b = build["dir"] / name
    b.write_text("#!/bin/sh\n" + body)
    b.chmod(0o755)
    return str(b)


def test_c6_hung_bibtex_times_out(serve, build):
    """C6: a BibTeX that never ends doesn't freeze the driver: it is killed after the timeout and the compile
    settles; the driver reads commands again."""
    bt = tool(build, "hung-bibtex", "sleep 1000\n")
    s = serve({"main.tex": BIBDOC, "refs.bib": "x\n"}, args=["--bibtex", bt], env={"TAUDOT_TOOL_TIMEOUT_S": "1"})
    s.allow_errors = True
    t0 = time.monotonic()
    b = s.expect(lambda e: e["ev"] == "bibtex", timeout=10)
    assert b["code"] != 0 and time.monotonic() - t0 < 5
    s.done(1, timeout=5)
    s.send(["change", "main.tex", 0, 0, "x"])
    s.done(2, timeout=5)
    assert s.close() == 0


def test_c6_tools_dont_get_the_command_pipe(serve, build):
    """C6: BibTeX's stdin is /dev/null, not the driver's command pipe."""
    bt = tool(build, "stdin-bibtex", 'stat -L -f %HT /dev/stdin > stdin-type.txt\ncp refs.bib "$1.bbl"\n')
    s = serve({"main.tex": BIBDOC, "refs.bib": "x\n"}, args=["--bibtex", bt])
    s.done(1)
    assert open(os.path.join(s.out, "work", "stdin-type.txt")).read().strip() == "Character Device"
    assert s.close() == 0


def test_c7_finish_before_R_is_kept(serve):
    """C7: a `finish` while the woken snapshot hasn't named its runner reaches the new runner (a partial PDF)."""
    s = serve({"main.tex": doc(200)}, env={"FAKE_LINE_MS": "5", "FAKE_R_DELAY_MS": "200"})
    s.done(1, timeout=20)
    s.send(["change", "main.tex", len(doc(100)), 0, "x"])  # resumes with pages shipped (none: nothing to finish)
    s.expect(lambda e: e["ev"] == "run" and e["seq"] == 2)
    s.send(["finish"])
    p = s.expect(lambda e: e["ev"] == "pdf" and e["seq"] == 2, timeout=10)
    assert p["final"] is False
    s.done(2, timeout=20)
    assert s.close() == 0


def test_c7_goal_before_first_snapshot(serve):
    """C7: a `goal` sent with the first command, before the engine took its first snapshot, is honoured."""
    s = serve({"main.tex": doc(200)}, env={"FAKE_LINE_MS": "5", "FAKE_START_MS": "500"})
    time.sleep(0.25)  # the engine has read ctl and hasn't taken a snapshot
    s.send(["goal", 3])
    p = s.expect(lambda e: e["ev"] == "pdf" and e["seq"] == 1, timeout=10)
    assert p["final"] is False and p["pages"] == 4
    s.done(1, timeout=20)
    assert s.close() == 0


def test_c12_many_changed_files_at_once(serve):
    """C12: more than 64 files changed in one burst (an Overleaf sync, a git checkout) all get typeset."""
    n = 80
    files = {f"ch{i:02d}.tex": f"old {i}\n" for i in range(n)}
    files["main.tex"] = "".join(f"\\input{{ch{i:02d}.tex}}\n" for i in reversed(range(n)))  # ch79 is read first
    s = serve(files)
    s.done(1, timeout=20)
    s.send(*[["open", f"ch{i:02d}.tex", f"new {i}\n"] for i in range(n)])
    d = s.done(2, timeout=20)
    pdf = open(d["path"], "rb").read()
    stale = [i for i in range(n) if f"new {i}\n".encode() not in pdf]
    assert stale == []


def test_c12_more_than_512_open_texts(serve):
    """C12: `open` of more than 512 files: every text is used."""
    n = 530
    files = {f"f{i:03d}.tex": f"old {i}\n" for i in range(n)}
    files["main.tex"] = "".join(f"\\input{{f{i:03d}.tex}}\n" for i in range(n))
    s = serve(files, env={"FAKE_LINE_MS": "0"})
    s.done(1, timeout=30)
    s.send(*[["open", f"f{i:03d}.tex", f"new {i}\n"] for i in range(n)])
    d = s.done(2, timeout=30)
    pdf = open(d["path"], "rb").read()
    assert [i for i in range(n) if f"new {i}\n".encode() not in pdf] == []


def test_c12_more_than_64_written_files(serve):
    """C12: a run that writes more than 64 changed project files (chapter .aux files): all are written back."""
    n = 70
    main = "".join(f"\\input{{c{i:02d}.aux}}\n\\write{{c{i:02d}.aux}}{{seen {i}}}\n" for i in range(n))
    s = serve({"main.tex": main}, env={"FAKE_LINE_MS": "0"})
    d = s.done(1, timeout=30)
    pdf = open(d["path"], "rb").read()
    assert [i for i in range(n) if f"seen {i}\n".encode() not in pdf] == []
    assert d["runs"] == 2


def test_c13_edit_after_a_run_without_snapshots(serve):
    """C13: a first run that took no snapshot: a later edit still compiles (from the top)."""
    s = serve({"main.tex": doc(20)}, env={"FAKE_NO_SNAP": "1"})
    s.done(1)
    s.send(["change", "main.tex", 0, 0, "edited "])
    d = s.done(2, timeout=10)
    assert b"edited line 0" in open(d["path"], "rb").read()
    assert s.close() == 0


def test_c13_edit_during_a_run_without_snapshots(serve):
    """C13: an edit held during a first run that never snapshots is applied when that run ends."""
    s = serve({"main.tex": doc(100)}, env={"FAKE_NO_SNAP": "1", "FAKE_LINE_MS": "5"})
    s.expect(lambda e: e["ev"] == "run")
    time.sleep(0.1)
    s.send(["change", "main.tex", 0, 0, "edited "])
    d = s.expect(lambda e: e["ev"] == "done" and e.get("path") and b"edited line 0" in open(e["path"], "rb").read(),
                 timeout=10, what="a done with the edit")
    assert s.close() == 0


def test_c14_makeindex_step_is_not_bibtex(serve, build):
    """C14: a makeindex run is reported as makeindex, and doesn't announce BibTeX's old .blg as new."""
    mi = tool(build, "fake-makeindex", 'echo "index from $4" > "$3"\n')  # makeindex -o OUT IN
    bt = tool(build, "fake-bibtex2", 'cp refs.bib "$1.bbl" && echo "bibtex log" > "$1.blg"\n')
    main = BIBDOC + "\\write{main.idx}{\\indexentry{a}{1}}\n\\input{main.ind}\n"
    s = serve({"main.tex": main, "refs.bib": "x\n"}, args=["--bibtex", bt, "--makeindex", mi])
    s.done(1)
    first = [e for e in s.events if e["ev"] == "bibtex"]
    # an edit that changes only the index
    pos = main.index("\\indexentry{a}")
    s.send(["change", "main.tex", pos + len("\\indexentry{"), 1, "b"])
    s.done(2)
    steps = [e for e in s.events if e["ev"] == "bibtex" and e["seq"] == 2]
    assert steps and all(e.get("tool") == "makeindex" for e in steps), steps
    assert all("blg" not in e for e in steps), steps
    assert any("bibtex" in e.get("tool", "").split(",") and "blg" in e for e in first), first


def test_c17_unannounced_pdfs_removed(serve):
    """C17: partial PDFs the driver never announces (finished for a run an edit already replaced) don't pile up in
    OUT: at most the ones it keeps for announced events."""
    s = serve({"main.tex": doc(300)}, env={"FAKE_LINE_MS": "2", "FAKE_LINES_PER_PAGE": "2", "FAKE_FINISH_MS": "80"})
    s.done(1, timeout=20)
    for i in range(30):
        s.send(["change", "main.tex", len(doc(150)), 0, "x"])
        s.send(["finish"])
        time.sleep(0.05)
    last = s.expect(lambda e: e["ev"] == "pdf" and e["final"] and e["applied"] == 30, 30, "the final PDF of every edit")
    s.done(last["seq"], timeout=30)  # edits may share a compile (a held key's edits wait for the run in flight)
    s.drain(0.5)
    announced = {e["path"] for e in s.events if e["ev"] == "pdf"}
    on_disk = {os.path.join(s.out, f) for f in os.listdir(s.out) if f.startswith("pdf-") and f.endswith(".pdf")}
    assert on_disk <= announced, sorted(on_disk - announced)[:5]
    assert s.close() == 0


def _held_key(serve, secs=3.0, rate=30):
    """A key held at `rate`/s on page 10 of 15, goal page 11; a run takes ~100 ms from the edit to that page."""
    s = serve({"main.tex": doc()}, env={"FAKE_LINE_MS": "8"})
    s.send(["goal", 11])
    s.done(1, timeout=20)
    pos = len(doc(40))
    t0 = time.monotonic()
    times, n = [], 0
    while time.monotonic() - t0 < secs:
        s.send(["change", "main.tex", pos, 0, "x"])
        n += 1
        time.sleep(max(0.0, 1 / rate - 0.001))
        for e in s.drain(0.001):
            if e["ev"] == "pdf":
                times.append(time.monotonic() - t0)
    for e in s.drain(0.4):
        if e["ev"] == "pdf":
            times.append(time.monotonic() - t0)
    return s, times, n, pos


def test_held_key_still_finishes(serve):
    """Rule 6 vs 3: a held key (an edit every 33 ms) must still give a PDF at least every ~200 ms, not none."""
    s, times, n, pos = _held_key(serve)
    during = [t for t in times if t < 3.0]
    assert len(during) >= 3.0 / 0.2 - 2, f"{len(during)} PDFs in 3 s: {times}"
    gaps = [b - a for a, b in zip([0.0] + during, during)]
    assert max(gaps) < 0.3, f"gap {max(gaps):.3f} s: {times}"
    # nothing lost: the settled PDF has every key
    d = [e for e in s.events if e["ev"] == "done"][-1:] or [s.done(timeout=20)]
    with open(d[-1]["path"], "rb") as f:
        body = f.read()
    assert (b"x" * n + b"line 40") in body, f"{n} keys, PDF: {body[:300]}"
    assert s.close() == 0


def test_slow_typing_is_not_held(serve):
    """Keys slower than a run restart it as before: each PDF has every key so far."""
    s, times, n, pos = _held_key(serve, secs=1.5, rate=4)
    shown = {e["applied"] for e in s.events if e["ev"] == "pdf" and e["seq"] > 1}
    assert shown == set(range(1, n + 1)), f"{n} keys, PDFs of {sorted(shown)}"
    assert s.close() == 0


def _csw(pid):
    import subprocess
    out = subprocess.run(["top", "-l", "1", "-pid", str(pid), "-stats", "pid,csw"], capture_output=True, text=True).stdout
    return int(out.split()[-1].rstrip("+"))


def test_idle_driver_sleeps(serve):
    """At rest (the compile settled, nothing pending) the driver wakes less than once a second (it was 20/s)."""
    s = serve({"main.tex": doc()})
    s.done(1)
    s.drain(0.3)
    a = _csw(s.p.pid)
    s.drain(3.0)
    b = _csw(s.p.pid)
    assert b - a <= 3, f"{b - a} context switches in 3 s"
    assert s.close() == 0


def test_engine_death_at_rest_is_seen(serve):
    """The driver sleeps at rest, but an engine that dies then is still reported at once (SIGCHLD wakes it)."""
    import signal as sg
    s = serve({"main.tex": doc()})
    s.allow_errors = True
    s.done(1)
    s.drain(0.3)
    import subprocess
    kids = subprocess.run(["pgrep", "-P", str(s.p.pid)], capture_output=True, text=True).stdout.split()
    assert kids
    t = time.monotonic()
    for k in kids:
        os.kill(int(k), sg.SIGKILL)
    s.expect(lambda e: e["ev"] == "error" and e["what"] == "engine", 2.0)
    assert time.monotonic() - t < 0.5
    s.send(["change", "main.tex", 0, 0, "x"])  # a new engine
    assert s.done(timeout=10)["code"] == 0
    assert s.close() == 0


def test_edited_page_comes_before_the_goal_page(serve):
    """The goal is the last page in view; an edit on an earlier page gets a PDF once its own page ships, without
    waiting for the goal's (the goal's still comes)."""
    s = serve({"main.tex": doc()}, env={"FAKE_LINE_MS": "3"})
    s.send(["goal", 13])
    s.done(1, timeout=20)
    s.send(["change", "main.tex", len(doc(9)), 0, "x"])  # page 2 (4 lines a page)
    pdfs = []
    s.expect(lambda e: e["ev"] == "pdf" and e["seq"] == 2 and (pdfs.append(e) or e["pages"] > 13), 10, "the goal's PDF")
    assert pdfs[0]["pages"] <= 4, [p["pages"] for p in pdfs]
    assert s.close() == 0
