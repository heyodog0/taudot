"""Shared pieces of the TeX Live store: paths, TeX Live's svn, the store's object format (docs/texstore.md)."""
import gzip
import hashlib
import os
import re
import subprocess
import time

REF = os.path.expanduser(os.environ.get("TEXSTORE_REF", "~/code/lab/taudot-ref/texstore"))
STORE = os.path.join(REF, "store")   # what goes to R2: files/<sha512>, images/<name>/r<rev>
WORK = os.path.join(REF, "work")     # per-image build state, never uploaded

SVN = "svn://tug.org/texlive/trunk/Master"  # TeX Live's public Subversion access; tlnet is built from it daily


def parse_image(spec):
    """NAME@rREV, e.g. 2026.1@r79413: an Overleaf TeX Live image name and the svn revision of TeX Live it matches."""
    name, _, rev = spec.partition("@")
    if not re.fullmatch(r"[0-9A-Za-z._-]+", name) or not re.fullmatch(r"r\d+", rev):
        raise SystemExit(f"bad image {spec!r}: want NAME@rREV, e.g. 2026.1@r79413")
    return name, int(rev[1:])


def svn(*args, out=None):
    """Run svn; return stdout bytes (or write to `out`). Retries, since a long export can drop."""
    for i in range(3):
        if out:
            with open(out, "wb") as f:
                r = subprocess.run(["svn", *args], stdout=f, stderr=subprocess.PIPE)
        else:
            r = subprocess.run(["svn", *args], capture_output=True)
        if r.returncode == 0:
            return r.stdout
        err = r.stderr.decode(errors="replace").strip()
        if i == 2:
            raise OSError(f"svn {' '.join(args)}: {err}")
        print(f"svn {' '.join(args[:3])}: {err}; retrying", flush=True)
        time.sleep(5 * (i + 1))


FORMAT = 1  # docs/texstore.md, "Versions"


def sha512(b):
    return hashlib.sha512(b).hexdigest()


def pack(b):
    """A store object's bytes: gzip, level 9, no name, mtime 0, so the same content always packs the same."""
    return gzip.compress(b, 9, mtime=0)


def object_path(h, store=STORE):
    return os.path.join(store, "files", h)


def put(b, store=STORE):
    """Store content `b` under its hash. Returns (hash, packed size, new)."""
    h = sha512(b)
    p = object_path(h, store)
    if os.path.exists(p):
        return h, os.path.getsize(p), False
    z = pack(b)
    tmp = f"{p}.{os.getpid()}.part"
    with open(tmp, "wb") as f:
        f.write(z)
    os.replace(tmp, p)
    return h, len(z), True


def get(h, store=STORE):
    with open(object_path(h, store), "rb") as f:
        b = gzip.decompress(f.read())
    if sha512(b) != h:
        raise ValueError(f"{h}: content does not match its name")
    return b


def read_tsv(path):
    with open(path, encoding="utf-8") as f:
        return [line.rstrip("\n").split("\t") for line in f if line.strip() and not line.startswith("#")]
