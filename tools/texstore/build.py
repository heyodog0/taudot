"""Build a TeX Live image's index and its share of the store, from TeX Live's Subversion repository.

An image is NAME@rREV: Overleaf's image name (texlive-full:NAME) and the revision of TeX Live's svn
(svn://tug.org/texlive/trunk/Master) it matches, e.g. 2026.1@r79413. Each file comes straight from svn at that
revision, so mid-year images (on no ISO) work the same as releases.

  uv run tools/texstore/build.py tlpdb IMAGE                the package database at the revision
  uv run tools/texstore/build.py files IMAGE [-j N] [--from IMAGE2]
                                                            every run file of every package into the store;
                                                            --from reuses IMAGE2's exports, fetching svn's changes
  uv run tools/texstore/build.py gen IMAGE PATH=FILE ...    add generated files (format, pdftex.map) to the image
  uv run tools/texstore/build.py index IMAGE                write ls-R, the package manifests and the image index
  uv run tools/texstore/build.py gc [--dry-run]             remove objects no image references (not during `files`)
  uv run tools/texstore/build.py stats [IMAGE ...]          sizes, and what sharing across images saves

Everything lives in $TEXSTORE_REF (~/code/lab/taudot-ref/texstore): store/ is what goes to R2, work/IMAGE/ is build
state. `files` resumes where it stopped. The format is in docs/texstore.md.
"""
import os
import shutil
import sys
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import texstore as ts  # noqa: E402

GEN = "_generated"  # the pseudo-package that holds an image's generated files
EXPORT_MIN = 200    # a directory with at least this many run files is exported whole; the rest are `svn cat`


class Image:
    def __init__(self, spec):
        self.name, self.rev = ts.parse_image(spec)
        self.spec = f"{self.name}@r{self.rev}"
        self.dir = os.path.join(ts.WORK, self.spec)
        self.pkgs = os.path.join(self.dir, "pkgs")

    def tlpdb_path(self):
        return os.path.join(self.dir, "texlive.tlpdb")


# --- tlpdb -------------------------------------------------------------------------------------------------------

def cmd_tlpdb(im):
    os.makedirs(im.dir, exist_ok=True)
    ts.svn("cat", "-r", str(im.rev), f"{ts.SVN}/tlpkg/texlive.tlpdb", out=im.tlpdb_path() + ".part")
    os.replace(im.tlpdb_path() + ".part", im.tlpdb_path())
    info = ts.svn("log", "-q", "-l", "1", "-r", f"{im.rev}:1", f"{ts.SVN}/tlpkg/texlive.tlpdb").decode()
    pk = tlpdb(im)
    print(f"{im.spec}: tlpdb last rebuilt at {info.splitlines()[1].strip()}; {len(pk)} packages with run files, "
          f"{sum(len(p['runfiles']) for p in pk.values())} run files")


def tlpdb(im):
    """name -> {rev, runfiles: [root-relative paths]}, packages that a full install's TeX needs."""
    pk, cur, files = {}, None, False
    with open(im.tlpdb_path(), encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                cur, files = None, False
            elif line.startswith(" "):
                if files and cur is not None:
                    cur["runfiles"].append(line[1:].split(" ", 1)[0])
            else:
                files = False
                k, _, v = line.partition(" ")
                if k == "name":
                    cur = pk[v] = {"rev": None, "runfiles": []}
                elif cur is None:
                    continue
                elif k == "revision":
                    cur["rev"] = v
                elif k == "runfiles":
                    files = True
    # 00texlive.* are the installer's; platform packages (NAME.ARCH-OS, NAME.windows) hold binaries, and a few
    # (tlperl.windows, ...) list them as run files.
    return {n: p for n, p in pk.items() if p["runfiles"] and not n.startswith("00texlive.") and not is_platform(n)}


def is_platform(name):
    suffix = name.rsplit(".", 1)[1] if "." in name else ""
    return suffix == "windows" or "-" in suffix


# --- files -------------------------------------------------------------------------------------------------------

def group(path):
    """The directory exported as one piece: texmf-dist/<top>, else the path's own directory."""
    parts = path.split("/")
    return "/".join(parts[:2]) if parts[0] == "texmf-dist" and len(parts) > 2 else os.path.dirname(path) or "."


def read_exported(base, rel):
    """(bytes, executable) of an exported file; a symlink reads as what it points to (inside the export)."""
    p = os.path.join(base, rel)
    real = os.path.realpath(p)
    if not real.startswith(os.path.realpath(base) + os.sep):
        raise ValueError(f"{rel}: link leaves the tree")
    with open(real, "rb") as f:
        return f.read(), bool(os.stat(real).st_mode & 0o111)


def cat_many(im, paths, jobs):
    """{path: (size, hash, "")} for files fetched by `svn cat` at the image's revision; missing ones map to None."""
    def one(f):
        try:
            b = ts.svn("cat", "-r", str(im.rev), f"{ts.SVN}/{f}@{im.rev}")
        except OSError:
            return f, None
        h, _, _ = ts.put(b)
        return f, (len(b), h, "")
    with ThreadPoolExecutor(jobs) as ex:
        return dict(ex.map(one, sorted(paths)))


REEXPORT = 2000  # with more changed or uncovered run files than this, a directory is exported again instead


def rebase(im, base, got_dir, jobs):
    """Start from another image's exported directories: copy their records, then fetch again only what svn says
    changed between the two revisions (content or properties; deletions become missing). A directory with more
    than REEXPORT such files is left to be exported whole at this revision."""
    lo, hi = sorted((base.rev, im.rev))
    out = ts.svn("diff", "--summarize", "-r", f"{lo}:{hi}", ts.SVN).decode()
    changed = {}
    for line in out.splitlines():
        url = line[8:].strip()
        if url.startswith(ts.SVN + "/"):
            changed[url[len(ts.SVN) + 1:]] = line[0]
    runfiles = {f for p in tlpdb(im).values() for f in p["runfiles"]}
    for fn in os.listdir(os.path.join(base.dir, "got")):
        if not fn.startswith("texmf-dist_") or fn.endswith(".part"):
            continue
        rows = {r[0] for r in ts.read_tsv(os.path.join(base.dir, "got", fn))}
        g = fn.replace("_", "/", 1)
        mine = {f for f in runfiles if group(f) == g}
        work = len({f for f in mine if f in changed or f not in rows})
        if work > REEXPORT:
            print(f"  {g}: {work} run files changed or new since {base.spec}; exporting it again", flush=True)
            continue
        shutil.copy(os.path.join(base.dir, "got", fn), os.path.join(got_dir, fn))
    copied = {}  # path -> executable flag, which `svn cat` can't tell
    for fn in os.listdir(got_dir):
        if fn.startswith("texmf-dist_"):
            copied.update({r[0]: r[3] if len(r) > 3 else "" for r in ts.read_tsv(os.path.join(got_dir, fn))})
    todo = {p for p in changed if p in copied}
    rows = cat_many(im, todo, jobs)
    with open(os.path.join(got_dir, "zz_rebase"), "w") as f:  # read last, so it overrides the copied records
        for p, r in sorted(rows.items()):
            f.write(f"{p}\t-\t-\t-\n" if r is None else f"{p}\t{r[0]}\t{r[1]}\t{copied[p]}\n")
    print(f"  from {base.spec}: {len(copied)} files reused, {len(changed)} paths changed in svn, "
          f"{len(todo)} of them run files fetched again", flush=True)


def cmd_files(im, jobs=6, base=None):
    """Every run file at the revision, into the store. Big directories come by one `svn export` each (then
    deleted), stray files by `svn cat`. Per-directory results are kept in work/IMAGE/got/, so it resumes.
    With `base` (another image), its exported directories are reused and only svn's changes are fetched."""
    os.makedirs(os.path.join(ts.STORE, "files"), exist_ok=True)
    got_dir = os.path.join(im.dir, "got")
    os.makedirs(got_dir, exist_ok=True)
    if base and not os.path.exists(os.path.join(got_dir, "zz_rebase")):
        rebase(im, base, got_dir, jobs)
    pk = tlpdb(im)
    groups = {}
    for p in pk.values():
        for f in p["runfiles"]:
            groups.setdefault(group(f), set()).add(f)
    big = sorted(g for g, fs in groups.items() if len(fs) >= EXPORT_MIN)
    small = sorted(f for g, fs in groups.items() if len(fs) < EXPORT_MIN for f in fs)
    print(f"{im.spec}: {sum(map(len, groups.values()))} run files; {len(big)} directories to export "
          f"({', '.join(big)}), {len(small)} files one by one", flush=True)

    def record(name, rows, missing):
        with open(os.path.join(got_dir, name + ".part"), "w") as f:
            f.writelines(f"{p}\t{s}\t{h}\t{x}\n" for p, (s, h, x) in sorted(rows.items()))
            f.writelines(f"{p}\t-\t-\t-\n" for p in sorted(missing))
        os.replace(os.path.join(got_dir, name + ".part"), os.path.join(got_dir, name))

    for g in big:
        name = g.replace("/", "_")
        if os.path.exists(os.path.join(got_dir, name)):
            continue
        dest = os.path.join(im.dir, "export", name)
        shutil.rmtree(dest, ignore_errors=True)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        print(f"  svn export {g} …", flush=True)
        ts.svn("export", "-q", "-r", str(im.rev), f"{ts.SVN}/{g}@{im.rev}", dest)
        rows, missing = {}, []
        for f in sorted(groups[g]):
            rel = os.path.relpath(f, g)
            if not os.path.lexists(os.path.join(dest, rel)):
                missing.append(f)
                continue
            b, x = read_exported(dest, rel)
            h, _, _ = ts.put(b)
            rows[f] = (len(b), h, "x" if x else "")
        record(name, rows, missing)
        shutil.rmtree(dest)
        print(f"  {g}: {len(rows)} files, {len(missing)} listed but not in svn", flush=True)

    if not os.path.exists(os.path.join(got_dir, "_single")):
        rows = cat_many(im, small, jobs)
        record("_single", {p: r for p, r in rows.items() if r}, [p for p, r in rows.items() if r is None])
        print(f"  one by one: {sum(1 for r in rows.values() if r)} files, "
              f"{sum(1 for r in rows.values() if r is None)} not in svn", flush=True)

    def load():
        have = {}
        for fn in sorted(os.listdir(got_dir)):  # zz_ records come last and win
            if not fn.endswith(".part"):
                have.update({r[0]: r[1:] for r in ts.read_tsv(os.path.join(got_dir, fn))})
        return have
    have = load()
    # Run files no record covers (added since a base image's exports): fetch them one by one.
    fill = {f for p in pk.values() for f in p["runfiles"] if f not in have}
    if fill:
        rows = cat_many(im, fill, jobs)
        record("zz_fill", {p: r for p, r in rows.items() if r}, [p for p, r in rows.items() if r is None])
        print(f"  filled in: {len(fill)} run files not covered by any export", flush=True)
        have = load()

    # Per package, as the index wants them.
    os.makedirs(im.pkgs, exist_ok=True)
    gaps = []
    for name, p in sorted(pk.items()):
        rows = [(f, *have[f]) for f in sorted(p["runfiles"]) if have.get(f, ["-"])[0] != "-"]
        gaps += [f"{name}: {f}" for f in p["runfiles"] if have.get(f, ["-"])[0] == "-"]
        with open(os.path.join(im.pkgs, name + ".tsv"), "w") as f:
            f.write(f"# svn\t{p['rev']}\n")
            f.writelines("\t".join(r) + "\n" for r in rows)
    with open(os.path.join(im.dir, "missing.txt"), "w") as f:
        f.writelines(g + "\n" for g in gaps)
    print(f"{im.spec}: {len(pk)} packages written; {len(gaps)} listed files not in svn (missing.txt)")
    return 0


# --- gen ---------------------------------------------------------------------------------------------------------

def cmd_gen(im, pairs):
    """PATH=FILE: put FILE in the store as root-relative PATH among the image's generated files."""
    out = os.path.join(im.pkgs, GEN + ".tsv")
    rows = {r[0]: r[1:] for r in ts.read_tsv(out)} if os.path.exists(out) else {}
    for pair in pairs:
        path, _, src = pair.partition("=")
        with open(src, "rb") as f:
            b = f.read()
        h, _, _ = ts.put(b)
        rows[path] = (str(len(b)), h, "")
        print(f"{path}: {len(b)} bytes, {h[:16]}…")
    with open(out + ".part", "w") as f:
        f.write("# generated\n")
        f.writelines(f"{p}\t{s}\t{h}\t{x}\n" for p, (s, h, x) in sorted(rows.items()))
    os.replace(out + ".part", out)


# --- index -------------------------------------------------------------------------------------------------------

def load_image(im):
    """pkg -> (package revision or None, [[path, size, hash, x]])"""
    out = {}
    for fn in sorted(os.listdir(im.pkgs)):
        if not fn.endswith(".tsv"):
            continue
        with open(os.path.join(im.pkgs, fn), encoding="utf-8") as f:
            head = f.readline()[2:].rstrip("\n").split("\t")
            rows = [line.rstrip("\n").split("\t") for line in f if line.strip()]
        out[fn[:-4]] = (head[1] if head[0] == "svn" else None, rows)
    return out


def lsr(paths):
    """kpathsea's ls-R for a tree holding `paths` (relative to the tree)."""
    dirs = {}
    for p in paths:
        d, _, b = p.rpartition("/")
        dirs.setdefault(d, set()).add(b)
        while d:
            pd, _, pb = d.rpartition("/")
            dirs.setdefault(pd, set()).add(pb)
            d = pd
    out = ["% ls-R -- filename database for kpathsea; do not change this line.\n"]
    for d in sorted(dirs):
        out.append(f"./{d}:\n" if d else "./:\n")
        out.extend(n + "\n" for n in sorted(dirs[d]))
        out.append("\n")
    return "".join(out).encode()


def cmd_index(im):
    pk = tlpdb(im)
    data = load_image(im)
    missing = sorted(set(pk) - set(data))
    if missing:
        sys.exit(f"{im.spec}: {len(missing)} packages not built yet (run `files`), e.g. {missing[:5]}")
    # ls-R for texmf-dist and texmf-var: every file a full install has there, generated ones included.
    gen = {r[0]: r for r in data.get(GEN, (None, []))[1]}
    allpaths = {r[0] for n, (_, rows) in data.items() for r in rows}
    for top in ("texmf-dist", "texmf-var"):
        sub = sorted(p[len(top) + 1:] for p in allpaths if p.startswith(top + "/") and p != f"{top}/ls-R")
        b = lsr(sub)
        h, _, _ = ts.put(b)
        gen[f"{top}/ls-R"] = [f"{top}/ls-R", str(len(b)), h, ""]
    data[GEN] = (None, sorted(gen.values()))
    # One manifest per package, named by its hash; the index lists packages, then every path.
    pkgrows, pathrows = [], []
    for name in sorted(data):
        head, rows = data[name]
        man = "".join(f"{p}\t{s}\t{h}\t{x}\n" for p, s, h, x in rows).encode()
        mh, _, _ = ts.put(man)
        pkgrows.append(f"P\t{name}\t{mh}\t{len(rows)}\t{sum(int(r[1]) for r in rows)}\t{head or ''}\n")
        pathrows.extend(f"F\t{p}\t{s}\t{name}\n" for p, s, _, _ in rows)
    pathrows.sort(key=lambda r: r.split("\t", 2)[1].encode())
    with open(im.tlpdb_path(), "rb") as f:
        dbsum = ts.sha512(f.read())
    head = (f"texstore\t{ts.FORMAT}\n"
            f"image\t{im.name}\tr{im.rev}\n"
            f"svn\t{ts.SVN}\t{im.rev}\t{dbsum}\n")
    idx = (head + "".join(pkgrows) + "".join(pathrows)).encode()
    ih, iz, _ = ts.put(idx)
    d = os.path.join(ts.STORE, "images", im.name)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, f"r{im.rev}"), "w") as f:
        f.write(ih + "\n")
    with open(os.path.join(im.dir, "files.tsv"), "w") as f:  # every path's hash in one table, for checks and stats
        f.writelines(f"{p}\t{s}\t{h}\t{name}\n" for name in sorted(data) for p, s, h, _ in data[name][1])
    inline = len(ts.pack(open(os.path.join(im.dir, "files.tsv"), "rb").read()))
    print(f"{im.spec}: {len(pkgrows)} packages, {len(pathrows)} files; index {len(idx) / 1e6:.1f} MB, "
          f"{iz / 1e6:.2f} MB packed (with hashes inline: {inline / 1e6:.1f} MB packed); "
          f"images/{im.name}/r{im.rev} = {ih[:16]}…")


# --- gc ----------------------------------------------------------------------------------------------------------

def cmd_gc(dry):
    """Remove store objects that no image references (left by packages dropped from an image, or a rebuilt one).
    Never run it while `files` runs: objects a build has stored but not yet recorded would go."""
    keep = set()
    for spec in sorted(d for d in os.listdir(ts.WORK) if "@" in d and os.path.isdir(os.path.join(ts.WORK, d))):
        im = Image(spec)
        for _, rows in load_image(im).values():
            keep |= {r[2] for r in rows}
        ptr = os.path.join(ts.STORE, "images", im.name, f"r{im.rev}")
        if os.path.exists(ptr):
            with open(ptr) as f:
                ih = f.read().strip()
            keep.add(ih)
            for line in ts.get(ih).decode().splitlines():
                if line.startswith("P\t"):
                    mh = line.split("\t")[2]
                    keep.add(mh)
                    if line.startswith(f"P\t{GEN}\t"):  # ls-R exists only in this manifest
                        keep |= {r.split("\t")[2] for r in ts.get(mh).decode().splitlines()}
    d = os.path.join(ts.STORE, "files")
    drop = [n for n in os.listdir(d) if n not in keep]
    size = sum(os.path.getsize(os.path.join(d, n)) for n in drop)
    for n in drop if not dry else []:
        os.remove(os.path.join(d, n))
    print(f"{len(keep)} objects referenced; {'would remove' if dry else 'removed'} {len(drop)} ({size / 1e6:.1f} MB)")


# --- stats -------------------------------------------------------------------------------------------------------

def cmd_stats(specs):
    seen, union_raw, union_z = set(), 0, 0
    print(f"| image | files | unique | raw GB | packed GB | new objects vs earlier rows |")
    print(f"|---|---|---|---|---|---|")
    for spec in specs:
        im = Image(spec)
        uniq = {}
        for p, s, h, _ in ts.read_tsv(os.path.join(im.dir, "files.tsv")):
            uniq[h] = int(s)
        nfiles = sum(1 for _ in open(os.path.join(im.dir, "files.tsv")))
        z = {h: os.path.getsize(ts.object_path(h)) for h in uniq}
        new = [h for h in uniq if h not in seen]
        union_raw += sum(uniq[h] for h in new)
        union_z += sum(z[h] for h in new)
        seen |= set(uniq)
        print(f"| {spec} | {nfiles} | {len(uniq)} | {sum(uniq.values()) / 1e9:.2f} | {sum(z.values()) / 1e9:.2f} | "
              f"{len(new)}, {sum(z[h] for h in new) / 1e9:.2f} GB packed |")
    print(f"\nall: {len(seen)} objects, {union_raw / 1e9:.2f} GB raw, {union_z / 1e9:.2f} GB packed")


def main(a):
    if len(a) >= 2 and a[0] in ("tlpdb", "files", "gen", "index"):
        im = Image(a[1])
        if a[0] == "tlpdb":
            cmd_tlpdb(im)
        elif a[0] == "files":
            return cmd_files(im, int(a[a.index("-j") + 1]) if "-j" in a else 6,
                             Image(a[a.index("--from") + 1]) if "--from" in a else None)
        elif a[0] == "gen":
            cmd_gen(im, a[2:])
        elif a[0] == "index":
            cmd_index(im)
    elif a[:1] == ["gc"]:
        cmd_gc("--dry-run" in a)
    elif a[:1] == ["stats"]:
        cmd_stats(a[1:] or sorted(d for d in os.listdir(ts.WORK) if "@" in d and os.path.isdir(os.path.join(ts.WORK, d))))
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
