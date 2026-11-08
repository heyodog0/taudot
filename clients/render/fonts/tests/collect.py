# Collects the reference for the font loader: every page of the given corpus papers through a txp-render whose
# dlist.c also dumps each font's bytes (TAUDOT_FONT_DUMP; a scratch build, never shipped), so the test can load
# exactly the fonts MuPDF loaded and compare with the FONT records MuPDF wrote. Our own code (MIT).
#
#   uv run clients/render/fonts/tests/collect.py TXP_RENDER OUTDIR PAPER...
import json
import os
import select
import shutil
import subprocess
import sys
import time
import tomllib
from pathlib import Path

CORPUS = Path.home() / "code/lab/taudot-ref/corpus"


def main_file(pid):
    try:
        return tomllib.loads(Path("clients/render/harness/corpus.toml").read_text())["paper"][pid]["main"]
    except KeyError:
        return "main.tex"


def run(txp, out, pid):
    d = out / "src" / pid
    if d.exists():
        shutil.rmtree(d)
    shutil.copytree(CORPUS / pid, d, ignore=shutil.ignore_patterns(".fetched", ".local"))
    p = subprocess.Popen([txp, "-tectonic", str(d / main_file(pid))], cwd=d, stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1,
                         env=dict(os.environ, TAUDOT_FONT_DUMP=str(out / "fonts")))
    p.stdin.write('["goal",-1]\n')
    n, quiet = 0, None
    while True:  # until "done", then 3 s without events
        r, _, _ = select.select([p.stdout], [], [], 1.0)
        if r:
            e = json.loads(p.stdout.readline())
            if e.get("ev") == "pages" and e.get("done"):
                n, quiet = e["n"], time.monotonic()
        elif quiet and time.monotonic() - quiet > 3:
            break
    ok = 0
    for i in range(n):
        p.stdin.write(json.dumps(["dlist", i, i, str(out / "tdl" / f"{pid}-p{i}.tdl")]) + "\n")
        while True:
            e = json.loads(p.stdout.readline())
            if e.get("id") == i:
                ok += bool(e.get("ok"))
                break
    p.kill()
    p.wait()
    print(f"{pid}: {n} pages, {ok} lists")


if __name__ == "__main__":
    txp, out = sys.argv[1], Path(sys.argv[2])
    (out / "fonts").mkdir(parents=True, exist_ok=True)
    (out / "tdl").mkdir(parents=True, exist_ok=True)
    for pid in sys.argv[3:]:
        run(txp, out, pid)
