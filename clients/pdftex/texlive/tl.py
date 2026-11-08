# GPL-2.0-or-later. A TeX Live year on demand: the tree of a full install, with only the files used so far on disk.
#
#   uv run --with pycdlib clients/pdftex/texlive/tl.py setup YEAR    build ROOT: the package database, an ls-R that
#                                                                    lists every file of a full install, and the
#                                                                    files TeX Live's installer generates
#   clients/pdftex/texlive/tl.py fetch PATH                          fetch the package holding PATH (ROOT/...) and
#                                                                    unpack it; run by kpathsea (TAUDOT_TL_FETCH)
#   clients/pdftex/texlive/tl.py env YEAR [FMTDIR]                   print the environment for a run
#   clients/pdftex/texlive/tl.py store YEAR                          set up ROOT for the TeX Live store (below)
#   clients/pdftex/texlive/tl.py cost YEAR FLS...                    packages (and MB) a first compile fetches,
#                                                                    from pdfTeX -recorder files
#
# The source is the year's release ISO on TeX Live's historic archive, read by HTTP byte ranges (iso.py): Overleaf's
# images are frozen installs, and 2025's carries the release's pdfTeX (1.40.27), not the year's final one (1.40.28).
# ROOT is ~/code/lab/taudot-ref/texlive-YEAR/root; packages are checked against the database's sha512.
#
# The TeX Live store (docs/texstore.md) is the default source for the years in IMAGES: ROOT is then
# ~/code/lab/taudot-ref/texlive-YEAR/store-root, and kpathsea fetches from the store itself, in process
# (patch 0001, taudot-store.c), with TEXSTORE_URL/IMAGE/ROOT set by `env`. TAUDOT_TL_SOURCE=iso: the release ISO.
import fcntl
import hashlib
import io
import lzma
import os
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.request

REF = os.path.expanduser("~/code/lab/taudot-ref")
CONNECT_S = 5    # per request: connect and each read
OFFLINE_S = 30   # after a failed fetch, missing files fail at once for this long
HERE = os.path.dirname(os.path.abspath(__file__))
STORE = "https://texlive.taudot.app"
IMAGES = {"2026": "2026.1@r79468", "2025": "2025.1@r74524", "2024": "2024.1@r70643"}
ISO = {
    "2025": "https://ftp.math.utah.edu/pub/tex/historic/systems/texlive/2025/texlive2025-20250308.iso",
}


def year_dir(year):
    return os.path.join(REF, f"texlive-{year}")


def tlpdb_packages(path):
    """name -> {relocated, checksum, runfiles: [paths relative to ROOT]}"""
    pk, cur, files = {}, None, False
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                cur, files = None, False
                continue
            if line.startswith(" "):
                if files and cur:
                    p = line[1:].split(" ", 1)[0]
                    cur["runfiles"].append("texmf-dist/" + p[6:] if p.startswith("RELOC/") else p)
                continue
            files = False
            k, _, v = line.partition(" ")
            if k == "name":
                cur = pk[v] = {"relocated": False, "checksum": None, "runfiles": [], "execute": []}
            elif cur is None:
                continue
            elif k == "relocated":
                cur["relocated"] = v == "1"
            elif k == "containerchecksum":
                cur["checksum"] = v
            elif k == "runfiles":
                files = True
            elif k == "execute":
                cur["execute"].append(v)
    return pk


def write_lsr(top, paths):
    """kpathsea's ls-R for directory `top`, listing `paths` (relative to top) whether or not they're on disk."""
    dirs = {}
    for p in paths:
        d, _, b = p.rpartition("/")
        dirs.setdefault(d, set()).add(b)
        while d:  # parents list their subdirectories, as `ls -R` does
            pd, _, pb = d.rpartition("/")
            dirs.setdefault(pd, set()).add(pb)
            d = pd
    out = ["% ls-R -- filename database for kpathsea; do not change this line.\n"]
    for d in sorted(dirs):
        out.append(f"./{d}:\n" if d else "./:\n")
        out.extend(n + "\n" for n in sorted(dirs[d]))
        out.append("\n")
    with open(os.path.join(top, "ls-R.part"), "w") as f:
        f.writelines(out)
    os.rename(os.path.join(top, "ls-R.part"), os.path.join(top, "ls-R"))


def source(y):
    """The TeX Live source for year Y: the store where it has an image, else the release ISO."""
    if y in IMAGES and os.environ.get("TAUDOT_TL_SOURCE") != "iso":
        return Store(y)
    return Year(y)


class Store:
    """A year from the TeX Live store. Only texmf.cnf and the two ls-R files are put in ROOT up front; kpathsea
    fetches the rest itself."""

    def __init__(self, year):
        self.year, self.dir, self.image = year, year_dir(year), IMAGES[year]
        self.root = os.environ.get("TAUDOT_TL_STORE_ROOT") or os.path.join(self.dir, "store-root")
        self.cnf = self.root + "-cnf"
        self.url = os.environ.get("TEXSTORE_URL", STORE)

    def env(self, fmtdir=None):
        e = {
            "TEXMFCNF": f"{self.cnf}:{self.root}/texmf-dist/web2c",
            "TEXSTORE_URL": self.url,
            "TEXSTORE_IMAGE": self.image,
            "TEXSTORE_ROOT": self.root,
        }
        if fmtdir:
            e["TEXFORMATS"] = f".:{fmtdir}"
        return e

    def setup(self):
        cnf = self.cnf
        os.makedirs(cnf, exist_ok=True)
        os.makedirs(self.root, exist_ok=True)
        with open(os.path.join(cnf, "texmf.cnf"), "w") as f:
            f.write(f"""% GPL-2.0-or-later. Read before TeX Live's own texmf.cnf (ROOT/texmf-dist/web2c), which it overrides:
% the TeX Live store's image {self.image} as installed at ROOT, with no user or local trees.
TEXMFROOT = {self.root}
TEXMFLOCAL = $TEXMFROOT/texmf-local
TEXMFHOME = $TEXMFROOT/texmf-home
TEXMFVAR = $TEXMFROOT/texmf-var
TEXMFCONFIG = $TEXMFROOT/texmf-config
TEXMFSYSVAR = $TEXMFROOT/texmf-var
TEXMFSYSCONFIG = $TEXMFROOT/texmf-config
""")
        client = os.path.join(HERE, "..", "..", "..", "tools", "texstore", "client.py")
        subprocess.run([sys.executable, "-I", client, "init"], check=True,
                       env={**os.environ, **self.env(), "TEXSTORE_IMAGE": self.image})


class Year:
    def __init__(self, year):
        self.year, self.dir = year, year_dir(year)
        self.root = os.path.join(self.dir, "root")
        self.iso = os.environ.get("TAUDOT_TL_ISO") or ISO[year]  # override: a mirror, or a test
        self.offline = os.path.join(self.root, ".offline")
        self.idx = os.path.join(self.dir, "iso-index.tsv")

    def archive(self, pkg):
        """(offset, size) of archive/PKG.rREV.tar.xz in the ISO."""
        pre = f"archive/{pkg}.r"
        with open(self.idx) as f:
            for line in f:
                n, o, s = line.split("\t")
                if n.startswith(pre) and n.endswith(".tar.xz") and n[len(pre):-7].isdigit():
                    return int(o), int(s)
        raise KeyError(pkg)

    def iso_file(self, name):
        with open(self.idx) as f:
            for line in f:
                n, o, s = line.split("\t")
                if n == name:
                    return self.range(int(o), int(s))
        raise KeyError(name)

    def range(self, off, size):
        """One byte range of the ISO. Two tries; a failure marks the tree offline for OFFLINE_S, so a compile
        without network fails each missing file at once instead of waiting on every lookup."""
        for attempt in range(2):
            try:
                req = urllib.request.Request(self.iso, headers={"Range": f"bytes={off}-{off + size - 1}"})
                with urllib.request.urlopen(req, timeout=CONNECT_S) as r:
                    b = r.read()
                if len(b) == size:
                    return b
            except OSError:
                pass
            if attempt == 0:
                time.sleep(0.3)
        with open(self.offline, "w") as f:
            f.write(f"{self.iso} {time.time():.0f}\n")
        raise OSError(f"range {off}+{size} of {self.iso} failed")

    def is_offline(self):
        try:
            return time.time() - os.path.getmtime(self.offline) < OFFLINE_S
        except OSError:
            return False

    def unpack(self, pkg, info):
        done = os.path.join(self.root, ".fetched", pkg)
        if os.path.exists(done):
            return False
        t = time.monotonic()
        data = self.range(*self.archive(pkg))
        if info["checksum"] and hashlib.sha512(data).hexdigest() != info["checksum"]:
            raise OSError(f"{pkg}: checksum mismatch")
        dest = os.path.join(self.root, "texmf-dist") if info["relocated"] else self.root
        # Unpack beside the tree, then move each file in with rename: an interrupted fetch never leaves a
        # truncated file for kpathsea to find.
        tmp = os.path.join(self.root, f".unpack-{pkg}-{os.getpid()}")
        with tarfile.open(fileobj=io.BytesIO(lzma.decompress(data))) as tar:
            members = [m for m in tar.getmembers() if not m.name.startswith("tlpkg/tlpobj/")]
            tar.extractall(tmp, members=members, filter="tar")
        for d, _, files in os.walk(tmp):
            for n in files:
                rel = os.path.relpath(os.path.join(d, n), tmp)
                os.makedirs(os.path.dirname(os.path.join(dest, rel)), exist_ok=True)
                os.replace(os.path.join(d, n), os.path.join(dest, rel))
        shutil.rmtree(tmp, ignore_errors=True)
        os.makedirs(os.path.dirname(done), exist_ok=True)
        with open(done, "w") as f:
            f.write(f"{len(data)} {time.monotonic() - t:.3f}\n")
        return True

    def packages(self):
        return tlpdb_packages(os.path.join(self.root, "tlpkg", "texlive.tlpdb"))

    def file_index(self):
        return os.path.join(self.root, "tlpkg", "taudot-files.tsv")

    def owner(self, rel):
        """The package holding ROOT-relative path `rel` (binary search in the sorted index)."""
        with open(self.file_index(), "rb") as f:
            data = f.read()
        key = rel.encode() + b"\t"
        lo, hi = 0, len(data)
        while lo < hi:  # find the first line >= key
            mid = (lo + hi) // 2
            s = data.rfind(b"\n", 0, mid) + 1
            e = data.find(b"\n", s)
            if data[s:e] + b"\n" < key:
                lo = e + 1
            else:
                hi = s
        e = data.find(b"\n", lo)
        line = data[lo:e]
        return line[len(key):].decode() if line.startswith(key) else None

    def fetch(self, path):
        rel = os.path.relpath(os.path.abspath(path), self.root)
        if rel.startswith(".."):
            return 1
        pkg = self.owner(rel)
        if not pkg or self.is_offline():
            return 1
        os.makedirs(self.root, exist_ok=True)
        with open(os.path.join(self.root, ".lock"), "w") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            if self.is_offline():  # another process just found the network down
                return 1
            try:
                self.unpack(pkg, self.packages_one(pkg))
            except OSError as e:
                print(f"tl-fetch: {pkg}: {e}", file=sys.stderr)
                return 1
        return 0 if os.path.exists(path) else 1

    def packages_one(self, pkg):
        """One package's entry, without parsing the whole database."""
        out = {"relocated": False, "checksum": None}
        with open(os.path.join(self.root, "tlpkg", "texlive.tlpdb"), encoding="utf-8", errors="replace") as f:
            found = False
            for line in f:
                if line == f"name {pkg}\n":
                    found = True
                elif found and line == "\n":
                    break
                elif found and line.startswith("relocated "):
                    out["relocated"] = line.strip().endswith("1")
                elif found and line.startswith("containerchecksum "):
                    out["checksum"] = line.split()[1]
        return out

    def env(self, fmtdir=None):
        cnf = os.path.join(self.dir, "cnf")
        e = {
            "TEXMFCNF": f"{cnf}:{self.root}/texmf-dist/web2c",
            "TAUDOT_TL_ROOT": self.root,
            "TAUDOT_TL_FETCH": os.path.join(HERE, "tl-fetch"),
            "TAUDOT_TL_YEAR": self.year,
        }
        if fmtdir:
            e["TEXFORMATS"] = f".:{fmtdir}"
        return e

    def setup(self):
        os.makedirs(self.root, exist_ok=True)
        if not os.path.exists(self.idx):
            sys.path.insert(0, HERE)
            import iso
            iso.index(self.iso, self.idx)
        db = os.path.join(self.root, "tlpkg", "texlive.tlpdb")
        if not os.path.exists(db):
            os.makedirs(os.path.dirname(db), exist_ok=True)
            with open(db + ".part", "wb") as f:
                f.write(self.iso_file("tlpkg/texlive.tlpdb"))
            os.rename(db + ".part", db)
        pk = self.packages()
        # Every run file of every package, as a full install (scheme-full) has them; platform binaries aside.
        rows = sorted({(p, n) for n, i in pk.items() if "." not in n or not n.rsplit(".", 1)[1].count("-")
                       for p in i["runfiles"]})
        with open(self.file_index() + ".part", "w") as f:
            f.writelines(f"{p}\t{n}\n" for p, n in rows)
        os.rename(self.file_index() + ".part", self.file_index())
        dist = [p[len("texmf-dist/"):] for p, _ in rows if p.startswith("texmf-dist/")]
        # Files TeX Live's installer generates, listed too so kpathsea's !! (ls-R only) paths see them.
        gen_dist = ["web2c/fmtutil.cnf", "web2c/updmap.cfg"]
        gen_var = ["tex/generic/config/language.dat", "tex/generic/config/language.def",
                   "tex/generic/config/language.dat.lua", "fonts/map/pdftex/updmap/pdftex.map",
                   "fonts/map/dvips/updmap/psfonts.map", "fonts/map/dvips/updmap/download35.map",
                   "fonts/map/dvips/updmap/builtin35.map", "fonts/map/dvips/updmap/psfonts_t1.map",
                   "fonts/map/dvips/updmap/psfonts_pk.map", "fonts/map/dvipdfmx/updmap/kanjix.map",
                   "fonts/map/pdftex/updmap/pdftex_dl14.map", "fonts/map/pdftex/updmap/pdftex_ndl14.map",
                   "web2c/updmap.log"]
        os.makedirs(os.path.join(self.root, "texmf-dist"), exist_ok=True)
        os.makedirs(os.path.join(self.root, "texmf-var"), exist_ok=True)
        write_lsr(os.path.join(self.root, "texmf-dist"), sorted(set(dist + gen_dist)))
        write_lsr(os.path.join(self.root, "texmf-var"), gen_var)
        self.write_cnf()
        # The installer's own code generates the config files from the database.
        for p in ("texlive.infra", "kpathsea", "hyphen-base", "texlive-scripts", "tex-ini-files"):
            self.unpack(p, pk[p])
        self.generate()
        print(f"{self.root}: {len(pk)} packages, {len(dist)} files listed, "
              f"{len(os.listdir(os.path.join(self.root, '.fetched')))} packages on disk", file=sys.stderr)

    def write_cnf(self):
        cnf = os.path.join(self.dir, "cnf")
        os.makedirs(cnf, exist_ok=True)
        with open(os.path.join(cnf, "texmf.cnf"), "w") as f:
            f.write(f"""% GPL-2.0-or-later. Read before TeX Live's own texmf.cnf (ROOT/texmf-dist/web2c), which it overrides:
% TeX Live {self.year} as installed at ROOT, with no user or local trees.
TEXMFROOT = {self.root}
TEXMFLOCAL = $TEXMFROOT/texmf-local
TEXMFHOME = $TEXMFROOT/texmf-home
TEXMFVAR = $TEXMFROOT/texmf-var
TEXMFCONFIG = $TEXMFROOT/texmf-config
""")

    def generate(self):
        root = self.root
        perl = f"""
use lib "{root}/tlpkg";
use TeXLive::TLPDB; use TeXLive::TLUtils;
my $db = TeXLive::TLPDB->new(root => "{root}") or die "no tlpdb";
TeXLive::TLUtils::create_language_dat($db, "{root}/texmf-var/tex/generic/config/language.dat", "");
TeXLive::TLUtils::create_language_def($db, "{root}/texmf-var/tex/generic/config/language.def", "");
TeXLive::TLUtils::create_language_lua($db, "{root}/texmf-var/tex/generic/config/language.dat.lua", "");
TeXLive::TLUtils::create_fmtutil($db, "{root}/texmf-dist/web2c/fmtutil.cnf");
TeXLive::TLUtils::create_updmap($db, "{root}/texmf-dist/web2c/updmap.cfg");
"""
        for d in ("texmf-var/tex/generic/config", "texmf-dist/web2c"):
            os.makedirs(os.path.join(root, d), exist_ok=True)
        subprocess.run(["perl", "-e", perl], check=True)

    def updmap(self, kpsewhich_dir):
        """pdftex.map and friends, by TeX Live's updmap; kpsewhich fetches each map file's package on demand."""
        env = {**os.environ, **self.env(), "PATH": f"{kpsewhich_dir}:{os.environ['PATH']}"}
        script = os.path.join(self.root, "texmf-dist/scripts/texlive/updmap.pl")
        subprocess.run(["perl", script, "--sys", "--nohash", "--quiet"], env=env, check=True,
                       stdin=subprocess.DEVNULL)


def main(a):
    if a[:1] == ["fetch"]:
        root = os.environ.get("TAUDOT_TL_ROOT")
        year = os.environ.get("TAUDOT_TL_YEAR")
        if not root or not year:
            return 1
        return Year(year).fetch(a[1])
    if a[:1] == ["store"]:
        Store(a[1]).setup()
        return 0
    if a[:1] == ["setup"]:
        Year(a[1]).setup()
        return 0
    if a[:1] == ["updmap"]:
        Year(a[1]).updmap(a[2])
        return 0
    if a[:1] == ["cost"]:  # cost YEAR FLS...: the packages a first compile would fetch, from pdfTeX's -recorder
        y = Year(a[1])
        sizes, cur = {}, None
        with open(os.path.join(y.root, "tlpkg", "texlive.tlpdb"), errors="replace") as f:
            for line in f:
                if line.startswith("name "):
                    cur = line[5:].strip()
                elif line.startswith("containersize ") and cur:
                    sizes[cur] = int(line.split()[1])
        pkgs = set()
        for fls in a[2:]:
            for line in open(fls, errors="replace"):
                if line.startswith("INPUT "):
                    p = os.path.realpath(line[6:].strip())
                    if p.startswith(y.root + "/"):
                        pkgs.add(y.owner(os.path.relpath(p, y.root)))
            n = sum(sizes.get(p, 0) for p in pkgs if p)
            print(f"{fls}: {len(pkgs)} packages, {n / 1e6:.1f} MB compressed (cumulative)")
        return 0
    if a[:1] == ["env"]:
        for k, v in source(a[1]).env(a[2] if len(a) > 2 else None).items():
            print(f"export {k}='{v}'")
        return 0
    print(__doc__ or "usage: tl.py setup|fetch|env|updmap", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
