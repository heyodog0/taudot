# /// script
# dependencies = ["numpy"]
# ///
"""Milestones of one probe run (probe.swift's DIR), as JSON on stdout.

  uv run clients/mac/Tests/perf/analyse.py DIR [DIR...]

The window is cut into its panes by the AX splitters (sidebar | editor column | PDF). For each pane:
  first   the first frame where the pane differs from its first captured frame (something drawn)
  done    the first frame after which the pane stays within tolerance of its final look ("visually complete":
          < 2% of its pixels differ by more than 24 levels from the last frame, and stays so)
Times are seconds since the launch. `window` is when CGWindowList first reports the window on screen.
After each scripted action, `reaction` is the first frame where a pane changes after it.
"""
import json
import struct
import sys
from pathlib import Path

import numpy as np


def frames(d: Path):
    b = (d / "frames.bin").read_bytes()
    i, out = 0, []
    while i + 12 <= len(b):
        t, = struct.unpack_from("<d", b, i)
        w, h = struct.unpack_from("<HH", b, i + 8)
        n = w * h
        if i + 12 + n > len(b):
            break
        out.append((t, np.frombuffer(b, np.uint8, n, i + 12).reshape(h, w)))
        i += 12 + n
    return out


def panes(d: Path, w_px: int):
    # ax.json lists each window, then its elements: keep the largest window's (other windows, e.g. Settings, may be open).
    groups, cur = [], None
    for a in json.loads((d / "ax.json").read_text()):
        if a["role"] == "AXWindow":
            cur = [a]
            groups.append(cur)
        elif cur is not None:
            cur.append(a)
    ax = max(groups, key=lambda g: g[0]["w"] * g[0]["h"])
    win = ax[0]
    cuts = sorted(a["x"] - win["x"] for a in ax if a["role"] == "AXSplitter" and a["depth"] == 2)
    top = next((a["y"] - win["y"] for a in ax if a["role"] == "AXSplitGroup"), 32)
    s = w_px / win["w"]
    xs = [0] + [c * s for c in cuts] + [w_px]
    names = ["sidebar", "editor", "pdf"] if len(xs) == 4 else ["editor", "pdf"] if len(xs) == 3 else ["all"]
    return {n: (int(xs[k]) + 2, int(xs[k + 1]) - 2) for k, n in enumerate(names)}, int(top * s) + 2, int(28 * s)


def windows(d: Path):
    on = None
    for l in (d / "windows.tsv").read_text().splitlines():
        t, _id, _pid, alpha, onscreen, _b, *title = l.split("\t")
        if on is None and onscreen == "1" and float(alpha) > 0 and int(_b.split()[2]) >= 400:
            on = float(t)
    return on


def timeline(d: Path):
    """The app's own milestones (TAUDOT_TIMELINE, in launch.sh's runN.log), in seconds since the process started:
    the first time each appears. They cover what the capture can't see: its stream starts ~140 ms after the window."""
    log = d.parent / (d.name + ".log")
    keys = {"main": "main", "presented": "presented", "engine online": "engine_online",
            "first nvim flush": "nvim_flush", "pdf: the last PDF": "pdf_cached", "page in view": "pdf_page_in_view",
            "typeset in": "pdf_typeset", "review attached": "review_attached"}
    out = {}
    if not log.exists():
        return out
    for l in log.read_text(errors="replace").splitlines():
        f = l.split(None, 2)
        if len(f) < 3 or f[0] != "timeline":
            continue
        for k, name in keys.items():
            if name not in out and k in f[2]:
                out[name] = float(f[1]) / 1000
    return out


def analyse(d: Path):
    d = Path(str(d).rstrip("/"))
    fs = frames(d)
    if not fs:
        return {"dir": str(d), "error": "no frames", "timeline": timeline(d)}
    h, w = fs[-1][1].shape
    fs = [f for f in fs if f[1].shape == (h, w)]
    ps, top, bottom = panes(d, w)
    res = {"dir": d.name, "window": windows(d), "capture_from": fs[0][0], "frames": len(fs), "timeline": timeline(d)}
    for name, (x0, x1) in ps.items():
        crop = lambda a: a[top:h - bottom, x0:x1].astype(np.int16)
        last, first = crop(fs[-1][1]), crop(fs[0][1])
        tf, td = None, None
        for t, a in fs:
            c = crop(a)
            if tf is None and (np.abs(c - first) > 24).mean() > 0.005:
                tf = t
            if (np.abs(c - last) > 24).mean() < 0.02:
                if td is None:
                    td = t
            else:
                td = None
        res[name] = {"first": tf, "done": td, "first_is_capture_start": tf is None}
    acts = d / "actions.tsv"
    if acts.exists():
        reactions = []
        for l in acts.read_text().splitlines():
            t, what = l.split("\t", 1)
            t = float(t)
            prev = None
            for ft, a in fs:
                if ft < t:
                    prev = a
                    continue
                if prev is not None and (np.abs(a.astype(np.int16) - prev) > 6).any():
                    changed = [n for n, (x0, x1) in ps.items() if (np.abs(a[:, x0:x1].astype(np.int16) - prev[:, x0:x1]) > 6).any()]
                    reactions.append({"t": t, "what": what, "reaction": ft - t, "panes": changed})
                    break
            else:
                reactions.append({"t": t, "what": what, "reaction": None})
            # Per pane: the first change of each pane within 2 s (a keystroke's glyph in the editor, the PDF update).
            per, prev = {}, None
            for ft, a in fs:
                if ft < t:
                    prev = a
                    continue
                if ft > t + 2 or prev is None:
                    break
                for n, (x0, x1) in ps.items():
                    if n not in per and (np.abs(a[top:h - bottom, x0:x1].astype(np.int16) - prev[top:h - bottom, x0:x1]) > 6).any():
                        per[n] = ft - t
                prev = a
            reactions[-1]["per_pane"] = per
        res["actions"] = reactions
    return res


if __name__ == "__main__":
    for a in sys.argv[1:]:
        print(json.dumps(analyse(Path(a))))
