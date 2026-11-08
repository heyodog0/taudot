"""Make an app bundle's executables self-contained: copy every dylib they load from outside the system into
Contents/Frameworks and point them at it.

    uv run --no-project python tools/release/vendor.py Taudot.app [--licences DIR]

Every Mach-O file in the bundle (outside Contents/Frameworks/*.framework, which are vendored as they are) is read with
`otool -L`; each load path that isn't /System, /usr/lib or already relative (@rpath, @loader_path, @executable_path)
is resolved (symlinks followed, @loader_path/@rpath against the file it came from), copied once into
Contents/Frameworks under its install name's file name, given the id @rpath/<name>, and the reference is rewritten
to @loader_path/<relative path to Frameworks>/<name>. The copies are scanned the same way, so their own deps follow.

install_name_tool breaks the code signature: sign the bundle afterwards (tools/release/sign.sh).

--licences DIR: for each vendored dylib from a Homebrew keg (…/Cellar/<formula>/<version>/), copies the keg's
licence files to DIR/<formula>-<version>/ and writes DIR/index.tsv (dylib, formula, version, source path), for
the notices (tools/release/notices.py).
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

SYSTEM = ("/System/", "/usr/lib/")
RELATIVE = ("@rpath/", "@loader_path/", "@executable_path/")
LICENCE_NAMES = re.compile(r"^(LICEN[CS]E|COPYING|COPYRIGHT|NOTICE|AUTHORS|README)([.-].*)?$", re.I)


def run(*a: str) -> str:
    return subprocess.run(a, check=True, capture_output=True, text=True).stdout


def is_macho(p: Path) -> bool:
    if p.is_symlink() or not p.is_file():
        return False
    with open(p, "rb") as f:
        magic = f.read(4)
    return magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")


def deps(p: Path) -> list[str]:
    """Load commands of p (not its own id)."""
    out = run("otool", "-L", str(p)).splitlines()[1:]
    paths = [l.strip().split(" (compatibility")[0] for l in out if l.strip()]
    ident = run("otool", "-D", str(p)).splitlines()[1:]
    if ident and paths and paths[0] == ident[0].strip():
        paths = paths[1:]
    return paths


def rpaths(p: Path) -> list[str]:
    out = run("otool", "-l", str(p)).splitlines()
    return [out[i + 2].split()[1] for i, l in enumerate(out) if "LC_RPATH" in l and i + 2 < len(out)]


def resolve(ref: str, origin: Path, origin_src: Path) -> Path | None:
    """The file a load path names, seen from origin_src (where the referencing file came from)."""
    if ref.startswith("@loader_path/"):
        return (origin_src.parent / ref[len("@loader_path/"):]).resolve()
    if ref.startswith("@rpath/"):
        for rp in rpaths(origin):
            base = rp.replace("@loader_path", str(origin_src.parent)).replace("@executable_path", str(origin_src.parent))
            c = Path(base) / ref[len("@rpath/"):]
            if c.exists():
                return c.resolve()
        return None
    return Path(ref).resolve()


def keg(src: Path) -> tuple[str, str, Path] | None:
    parts = src.parts
    if "Cellar" in parts:
        i = parts.index("Cellar")
        if i + 2 < len(parts):
            return parts[i + 1], parts[i + 2], Path(*parts[: i + 3])
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("app", type=Path)
    ap.add_argument("--licences", type=Path)
    a = ap.parse_args()
    app = a.app.resolve()
    fw = app / "Contents/Frameworks"
    fw.mkdir(parents=True, exist_ok=True)

    def skip(p: Path) -> bool:
        return any(part.endswith(".framework") for part in p.relative_to(app).parts)

    # (file in the bundle, where it came from: for a vendored copy, its source, so @loader_path refs resolve)
    queue = [(p, p) for p in sorted(app.rglob("*")) if not skip(p) and is_macho(p)]
    vendored: dict[str, Path] = {}  # name in Frameworks -> source
    seen: set[Path] = set()
    while queue:
        f, src = queue.pop()
        if f in seen:
            continue
        seen.add(f)
        changes: list[str] = []
        for ref in deps(f):
            if ref.startswith(SYSTEM):
                continue
            if ref.startswith(RELATIVE) and f.parent != fw and not ref.startswith("@rpath/"):
                # already relative inside the bundle (e.g. a vendored framework's own); leave it
                target = resolve(ref, f, f)
                if target and str(target).startswith(str(app)):
                    continue
            target = resolve(ref, f, src)
            if target is None or not target.exists():
                print(f"vendor: {f.relative_to(app)} loads {ref}, which isn't found", file=sys.stderr)
                return 1
            if str(target).startswith(str(app)):
                continue
            name = Path(ref).name
            dst = fw / name
            if name in vendored and vendored[name] != target:
                print(f"vendor: two different {name}: {vendored[name]} and {target}", file=sys.stderr)
                return 1
            if name not in vendored:
                shutil.copy2(target, dst)
                os.chmod(dst, 0o755)
                run("install_name_tool", "-id", f"@rpath/{name}", str(dst))
                vendored[name] = target
                queue.append((dst, target))
            rel = os.path.relpath(fw, f.parent)
            new = f"@loader_path/{name}" if rel == "." else f"@loader_path/{rel}/{name}"
            changes += ["-change", ref, new]
        if changes:
            run("install_name_tool", *changes, str(f))
        # rpaths into the build machine are dead weight (and show the build's paths)
        for rp in rpaths(f):
            if not rp.startswith(RELATIVE):
                run("install_name_tool", "-delete_rpath", rp, str(f))

    for name, src in sorted(vendored.items()):
        print(f"vendored {name} <- {src}")
    if a.licences:
        a.licences.mkdir(parents=True, exist_ok=True)
        rows = []
        for name, src in sorted(vendored.items()):
            k = keg(src)
            if not k:
                rows.append(f"{name}\t\t\t{src}")
                continue
            formula, version, root = k
            d = a.licences / f"{formula}-{version}"
            d.mkdir(exist_ok=True)
            for lf in sorted(root.iterdir()):
                if lf.is_file() and LICENCE_NAMES.match(lf.name) and not lf.name.upper().startswith("README"):
                    shutil.copy2(lf, d / lf.name)
            for sub in ("share/doc", "share/licenses"):
                for lf in (root / sub).rglob("*") if (root / sub).exists() else []:
                    if lf.is_file() and LICENCE_NAMES.match(lf.name) and not lf.name.upper().startswith("README"):
                        shutil.copy2(lf, d / lf.name)
            rows.append(f"{name}\t{formula}\t{version}\t{src}")
        (a.licences / "index.tsv").write_text("\n".join(rows) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
