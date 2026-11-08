"""Writes the app's Acknowledgements.txt: every third-party piece Taudot.app carries, with its licence text.

    uv run --no-project python tools/release/notices.py OUT.txt --licences DIR --texpresso T --neovim-licence F
        --sparkle-licence F [--pdftex-source-note TEXT]

Sections, in order: what Taudot is made of (a short table), the GPL programs and where their source is, then each
piece with its licence. Identical licence texts (most Rust crates) are printed once, with every crate that uses
them listed above. Sources:
- DIR: tools/release/vendor.py's --licences output (the Homebrew kegs of the vendored dylibs).
- the TeXpresso checkout T: its LICENSE and the headers of the files with other licences (TECkit, SIL's layout code,
  SyncTeX, picohash, QOI), read from the files themselves;
- `cargo metadata` for the engine's crates (normal dependencies, for this platform), each crate's licence files;
- THIRD_PARTY.md (the OT core's ancestors, the themes).
Facts about the licences: docs/agents/renderer/licences.md.
"""

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LICENCE_FILE = re.compile(r"^(LICEN[CS]E|COPYING|COPYRIGHT|NOTICE|UNLICENSE)([.-].*)?$", re.I)
RULE = "=" * 78


def header(path: Path, max_lines: int = 60) -> str:
    """The first comment block of a source file, without comment markers."""
    lines = path.read_text(errors="replace").splitlines()[:max_lines]
    out: list[str] = []
    started = False
    for l in lines:
        s = l.strip()
        if not started:
            if s.startswith(("/*", "//", "*")):
                started = True
            elif not s:
                continue
            else:
                break
        if started and not s.startswith(("/*", "//", "*", "*/")) and s:
            break
        s = re.sub(r"^(/\*+|\*+/|//+|\*+)\s?", "", s)
        s = re.sub(r"\s*\*+/$", "", s)
        out.append(s)
        if l.strip().endswith("*/"):
            break
    return "\n".join(out).strip()


def crates() -> list[dict]:
    """The engine's normal dependencies on this platform, from cargo metadata."""
    host = subprocess.run(["rustc", "-vV"], capture_output=True, text=True, check=True).stdout
    triple = re.search(r"host: (\S+)", host).group(1)
    md = json.loads(subprocess.run(["cargo", "metadata", "--format-version", "1", "--filter-platform", triple],
                                   cwd=ROOT, capture_output=True, text=True, check=True).stdout)
    pkgs = {p["id"]: p for p in md["packages"]}
    nodes = {n["id"]: n for n in md["resolve"]["nodes"]}
    ws = set(md["workspace_members"])
    engine = next(i for i in ws if pkgs[i]["name"] == "taudot-engine")
    seen, todo = set(), [engine]
    while todo:
        i = todo.pop()
        if i in seen:
            continue
        seen.add(i)
        for d in nodes[i]["deps"]:
            if any(k["kind"] is None for k in d["dep_kinds"]):
                todo.append(d["pkg"])
    return sorted((pkgs[i] for i in seen if i not in ws), key=lambda p: (p["name"], p["version"]))


def crate_texts(p: dict) -> list[str]:
    d = Path(p["manifest_path"]).parent
    texts = []
    for f in sorted(d.iterdir()):
        if f.is_file() and LICENCE_FILE.match(f.name):
            texts.append(f.read_text(errors="replace").strip())
    if p.get("license_file"):
        f = d / p["license_file"]
        if f.exists():
            texts.append(f.read_text(errors="replace").strip())
    return texts


def section(title: str, body: str) -> str:
    return f"\n{RULE}\n{title}\n{RULE}\n\n{body.strip()}\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("out", type=Path)
    ap.add_argument("--licences", type=Path, required=True)
    ap.add_argument("--texpresso", type=Path, required=True)
    ap.add_argument("--neovim-licence", type=Path, required=True)
    ap.add_argument("--sparkle-licence", type=Path)
    ap.add_argument("--pdftex-source-note", default="")
    ap.add_argument("--version", default="")
    ap.add_argument("--static-keg", action="append", default=[], metavar="DIR",
                    help="a Homebrew keg (…/opt/NAME) linked statically into a shipped program, e.g. txp-render's FreeType")
    a = ap.parse_args()
    T = a.texpresso
    parts: list[str] = []

    parts.append(f"""Taudot {a.version}
Acknowledgements and licences

Taudot is made with the software below. Thank you to everyone who wrote it.

Portions of this software are copyright (c) The FreeType Project (www.freetype.org). All rights reserved.
""")

    parts.append(section("Programs under the GNU GPL, and where their source is", f"""
The live pdfTeX engine (pdftex, pdftex-live: a modified pdfTeX from TeX Live) and BibTeX ship inside Taudot.app as
separate programs, under the GNU General Public License, version 2 or (at your option) any later version. Taudot
runs them as separate processes; they are not part of Taudot's own program.

{a.pdftex_source_note or "Their complete corresponding source is published with each release: the tarball named taudot-gpl-source-VERSION.tar.gz next to the release's download, made by tools/release/gpl-source.sh. It holds our patches and the build scripts, and names the exact TeX Live source release they apply to."}

You may also ask for the source by writing to the address on taudot.app, for three years after a release.
The GNU GPL version 2 is in the file COPYING-GPL-2 next to these acknowledgements in the app
(Taudot.app/Contents/Resources/COPYING-GPL-2).
"""))

    # TeXpresso and what it contains
    tx = [f"TeXpresso (github.com/let-def/texpresso), used in texpresso-xetex (TeXpresso's XeTeX engine) and in\n"
          f"txp-render (the live XeLaTeX preview). MIT licence:\n\n{(T / 'LICENSE').read_text().strip()}"]
    for title, rel in [
        ("The XeTeX engine as ported by the Tectonic Project (MIT)", "src/engine/engine/xetex-ini.c"),
        ("XeTeX's font layout code, (c) SIL International and Jonathan Kew (MIT/X11)", "src/engine/layout/xetex-XeTeXLayoutInterface.cpp"),
        ("SyncTeX (MIT)", "src/engine/engine/xetex-synctex.c"),
        ("TECkit, (c) SIL International (taken under the Common Public License 1.0; unmodified)", "src/engine/engine/teckit-Engine.cpp"),
        ("picohash (public domain)", "src/engine/main/picohash.h"),
        ("QOI, (c) Dominic Szablewski (MIT)", "src/frontend/qoi.h"),
    ]:
        f = T / rel
        if f.exists():
            tx.append(f"{title}, from {rel}:\n\n{header(f)}")
    parts.append(section("TeXpresso, XeTeX, TECkit, SyncTeX", "\n\n---\n\n".join(tx)))

    parts.append(section("Neovim (Apache License 2.0; parts under the Vim licence)", a.neovim_licence.read_text()))
    if a.sparkle_licence and a.sparkle_licence.exists():
        parts.append(section("Sparkle (MIT), the updater", a.sparkle_licence.read_text()))

    # Vendored libraries
    idx = a.licences / "index.tsv"
    libs = []
    if idx.exists():
        for row in idx.read_text().splitlines():
            if not row.strip():
                continue
            name, formula, version, src = (row.split("\t") + ["", "", ""])[:4]
            libs.append((name, formula, version))
    by_formula: dict[tuple[str, str], list[str]] = {}
    for name, formula, version in libs:
        by_formula.setdefault((formula, version), []).append(name)
    static = {Path(k).resolve().parent.name for k in a.static_keg}
    for (formula, version), names in sorted(by_formula.items()):
        d = a.licences / f"{formula}-{version}"
        texts = [f"--- {f.name} ---\n\n{f.read_text(errors='replace').strip()}" for f in sorted(d.glob("*")) if f.is_file()] if d.exists() else []
        body = f"Libraries: {', '.join(names)}" + (" (also linked statically into txp-render)" if formula in static else "") + "\n\n" + ("\n\n".join(texts) if texts else "(no licence file in the package; see its project)")
        if formula == "jpeg-turbo":
            body = "This software is based in part on the work of the Independent JPEG Group.\n\n" + body
        parts.append(section(f"{formula} {version}", body))

    # Libraries linked statically (no dylib to vendor): their keg's licence files
    for kd in a.static_keg:
        root = Path(kd).resolve()
        formula, version = root.parent.name, root.name
        if formula in {f for f, _ in by_formula}:
            continue  # its licence is already there, with the vendored dylib
        files = [f for f in sorted(root.iterdir()) if f.is_file() and LICENCE_FILE.match(f.name)]
        for sub in ("share/doc", "share/licenses"):
            if (root / sub).exists():
                files += [f for f in sorted((root / sub).rglob("*")) if f.is_file() and LICENCE_FILE.match(f.name)]
        texts = [f"--- {f.name} ---\n\n{f.read_text(errors='replace').strip()}" for f in files]
        body = "Linked statically into txp-render.\n\n" + ("\n\n".join(texts) if texts else "(no licence file in the package; see its project)")
        parts.append(section(f"{formula} {version}", body))

    # Rust crates, grouped by identical text
    groups: dict[str, tuple[str, list[str]]] = {}
    no_text: list[str] = []
    for p in crates():
        label = f"{p['name']} {p['version']} ({p.get('license') or 'see crate'})"
        texts = crate_texts(p)
        if not texts:
            no_text.append(label)
            continue
        t = "\n\n---\n\n".join(texts)
        h = hashlib.sha256(t.encode()).hexdigest()
        groups.setdefault(h, (t, []))[1].append(label)
    rust = ["The sync engine (taudot) is written in Rust and uses these crates, each under the licence(s) named."]
    if no_text:
        rust.append("Crates that ship no licence file (their licence is the SPDX expression given):\n  " + "\n  ".join(no_text))
    for t, labels in sorted(groups.values(), key=lambda g: g[1][0]):
        rust.append("Used by:\n  " + "\n  ".join(labels) + "\n\n" + t)
    parts.append(section("Rust crates in the sync engine", "\n\n" + ("\n\n" + "-" * 78 + "\n\n").join(rust)))

    tp = ROOT / "THIRD_PARTY.md"
    if tp.exists():
        parts.append(section("Taudot's OT core ancestors and colour themes (THIRD_PARTY.md)", tp.read_text()))

    a.out.write_text("\n".join(parts))
    print(f"notices: {a.out} ({a.out.stat().st_size // 1024} KB, {len(by_formula)} libraries, {sum(len(g[1]) for g in groups.values()) + len(no_text)} crates)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
