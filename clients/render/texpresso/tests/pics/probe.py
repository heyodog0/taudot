# Picture probe: what texpresso-xetex answers for every figure, as golden values. Our own code (MIT).
#
#   uv run --with pikepdf==9.11.0 clients/render/texpresso/tests/pics/probe.py ENGINE WORKDIR OUT.tsv NAME=DIR...
#
# Collects every .pdf/.png/.jpg/.jpeg/.bmp/.eps under each DIR (sorted, labelled NAME:relative/path), copies them to
# WORKDIR/f/NNNN.ext, and typesets one document that asks the engine about each:
#   pic           \XeTeXpicfile "f"                      (every file)
#   pdf P B       \XeTeXpdffile "f" [page P] [B]         (every file with no options; PDFs also every page variant
#                                                         and box below)
#   count         \XeTeXpdfpagecount "f"                 (every file)
# Each record gets the box's wd/ht/dp in sp (exact) and the `pdf:image` special that the picture wrote into the
# XDV (its matrix, page and box, as XeTeX prints them), or "-" when the engine refused the file. The header
# carries the XDV's sha256, so a second engine can be checked byte for byte.
import hashlib
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

import pikepdf

EXTS = {".pdf", ".png", ".jpg", ".jpeg", ".bmp", ".eps"}
BOXES = [None, "crop", "media", "bleed", "trim", "art"]


def page_variants(path):
    try:
        with pikepdf.open(path) as p:
            n = len(p.pages)
    except Exception:
        n = 1
    pages = [None, 0, 1, 2, n, n + 1, -1, -(n + 3)]
    seen, out = set(), []
    for p in pages:
        if p not in seen:
            seen.add(p)
            out.append(p)
    return out


def main(engine, work, out, *sources):
    work = Path(work)
    if work.exists():
        shutil.rmtree(work)
    (work / "f").mkdir(parents=True)
    files = []
    for src in sources:
        name, d = src.split("=", 1)
        d = Path(d).expanduser()
        for p in sorted(d.rglob("*")):
            if p.is_file() and p.suffix.lower() in EXTS:
                files.append((f"{name}:{p.relative_to(d)}", p))

    calls = []  # (label, sha, call text, tex)
    for i, (label, p) in enumerate(files):
        f = f"f/{i:04d}{p.suffix.lower()}"
        shutil.copyfile(p, work / f)
        sha = hashlib.sha256(p.read_bytes()).hexdigest()[:16]
        calls.append((label, sha, "pic", f'\\XeTeXpicfile "{f}"'))
        if p.suffix.lower() == ".pdf":
            for pg in page_variants(p):
                for b in BOXES:
                    opt = (f" page {pg}" if pg is not None else "") + (f" {b}" if b else "")
                    calls.append((label, sha, f"pdf {'-' if pg is None else pg} {b or '-'}",
                                  f'\\XeTeXpdffile "{f}"{opt}'))
        else:
            calls.append((label, sha, "pdf - -", f'\\XeTeXpdffile "{f}"'))
        calls.append((label, sha, "count", f'"{f}"'))

    tex = [r"\batchmode", r"\documentclass{article}", r"\newwrite\po\immediate\openout\po=probe.out",
           r"\newcount\pc", r"\pagestyle{empty}\parindent0pt", r"\begin{document}"]
    for k, (_, _, call, t) in enumerate(calls):
        if call == "count":
            tex.append(f"\\pc=\\XeTeXpdfpagecount {t}\\relax\\immediate\\write\\po{{{k} \\the\\pc}}\\par")
        else:
            tex.append(f"\\setbox0\\hbox{{\\special{{probe:{k}}}{t}\\relax}}"
                       f"\\immediate\\write\\po{{{k} \\number\\wd0,\\number\\ht0,\\number\\dp0}}"
                       f"\\noindent\\box0\\par")
    tex += [r"\immediate\closeout\po", r"\end{document}"]
    (work / "probe.tex").write_text("\n".join(tex) + "\n")

    t0 = time.monotonic()
    r = subprocess.run([engine, "-tectonic", "probe.tex"], cwd=work, env=dict(os.environ, SOURCE_DATE_EPOCH="0"), capture_output=True, text=True)
    secs = time.monotonic() - t0
    xdv = (work / "probe.xdv").read_bytes()
    log = (work / "probe.log").read_text(errors="replace")

    vals = {}
    for line in (work / "probe.out").read_text().splitlines():
        k, _, v = line.partition(" ")
        vals[int(k)] = v.replace(",", " ")
    specials = {}
    for m in re.finditer(rb"probe:(\d+)|pdf:image ([^(]*)\(", xdv):
        if m.group(1):
            cur = int(m.group(1))
        else:
            specials[cur] = m.group(2).decode().strip()

    lines = [f"# engine {engine} exit {r.returncode} in {secs:.1f}s; {len(files)} files, {len(calls)} calls",
             f"# xdv sha256 {hashlib.sha256(xdv).hexdigest()} ({len(xdv)} bytes)",
             f"# 'Unable to load picture' errors in the log: {log.count('Unable to load picture')}",
             "# label\tsha256[:16]\tcall\tresult (sp wd ht dp, or page count)\tpdf:image special"]
    for k, (label, sha, call, _) in enumerate(calls):
        sp = specials.get(k, "-") if call != "count" else ""
        lines.append(f"{label}\t{sha}\t{call}\t{vals.get(k, 'MISSING')}\t{sp}")
    Path(out).write_text("\n".join(lines) + "\n")
    print("\n".join(lines[:3]))


if __name__ == "__main__":
    main(*sys.argv[1:])
