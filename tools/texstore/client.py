"""Reference client for the TeX Live store (docs/texstore.md, "How a client resolves a path").

  client.py fetch PATH      put PATH (absolute, under the root) into the tree; exit 0 if it is there afterwards.
                            Usable as kpathsea's fetch hook: TAUDOT_TL_FETCH=tools/texstore/tl-fetch
  client.py init            put what kpathsea reads before any fetch can run into an empty root: TeX Live's
                            texmf.cnf and both ls-R files
  client.py index           print the index hash in use and its size
  client.py warm PKG ...    fetch every file of these packages (in parallel)

Environment:
  TEXSTORE_URL       the store's base URL (R2's public URL, or tools/texstore/serve.py)
  TEXSTORE_INDEX     the image index's SHA-512, pinned; else TEXSTORE_IMAGE=NAME@rREV asks images/NAME/rREV (once)
  TEXSTORE_ROOT      the tree (TEXMFROOT); default $TAUDOT_TL_ROOT
  TEXSTORE_CACHE     objects by hash, shared by every image (default ~/Library/Caches/taudot/texstore)
  TEXSTORE_FALLBACK  0: never fall back to TeX Live's svn (to prove a run used the store only)
  TEXSTORE_LOG       append one line per file: where it came from (store, fallback, cache)

The pdftex agent owns the real client (in clients/pdftex/); this one fixes the behaviour and tests the store.
"""
import bisect
import gzip
import hashlib
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

URL = os.environ.get("TEXSTORE_URL", "").rstrip("/")
ROOT = os.environ.get("TEXSTORE_ROOT") or os.environ.get("TAUDOT_TL_ROOT", "")
CACHE = os.path.expanduser(os.environ.get("TEXSTORE_CACHE", "~/Library/Caches/taudot/texstore"))
TIMEOUT = 10


def sha512(b):
    return hashlib.sha512(b).hexdigest()


def log(kind, what):
    p = os.environ.get("TEXSTORE_LOG")
    if p:
        with open(p, "a") as f:
            f.write(f"{time.time():.3f}\t{kind}\t{what}\n")


def write_atomic(path, b, mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.{os.getpid()}.part"
    with open(tmp, "wb") as f:
        f.write(b)
    if mode:
        os.chmod(tmp, mode)
    os.replace(tmp, path)


def http(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "taudot-texstore"}),
                                timeout=TIMEOUT) as r:
        return r.read()


def obj(h, what):
    """The content named `h`: from the cache, else the store. Checked before it is used or cached."""
    p = os.path.join(CACHE, "objects", h[:2], h)
    try:
        with open(p, "rb") as f:
            log("cache", what)
            return f.read()
    except FileNotFoundError:
        pass
    b = gzip.decompress(http(f"{URL}/files/{h}"))
    if sha512(b) != h:
        raise ValueError(f"{h[:16]}…: store returned the wrong content")
    write_atomic(p, b)
    log("store", what)
    return b


class Index:
    def __init__(self):
        h = os.environ.get("TEXSTORE_INDEX")
        if not h:  # the image's pointer, asked once and kept: the image never changes under a client
            name, _, rev = os.environ["TEXSTORE_IMAGE"].partition("@")
            ptr = os.path.join(CACHE, "images", name, rev)
            try:
                with open(ptr) as f:
                    h = f.read().strip()
            except FileNotFoundError:
                h = http(f"{URL}/images/{name}/{rev}").decode().strip()
                write_atomic(ptr, (h + "\n").encode())
        self.hash = h
        self.data = obj(h, f"index {h[:16]}")
        lines = self.data.split(b"\n")
        self.head, self.pkgs, self.paths, self.rows = {}, {}, [], []
        for line in lines:
            f = line.split(b"\t")
            if f[0] == b"F":
                self.paths.append(f[1])
                self.rows.append(f)
            elif f[0] == b"P":
                self.pkgs[f[1].decode()] = [x.decode() for x in f[2:]]
            elif len(f) > 1:
                self.head[f[0].decode()] = [x.decode() for x in f[1:]]
        if self.head.get("texstore", ["?"])[0] != "1":
            raise ValueError(f"index format {self.head.get('texstore')} not supported")

    def owner(self, rel):
        i = bisect.bisect_left(self.paths, rel.encode())
        if i < len(self.paths) and self.paths[i] == rel.encode():
            return self.rows[i][3].decode()
        return None

    def manifest(self, pkg):
        mh = self.pkgs[pkg][0]
        out = {}
        for line in obj(mh, f"manifest {pkg}").decode().splitlines():
            p, s, h, x = line.split("\t")
            out[p] = (int(s), h, x == "x")
        return out


def fallback(idx, rel, h):
    """The file from TeX Live's svn at the image's revision (`svn cat`, svn's public access), checked by hash."""
    if os.environ.get("TEXSTORE_FALLBACK") == "0":
        raise OSError("store failed and fallback is off")
    url, rev = idx.head["svn"][0], idx.head["svn"][1]
    if rel.startswith(("texmf-var/", "texmf-dist/ls-R")) or rel in ("texmf-dist/web2c/fmtutil.cnf",
                                                                     "texmf-dist/web2c/updmap.cfg"):
        raise OSError(f"{rel}: generated, only in the store")
    b = subprocess.run(["svn", "cat", "-r", rev, f"{url}/{rel}@{rev}"], capture_output=True, check=True,
                       timeout=60).stdout
    if sha512(b) != h:
        raise ValueError(f"{rel}: svn r{rev} has different content")
    write_atomic(os.path.join(CACHE, "objects", h[:2], h), b)
    log("fallback", f"{rel} from svn r{rev}")
    return b


def place(idx, man, pkg, rel):
    s, h, x = man[rel]
    try:
        b = obj(h, rel)
    except (OSError, ValueError) as e:
        print(f"texstore: {rel}: store: {e}; falling back to svn", file=sys.stderr)
        b = fallback(idx, rel, h)
    if len(b) != s:
        raise ValueError(f"{rel}: size {len(b)} != {s}")
    write_atomic(os.path.join(ROOT, rel), b, 0o755 if x else None)


def fetch(path):
    rel = os.path.relpath(os.path.abspath(path), os.path.abspath(ROOT))
    if rel.startswith(".."):
        return 1
    try:
        idx = Index()
    except (OSError, ValueError, KeyError) as e:
        print(f"texstore: no index for {os.environ.get('TEXSTORE_IMAGE') or os.environ.get('TEXSTORE_INDEX')}: {e}",
              file=sys.stderr)
        return 1
    pkg = idx.owner(rel)
    if not pkg:
        return 1  # not in TeX Live: no network
    try:
        place(idx, idx.manifest(pkg), pkg, rel)
    except (OSError, ValueError, subprocess.CalledProcessError) as e:
        print(f"texstore: {rel}: {e}", file=sys.stderr)
        return 1
    return 0 if os.path.exists(path) else 1


BOOT = ["texmf-dist/web2c/texmf.cnf", "texmf-dist/ls-R", "texmf-var/ls-R"]


def init():
    idx = Index()
    for rel in BOOT:
        pkg = idx.owner(rel)
        place(idx, idx.manifest(pkg), pkg, rel)
    print(f"{ROOT}: {', '.join(BOOT)} from image {' '.join(idx.head['image'])}")


def warm(pkgs):
    idx = Index()
    for pkg in pkgs:
        man = idx.manifest(pkg)
        with ThreadPoolExecutor(16) as ex:
            list(ex.map(lambda rel: place(idx, man, pkg, rel), man))
        print(f"{pkg}: {len(man)} files")


def main(a):
    if a[:1] == ["fetch"] and len(a) == 2:
        return fetch(a[1])
    if a[:1] == ["init"]:
        init()
        return 0
    if a[:1] == ["index"]:
        idx = Index()
        print(idx.hash, len(idx.data), len(idx.pkgs), len(idx.paths))
        return 0
    if a[:1] == ["warm"]:
        warm(a[1:])
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
