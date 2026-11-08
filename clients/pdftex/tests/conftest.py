"""Harness for the driver's tests: builds pdftex-live, runs it in --serve mode on the fake engine (or the real one).

    uv run --no-project --with pytest pytest clients/pdftex/tests
"""
import json
import os
import queue
import subprocess
import sys
import threading
import time

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.dirname(HERE)


@pytest.fixture(scope="session")
def build(tmp_path_factory):
    d = tmp_path_factory.mktemp("build")
    exe = d / "pdftex-live"
    subprocess.run(["cc", "-O2", "-Wall", "-o", str(exe), os.environ.get("DRIVER_SRC", os.path.join(SRC, "live.c"))],
                   check=True)  # DRIVER_SRC: an older live.c, to see a test fail before its fix
    eng = d / "fake-engine"
    eng.write_text(f'#!/bin/sh\nexec "{sys.executable}" -I "{HERE}/fake_engine.py" "$@"\n')
    eng.chmod(0o755)
    return {"driver": str(exe), "fake": str(eng), "dir": d}


class Serve:
    """One `pdftex-live --serve` process: commands in, events out."""

    def __init__(self, build, proj, out, main="main.tex", engine=None, args=(), env=None):
        e = dict(os.environ)
        e.update({"FAKE_LINE_MS": "1"})
        e.update(env or {})
        self.out = str(out)
        cmd = [build["driver"], "--serve", "--engine", engine or build["fake"], *args, str(proj), main, str(out)]
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=e,
                                  start_new_session=True)  # its own process group: nprocs() counts the engine's
        self.q = queue.Queue()
        self.events = []
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.p.stdout:
            try:
                self.q.put(json.loads(line))
            except ValueError:
                self.q.put({"ev": "garbage", "line": line.decode(errors="replace")})
        self.q.put(None)

    def send(self, *cmds):
        data = "".join(json.dumps(c) + "\n" for c in cmds).encode()
        self.p.stdin.write(data)
        self.p.stdin.flush()

    def expect(self, pred, timeout=10.0, what=""):
        """The first event (from now on) that matches pred; fails on timeout or exit."""
        end = time.monotonic() + timeout
        while True:
            left = end - time.monotonic()
            if left <= 0:
                raise AssertionError(f"timed out waiting for {what or pred}; events: {self.events[-12:]}")
            try:
                ev = self.q.get(timeout=left)
            except queue.Empty:
                continue
            if ev is None:
                raise AssertionError(f"driver exited ({self.p.wait()}) waiting for {what}; events: {self.events[-12:]}"
                                     f"\nstderr: {self.p.stderr.read().decode(errors='replace')[-2000:]}")
            self.events.append(ev)
            if ev.get("ev") == "error" and ev.get("what") != "protocol" and not getattr(self, "allow_errors", False):
                raise AssertionError(f"error event {ev}; events: {self.events[-12:]}")
            if pred(ev):
                return ev

    def done(self, seq=None, timeout=10.0):
        return self.expect(lambda e: e["ev"] == "done" and (seq is None or e["seq"] == seq), timeout, f"done {seq}")

    def drain(self, secs):
        """Events in the next `secs` seconds."""
        got = []
        end = time.monotonic() + secs
        while (left := end - time.monotonic()) > 0:
            try:
                ev = self.q.get(timeout=left)
            except queue.Empty:
                break
            if ev is None:
                break
            self.events.append(ev)
            got.append(ev)
        return got

    def close(self, timeout=10):
        try:
            self.p.stdin.close()
        except OSError:
            pass
        try:
            return self.p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.p.kill()
            raise

    def alive(self):
        return self.p.poll() is None

    def nprocs(self):
        """Processes in the driver's group: the driver and every engine process (snapshots, runner, finishers)."""
        out = subprocess.run(["ps", "-A", "-o", "pgid="], capture_output=True, text=True).stdout.split()
        return sum(1 for g in out if g == str(self.p.pid))


@pytest.fixture
def serve(build, tmp_path):
    made = []

    def start(files, main="main.tex", **kw):
        proj = tmp_path / f"proj{len(made)}"
        out = tmp_path / f"out{len(made)}"
        proj.mkdir()
        for rel, text in files.items():
            (proj / rel).parent.mkdir(parents=True, exist_ok=True)
            (proj / rel).write_bytes(text.encode() if isinstance(text, str) else text)
        s = Serve(build, proj, out, main=main, **kw)
        s.proj = proj
        made.append(s)
        return s

    yield start
    for s in made:
        try:
            if s.alive():
                s.close()
        finally:  # the group we made: nothing a test started outlives it (a hung tool, an orphaned engine)
            try:
                os.killpg(s.p.pid, 9)
            except OSError:
                pass


REF = os.environ.get("TAUDOT_REF", os.path.expanduser("~/code/lab/taudot-ref"))
IMAGES = {"2026": "2026.1@r79468", "2025": "2025.1@r74524", "2024": "2024.1@r70643"}


@pytest.fixture
def real():
    """Arguments for Serve on the real live engine (pdftex agent's build), as LiveTexPaths sets them up."""
    year = os.environ.get("TAUDOT_TEST_YEAR", "2026")
    b = f"{REF}/pdftex-build-{year}"
    root = f"{REF}/texlive-{year}/store-root"
    engine = os.environ.get("TAUDOT_TEST_ENGINE", f"{b}/live/texk/web2c/pdflatex")  # e.g. a build with a new patch
    if not os.path.exists(engine) or not os.path.exists(f"{root}/texmf-dist/ls-R"):
        pytest.skip(f"no live engine for {year}")
    env = {"TEXMFCNF": f"{root}-cnf:{root}/texmf-dist/web2c", "TEXSTORE_URL": "https://texlive.taudot.app",
           "TEXSTORE_IMAGE": IMAGES[year], "TEXSTORE_ROOT": root, "TEXFORMATS": f".:{b}/fmt-live",
           "SOURCE_DATE_EPOCH": "1700000000", "FORCE_SOURCE_DATE": "1"}  # PDFs comparable byte for byte
    args = []
    if os.path.exists(f"{b}/stock/texk/web2c/bibtex"):
        args = ["--bibtex", f"{b}/stock/texk/web2c/bibtex"]
    return {"engine": engine, "env": env, "args": args}
