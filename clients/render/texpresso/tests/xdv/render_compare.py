# Driver-mode check: typesets each corpus paper under two txp-render builds (the app's path: the engine runs with
# -texpresso, its files read over the protocol) and renders every page with MuPDF at the harness's scale, like the
# harness oracle. Compares the pixels page by page. Our own code (MIT).
#
#   uv run clients/render/texpresso/tests/xdv/render_compare.py TXP_A TXP_B WORKDIR [CORPUS_TOML] [CORPUS_DIR]
import concurrent.futures as cf
import hashlib
import json
import math
import shutil
import subprocess
import sys
import time
import tomllib
from pathlib import Path

SCALE = 2.0


def render_all(txp, src, dst, main):
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst, symlinks=True, ignore=shutil.ignore_patterns(".fetched", ".local"))
    p = subprocess.Popen([str(txp), "-tectonic", str(dst / main)], cwd=dst, stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
    p.stdin.write('["goal",-1]\n')
    deadline = time.monotonic() + 600
    sizes = None
    for line in p.stdout:
        ev = json.loads(line)
        if ev.get("ev") == "pages" and ev.get("done"):
            sizes = ev["sizes"]
            break
        if time.monotonic() > deadline:
            break
    hashes = []
    if sizes:
        for i, (w, h) in enumerate(sizes):
            W, H = math.ceil(w * SCALE), math.ceil(h * SCALE)
            out = dst / f"p{i}.rgb"
            p.stdin.write(json.dumps(["render", i, i, SCALE, 0, 0, W, H, str(out), ""]) + "\n")
            while True:
                ev = json.loads(p.stdout.readline())
                if ev.get("id") == i:
                    break
            hashes.append(hashlib.sha256(out.read_bytes()).hexdigest()[:12] if ev.get("ok") else "-")
            out.unlink(missing_ok=True)
    p.stdin.close()
    p.kill()
    p.wait()
    return hashes


def main(a, b, work, toml="clients/render/harness/corpus.toml", corpus="~/code/lab/taudot-ref/corpus"):
    work, corpus = Path(work), Path(corpus).expanduser()
    papers = tomllib.loads(Path(toml).read_text())["paper"]
    jobs = [(pid, p["main"]) for pid, p in papers.items() if (corpus / pid / p.get("main", "")).is_file()]

    def one(job):
        pid, m = job
        ha = render_all(a, corpus / pid, work / "a" / pid, m)
        hb = render_all(b, corpus / pid, work / "b" / pid, m)
        diff = [i for i in range(max(len(ha), len(hb))) if i >= len(ha) or i >= len(hb) or ha[i] != hb[i]]
        verdict = "no pages" if not ha and not hb else ("same" if not diff else f"DIFFERENT pages {diff[:10]}")
        return pid, len(ha), len(hb), verdict

    with cf.ThreadPoolExecutor(3) as ex:
        rows = sorted(ex.map(one, jobs))
    for r in rows:
        print("\t".join(map(str, r)))
    same = sum(1 for r in rows if r[3] == "same")
    pages = sum(r[1] for r in rows if r[3] == "same")
    print(f"# {len(rows)} papers: {same} identical ({pages} pages), "
          f"{sum(1 for r in rows if r[3].startswith('DIFF'))} different, {sum(1 for r in rows if r[3] == 'no pages')} no pages")


if __name__ == "__main__":
    main(*sys.argv[1:])
