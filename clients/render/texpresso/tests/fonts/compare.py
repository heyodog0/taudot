# Patch 0005 check: fonts given by name (fontspec) resolve to the files and sizes XeTeX's fontconfig build chooses
# (as on Overleaf). Our own code (MIT).
#
#   uv run clients/render/texpresso/tests/fonts/compare.py ORACLE_ENGINE FONTDIR NEW_ENGINE WORKDIR
#
# ORACLE_ENGINE is texpresso-xetex built without XETEX_MAC (XeTeX's fontconfig font manager), run with a fontconfig
# that sees only FONTDIR (the bundle's fonts of the families below). NEW_ENGINE is the macOS build with the bundle
# font index. For each family, a document sets it with \setmainfont{...} and uses regular, bold, italic and bold
# italic at three sizes. The XDVs must define the same fonts (file name, size, flags, face) in the same order, and be
# identical op for op (font file paths reduced to base names, back-pointers ignored).
import os
import re
import subprocess
import sys
from pathlib import Path

FAMILIES = ["Latin Modern Roman", "TeX Gyre Pagella", "Libertinus Serif", "STIX Two Text"]
DOC = r"""\documentclass{article}
\usepackage{fontspec}
\setmainfont{%s}
\pagestyle{empty}
\begin{document}
Regular \textbf{bold} \textit{italic} \textbf{\textit{bold italic}}

{\footnotesize Small regular \textbf{bold} \textit{italic} \textbf{\textit{bold italic}}\par}

{\Large Large regular \textbf{bold} \textit{italic} \textbf{\textit{bold italic}}\par}
\end{document}
"""


def ops(xdv):
    """The XDV as a list of ops, comparable across font paths: native font definitions (252) keep only the file's base
    name; bop/post/post_post back-pointers are zeroed. Also the font definitions: (size, flags, base name, face)."""
    out, defs, i, n = [], [], 0, len(xdv)
    be = lambda a, b: int.from_bytes(xdv[a:b], "big")
    while i < n:
        o = xdv[i]
        if o <= 127 or o in (138, 140, 141, 142, 147, 152, 161, 166) or 171 <= o <= 234:
            ln = 1
        elif 128 <= o <= 131 or 133 <= o <= 136 or 143 <= o <= 146 or 148 <= o <= 151 or 153 <= o <= 160 \
                or 162 <= o <= 165 or 167 <= o <= 170 or 235 <= o <= 238:
            ln = 1 + (o - {128: 127, 133: 132, 143: 142, 148: 147, 153: 152, 157: 156, 162: 161, 167: 166,
                           235: 234}[max(k for k in (128, 133, 143, 148, 153, 157, 162, 167, 235) if k <= o)])
        elif o in (132, 137):
            ln = 9
        elif o == 139:
            out.append(xdv[i:i + 41])  # c0..c9, without p
            i += 45
            continue
        elif 239 <= o <= 242:
            k = o - 238
            ln = 1 + k + be(i + 1, i + 1 + k)
        elif 243 <= o <= 246:
            k = o - 242
            a, l = xdv[i + 1 + k + 12], xdv[i + 1 + k + 13]
            ln = 1 + k + 14 + a + l
        elif o == 247:
            ln = 15 + xdv[i + 14]
        elif o == 248:
            out.append(xdv[i:i + 1] + xdv[i + 5:i + 29])  # without p
            i += 29
            continue
        elif o == 249:
            out.append(b"post_post")
            break
        elif o == 252:
            flags, l = be(i + 9, i + 11), xdv[i + 11]
            name = xdv[i + 12:i + 12 + l].decode("utf-8", "replace")
            ln = 16 + l + 4 * sum(1 for b in (0x200, 0x1000, 0x2000, 0x4000) if flags & b)
            rec = (be(i + 5, i + 9), flags, os.path.basename(name), be(i + 12 + l, i + 16 + l))
            defs.append(rec)
            out.append(("fontdef", be(i + 1, i + 5)) + rec + (xdv[i + 16 + l:i + ln],))
            i += ln
            continue
        elif o == 253:
            ln = 7 + 10 * be(i + 5, i + 7)
        elif o == 254:
            l = be(i + 1, i + 3)
            ln = 3 + 2 * l + 4 + 2 + 10 * be(i + 3 + 2 * l + 4, i + 3 + 2 * l + 6)
        else:
            raise ValueError(f"unknown opcode {o} at {i}")
        out.append(xdv[i:i + ln])
        i += ln
    return defs, out


def run(engine, d, env):
    subprocess.run([engine, "-tectonic", "main.tex"], cwd=d, env=env, capture_output=True, timeout=600)
    x = d / "main.xdv"
    return x.read_bytes() if x.exists() else None


def main(oracle, fontdir, new, work):
    work = Path(work)
    conf = work / "fonts.conf"
    work.mkdir(parents=True, exist_ok=True)
    conf.write_text(f"""<?xml version="1.0"?><!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig><dir>{Path(fontdir).resolve()}</dir><cachedir>{work.resolve()}/fc-cache</cachedir></fontconfig>
""")
    base = dict(os.environ, SOURCE_DATE_EPOCH="0")
    ok = 0
    for fam in FAMILIES:
        res = {}
        for who, eng, env in (("oracle", oracle, dict(base, FONTCONFIG_FILE=str(conf))), ("new", new, base)):
            d = work / who / fam.replace(" ", "-")
            d.mkdir(parents=True, exist_ok=True)
            for f in d.glob("main.*"):
                f.unlink()
            (d / "main.tex").write_text(DOC % fam)
            res[who] = run(eng, d, env)
        if not res["oracle"] or not res["new"]:
            print(f"{fam}: FAILED to typeset (oracle {bool(res['oracle'])}, new {bool(res['new'])})")
            continue
        (da, ra), (db, rb) = ops(res["oracle"]), ops(res["new"])
        same = da == db and ra == rb
        ok += same
        print(f"{fam}: {'same' if same else 'DIFFERENT'}")
        for size, flags, name, idx in sorted(set(da)):
            print(f"    oracle  {name:34} {size / 65536:6.2f}pt flags {flags:#06x} face {idx}")
        if da != db:
            for size, flags, name, idx in sorted(set(db)):
                print(f"    new     {name:34} {size / 65536:6.2f}pt flags {flags:#06x} face {idx}")
        elif ra != rb:
            print("    font definitions agree, but the rest of the XDV differs")
    print(f"# {ok}/{len(FAMILIES)} families match")


if __name__ == "__main__":
    main(*sys.argv[1:])
