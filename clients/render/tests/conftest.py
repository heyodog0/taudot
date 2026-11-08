"""Harness for txp-render's driver (driver.c, the TeXpresso path): JSON commands in, events out.

    uv run --no-project --with pytest pytest clients/render/tests

Needs a built txp-render (clients/render/build.sh), tectonic on PATH and TeXpresso's texpresso-xetex.
"""
import json
import os
import queue
import shutil
import subprocess
import threading
import time

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.environ.get("TXP_RENDER", os.path.join(os.path.dirname(HERE), "txp-render"))
XETEX = os.environ.get("TEXPRESSO_XETEX", os.path.expanduser("~/code/lab/taudot-ref/texpresso/build/texpresso-xetex"))


class Txp:
    def __init__(self, main, env=None, trace=False):
        e = dict(os.environ, TEXPRESSO_XETEX=XETEX)
        e.update(env or {})
        self.p = subprocess.Popen([BIN, "-tectonic", *(["-trace"] if trace else []), str(main)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, env=e, start_new_session=True)
        self.q, self.err = queue.Queue(), []
        self.events = []
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._read_err, daemon=True).start()

    def _read(self):
        for line in self.p.stdout:
            try:
                self.q.put(json.loads(line))
            except ValueError:
                pass
        self.q.put(None)

    def _read_err(self):
        for line in self.p.stderr:
            self.err.append(line.decode(errors="replace"))

    def send(self, *cmds):
        self.p.stdin.write("".join(json.dumps(c) + "\n" for c in cmds).encode())
        self.p.stdin.flush()

    def expect(self, pred, timeout=30.0, what=""):
        end = time.monotonic() + timeout
        while True:
            left = end - time.monotonic()
            if left <= 0:
                raise AssertionError(f"timed out waiting for {what}; events: {self.events[-8:]}")
            try:
                ev = self.q.get(timeout=left)
            except queue.Empty:
                continue
            if ev is None:
                raise AssertionError(f"txp-render exited waiting for {what}; stderr: {''.join(self.err)[-2000:]}")
            self.events.append(ev)
            if pred(ev):
                return ev

    def drain(self, secs):
        got, end = [], time.monotonic() + secs
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

    def done(self, timeout=60.0):
        return self.expect(lambda e: e.get("ev") == "pages" and e.get("done"), timeout, "done")

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=10)
        finally:
            try:
                os.killpg(self.p.pid, 9)
            except OSError:
                pass


@pytest.fixture
def txp(tmp_path):
    if not os.access(BIN, os.X_OK) or not shutil.which("tectonic") or not os.path.exists(XETEX):
        pytest.skip("no txp-render, tectonic or texpresso-xetex")
    made = []

    def start(files, env=None, trace=False):
        d = tmp_path / f"doc{len(made)}"
        d.mkdir()
        for rel, text in files.items():
            (d / rel).write_text(text)
        t = Txp(d / "main.tex", env, trace)
        t.dir = d
        made.append(t)
        return t

    yield start
    for t in made:
        t.close()
