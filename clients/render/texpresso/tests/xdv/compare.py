# Typesets every corpus paper with two texpresso-xetex builds and compares the XDVs byte for byte. Our own code (MIT).
#
#   uv run clients/render/texpresso/tests/xdv/compare.py ENGINE_A ENGINE_B WORKDIR [CORPUS_TOML] [CORPUS_DIR]
#
# Each paper is copied twice into WORKDIR (one copy per engine) and typeset standalone twice (the second run reads
# the .aux), with SOURCE_DATE_EPOCH=0. Prints one line per paper: same / DIFFERENT / failed, with sha256 prefixes.
import concurrent.futures as cf
import hashlib
import os
import shutil
import subprocess
import sys
import time
import tomllib
from pathlib import Path


def run(engine, src, dst, main):
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst, symlinks=True)
    env = dict(os.environ, SOURCE_DATE_EPOCH="0")
    t0 = time.monotonic()
    for _ in range(2):
        try:
            subprocess.run([engine, "-tectonic", main], cwd=dst, env=env, capture_output=True, timeout=600)
        except subprocess.TimeoutExpired:
            return None, time.monotonic() - t0
    xdv = dst / (Path(main).stem + ".xdv")
    return (xdv.read_bytes() if xdv.exists() else None), time.monotonic() - t0


def main(a, b, work, toml="clients/render/harness/corpus.toml", corpus="~/code/lab/taudot-ref/corpus"):
    work, corpus = Path(work), Path(corpus).expanduser()
    papers = tomllib.loads(Path(toml).read_text())["paper"]
    jobs = [(pid, p["main"]) for pid, p in papers.items() if (corpus / pid / p.get("main", "")).is_file()]

    def one(job):
        pid, main_ = job
        xa, ta = run(a, corpus / pid, work / "a" / pid, main_)
        xb, tb = run(b, corpus / pid, work / "b" / pid, main_)
        h = lambda x: hashlib.sha256(x).hexdigest()[:12] if x else "-"
        if xa is None or xb is None:
            verdict = "failed" if xa is None and xb is None else "ONE-FAILED"
        else:
            verdict = "same" if xa == xb else "DIFFERENT"
        pages = xa.count(b"\x8b") if xa else 0  # rough: bop bytes
        return f"{pid}\t{verdict}\t{h(xa)}\t{h(xb)}\t{len(xa or b'')}\t{ta:.1f}s\t{tb:.1f}s"

    with cf.ThreadPoolExecutor(4) as ex:
        lines = sorted(ex.map(one, jobs))
    print("paper\tverdict\tsha A\tsha B\tbytes\ttime A\ttime B")
    print("\n".join(lines))
    v = [l.split("\t")[1] for l in lines]
    print(f"# {len(v)} papers: {v.count('same')} same, {v.count('DIFFERENT')} different, "
          f"{v.count('failed')} failed in both, {v.count('ONE-FAILED')} failed in one")


if __name__ == "__main__":
    main(*sys.argv[1:])
