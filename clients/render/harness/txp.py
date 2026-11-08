"""The renderer project's shared driver for clients/render/txp-render (the txp-headless protocol plus our verbs).
Owned by the harness agent; ask it for additions, keep the API small.

    from txp import Txp
    with Txp(Path("paper/main.tex"), log=Path("txp.log")) as t:   # starts txp-render in the paper's folder
        ev = t.typeset()              # waits for the finished document, .aux reruns included; the "pages" event
        t.pages["sizes"][i]           # [w, h] in PDF points of page i (from the last "pages" event)
        t.render(i, 2.0, png)         # MuPDF draws page i at 2x (144 dpi) → PNG; returns the answer {w, h, cpu_us}
        t.dlist(i, path)              # ["dlist", id, i, path] → the answer dict (dlist.md)
        t.ask("glyphs", i, path)      # any other verb that takes (id, ...) → the answer with that id
        t.errors                      # "! ..." lines TeX printed
        t.nullfont()                  # "Missing character ... nullfont" lines in the log: text drawn in no font

Raises TxpError when txp-render exits or doesn't answer. Typesetting is done when a finished "pages" report is
followed by SETTLE seconds of quiet, longer for long papers (txp-headless reruns for a dirty .aux after 2 s idle, then
reports again). A rerun can still start later: callers check `t.pages["gen"]` and retry (run.py does)."""

import json
import os
import queue
import subprocess
import threading
import time
from pathlib import Path

import numpy as np
from PIL import Image

RENDER = Path(__file__).resolve().parent.parent
BINARY = RENDER / "txp-render"
SETTLE = 4.0   # s of quiet after a finished report: txp-headless reruns for a dirty .aux after 2 s idle


class TxpError(RuntimeError):
    pass


class Txp:
    """One txp-render process on one paper. Events and answers are JSON lines on its stdout."""

    def __init__(self, main_tex: Path, log: Path | None = None, binary: Path = BINARY):
        self.log = log
        self.err = open(log, "wb") if log else subprocess.DEVNULL
        self.p = subprocess.Popen([str(binary), str(main_tex)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=self.err, cwd=main_tex.parent)
        self.q: queue.Queue = queue.Queue()
        self.errors: list[str] = []
        threading.Thread(target=self._read, daemon=True).start()
        self.pages: dict | None = None
        self.next_id = 1

    def _read(self):
        for line in self.p.stdout:
            try:
                self.q.put(json.loads(line))
            except json.JSONDecodeError:
                pass
        self.q.put(None)

    def _get(self, timeout: float):
        m = self.q.get(timeout=timeout)
        if m is None:
            raise TxpError(f"txp-render exited ({self.p.poll()})")
        if m.get("ev") == "error":
            self.errors.append(m.get("line", ""))
        if m.get("ev") == "pages":
            self.pages = m
        return m

    def typeset(self, timeout: float = 600) -> dict:
        """Wait for the document to finish, including .aux reruns: the last finished "pages" report."""
        t0 = time.monotonic()
        t_end = t0 + timeout
        done, settle = None, SETTLE
        while True:
            left = t_end - time.monotonic()
            if left <= 0:
                raise TxpError("typeset timed out")
            try:
                m = self._get(min(left, settle) if done else left)
            except queue.Empty:
                if done:
                    return done
                continue
            if m.get("ev") == "pages" and m.get("done"):
                # a rerun starts 2 s after the report and takes up to about as long as the first pass (GPT-3: 79 pages
                # at 6 s, then 83 at 9.5 s; slower under load), so wait that long for quiet
                settle = max(SETTLE, 2.5 + 0.75 * (time.monotonic() - t0)) if done is None else settle
                done = m

    def _ask(self, cmd: list, timeout: float = 120) -> dict:
        self.p.stdin.write((json.dumps(cmd) + "\n").encode())
        self.p.stdin.flush()
        t_end = time.monotonic() + timeout
        while True:
            m = self._get(max(0.1, t_end - time.monotonic()))
            if m.get("id") == cmd[1] or ("ev" not in m and "id" not in m):   # stubs may answer without an id
                return m

    def render(self, page: int, scale: float, png: Path) -> dict:
        """The whole page at scale × PDF points, to PNG. {w, h, cpu_us}."""
        w_pt, h_pt = self.pages["sizes"][page]
        w, h = max(1, round(w_pt * scale)), max(1, round(h_pt * scale))
        rgb = png.with_suffix(".rgb")
        m = self.ask("render", page, scale, 0, 0, w, h, rgb, "")
        if not m.get("ok"):
            raise TxpError(f"render page {page}: {m.get('error')}")
        a = np.fromfile(rgb, dtype=np.uint8).reshape(h, w, 3)
        Image.fromarray(a).save(png, optimize=False, compress_level=1)
        rgb.unlink()
        return m

    def ask(self, verb: str, *args, timeout: float = 120) -> dict:
        """[verb, id, *args] → the answer carrying that id."""
        i = self.next_id; self.next_id += 1
        return self._ask([verb, i, *[str(a) if isinstance(a, Path) else a for a in args]], timeout)

    def dlist(self, page: int, path: Path) -> dict:
        return self.ask("dlist", page, path)

    def nullfont(self) -> list[str]:
        """TeX's "Missing character: There is no X in font nullfont!" lines (needs `log`). A font fontspec couldn't
        find leaves TeX in nullfont: the text is silently not drawn and no "! ..." error is raised."""
        if not self.log:
            return []
        self.err.flush()
        text = Path(self.log).read_text(errors="replace")
        return sorted({m.split("!")[0].replace("\\", "").strip(": ") for m in text.split("Missing character")[1:] if "nullfont" in m[:200]})[:20]

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=10)
        except Exception:
            self.p.kill()
        if self.err is not subprocess.DEVNULL:
            self.err.close()

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()
