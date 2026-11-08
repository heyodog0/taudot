# GPL-2.0-or-later. Fills the flat TeX tree ($TAUDOT_TEXMF) from Tectonic's bundle, on demand.
#
#   uv run clients/pdftex/texmf/fetch.py NAME...           fetch these files if missing
#   uv run clients/pdftex/texmf/fetch.py --learn -- CMD...  run CMD (a pdftex run) with kpathsea debugging until
#                                                           no file it looked for is missing from the tree but
#                                                           present in the bundle
#
# The bundle is Tectonic's default (TeX Live 2023, ~135k files, one flat namespace). This stands in for Phase 2's
# per-year bundles; the TeX Live year doesn't matter for the go/no-go.
import concurrent.futures as cf
import glob
import os
import re
import subprocess
import sys

TEXMF = os.environ.get("TAUDOT_TEXMF") or sys.exit("set TAUDOT_TEXMF")


def bundle_names():
    idx = glob.glob(os.path.expanduser("~/Library/Caches/Tectonic/bundles/data/*.index"))
    if not idx:
        sys.exit("no Tectonic bundle index; run tectonic once")
    names = set()
    with open(idx[0]) as f:
        for line in f:
            names.add(line.split(" ", 1)[0])
    return names


def fetch_one(name):
    dst = os.path.join(TEXMF, name)
    if os.path.exists(dst):
        return None
    tmp = dst + ".part"
    with open(tmp, "wb") as out:
        r = subprocess.run(["tectonic", "-X", "bundle", "cat", name], stdout=out, stderr=subprocess.DEVNULL)
    if r.returncode != 0:
        os.unlink(tmp)
        return f"failed: {name}"
    os.rename(tmp, dst)
    return name


def fetch(names):
    os.makedirs(TEXMF, exist_ok=True)
    todo = [n for n in sorted(set(names)) if not os.path.exists(os.path.join(TEXMF, n))]
    got = []
    with cf.ThreadPoolExecutor(12) as ex:
        for r in ex.map(fetch_one, todo):
            if r:
                got.append(r)
    return got


SEARCH = re.compile(r"search\((?:x?names?=|files?=)?\[?([^\],)]*)")


def font_files():
    """pdfTeX reads font map, Type 1 and encoding files without kpathsea's fetch hooks: for every .tfm in the
    tree, the files its pdftex.map line names."""
    fetch(["pdftex.map"])
    tfms = {n[:-4] for n in os.listdir(TEXMF) if n.endswith(".tfm")}
    want = set()
    with open(os.path.join(TEXMF, "pdftex.map"), errors="replace") as f:
        for line in f:
            w = line.split()
            if w and w[0] in tfms:
                want.update(re.findall(r"<<?\[?([^\s\"]+)", line))
    return fetch(want)


def learn(cmd, rounds=12):
    have = bundle_names()
    for i in range(rounds):
        r = subprocess.run(cmd + [], env={**os.environ, "KPATHSEA_DEBUG": "32"}, stdout=subprocess.DEVNULL, stdin=subprocess.DEVNULL,
                           stderr=subprocess.PIPE, text=True, errors="replace")
        wanted = set()
        for m in SEARCH.finditer(r.stderr):
            for n in re.split(r"[ ,]+", m.group(1)):
                n = os.path.basename(n.strip())
                if n in have:
                    wanted.add(n)
        got = fetch(wanted) + font_files()
        print(f"learn round {i}: {len(wanted)} looked up in the bundle, {len(got)} fetched", file=sys.stderr)
        if not got:
            return r.returncode
    return 1


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["--learn"]:
        a = a[1:]
        if a[:1] == ["--"]:
            a = a[1:]
        sys.exit(learn(a))
    for n in fetch(a):
        print(n)
