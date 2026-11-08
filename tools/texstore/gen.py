"""Make an image's generated files, as TeX Live's installer would, in a tree unpacked from the store (so this also
checks the store), then add them to the image with `build.py gen`.

  uv run --no-project python -I tools/texstore/gen.py IMAGE ENGINE_BUILD [--keep]

ENGINE_BUILD is a web2c build directory holding texk/web2c/pdftex and texk/kpathsea/kpsewhich: the image's own
pdfTeX, since a format only loads in the engine that dumped it. Makes:
  - fmtutil.cnf, updmap.cfg, language.dat/.def/.dat.lua, from TeX Live's own TLUtils.pm and the snapshot's tlpdb;
  - pdftex.map and the other updmap outputs, by TeX Live's updmap.pl;
  - pdflatex.fmt, by fmtutil.cnf's command line, with SOURCE_DATE_EPOCH at the revision's commit time
    (reproducible).
The tree (work/IMAGE/tree) leaves out font outlines and bitmaps, which none of these read, and is removed afterwards
unless --keep.
"""
import datetime
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build  # noqa: E402
import texstore as ts  # noqa: E402

SKIP = (".pfb", ".pfm", ".afm", ".otf", ".ttf", ".ttc", ".pk", ".woff", ".woff2", ".pdf", ".png", ".jpg", ".eps")
GEN_VAR = ["tex/generic/config/language.dat", "tex/generic/config/language.def", "tex/generic/config/language.dat.lua",
           "fonts/map/pdftex/updmap/pdftex.map", "fonts/map/pdftex/updmap/pdftex_dl14.map",
           "fonts/map/pdftex/updmap/pdftex_ndl14.map", "fonts/map/dvips/updmap/psfonts.map",
           "fonts/map/dvips/updmap/psfonts_t1.map", "fonts/map/dvips/updmap/psfonts_pk.map",
           "fonts/map/dvips/updmap/download35.map", "fonts/map/dvips/updmap/builtin35.map",
           "fonts/map/dvipdfmx/updmap/kanjix.map"]
GEN_DIST = ["web2c/fmtutil.cnf", "web2c/updmap.cfg"]


def write_lsr(top):
    paths = []
    for d, _, files in os.walk(top):
        paths += [os.path.relpath(os.path.join(d, f), top) for f in files if f != "ls-R"]
    with open(os.path.join(top, "ls-R"), "wb") as f:
        f.write(build.lsr(sorted(paths)))


def main(a):
    if len(a) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    im, eng = build.Image(a[0]), os.path.abspath(a[1])
    root = os.path.join(im.dir, "tree")
    shutil.rmtree(root, ignore_errors=True)
    n = 0
    for name, (_, rows) in build.load_image(im).items():
        if name == build.GEN:
            continue
        for p, s, h, x in rows:
            if p.lower().endswith(SKIP):
                continue
            out = os.path.join(root, p)
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, "wb") as f:
                f.write(ts.get(h))
            if x:
                os.chmod(out, 0o755)
            n += 1
    print(f"{n} files unpacked from the store into {root}", flush=True)
    os.makedirs(os.path.join(root, "tlpkg"), exist_ok=True)
    shutil.copy(im.tlpdb_path(), os.path.join(root, "tlpkg", "texlive.tlpdb"))
    for d in ("texmf-var/tex/generic/config", "texmf-dist/web2c", "texmf-var/web2c"):
        os.makedirs(os.path.join(root, d), exist_ok=True)

    cnf = os.path.join(im.dir, "cnf")
    os.makedirs(cnf, exist_ok=True)
    with open(os.path.join(cnf, "texmf.cnf"), "w") as f:
        f.write(f"TEXMFROOT = {root}\nTEXMFLOCAL = $TEXMFROOT/texmf-local\nTEXMFHOME = $TEXMFROOT/texmf-home\n"
                f"TEXMFVAR = $TEXMFROOT/texmf-var\nTEXMFCONFIG = $TEXMFROOT/texmf-config\n"
                f"TEXMFSYSVAR = $TEXMFROOT/texmf-var\nTEXMFSYSCONFIG = $TEXMFROOT/texmf-config\n")
    when = ts.svn("log", "-q", "-r", str(im.rev), ts.SVN).decode().splitlines()[1].split(" | ")[2][:25]
    epoch = str(int(datetime.datetime.strptime(when, "%Y-%m-%d %H:%M:%S %z").timestamp()))
    env = {**os.environ, "TEXMFCNF": f"{cnf}:{root}/texmf-dist/web2c",
           "PATH": f"{eng}/texk/kpathsea:{eng}/texk/web2c:{os.environ['PATH']}",
           "SOURCE_DATE_EPOCH": epoch, "FORCE_SOURCE_DATE": "1"}
    for k in ("TAUDOT_TL_FETCH", "TEXINPUTS", "TEXFORMATS", "TEXMFHOME"):
        env.pop(k, None)
    # 1. Configs from the tlpdb, by TeX Live's own code. (Single quotes: the path has an @ that Perl would expand.)
    subprocess.run(["perl", "-e", f"""
use lib '{root}/tlpkg'; use TeXLive::TLPDB; use TeXLive::TLUtils;
my $db = TeXLive::TLPDB->new(root => '{root}') or die "no tlpdb";
TeXLive::TLUtils::create_language_dat($db, '{root}/texmf-var/tex/generic/config/language.dat', '');
TeXLive::TLUtils::create_language_def($db, '{root}/texmf-var/tex/generic/config/language.def', '');
TeXLive::TLUtils::create_language_lua($db, '{root}/texmf-var/tex/generic/config/language.dat.lua', '');
TeXLive::TLUtils::create_fmtutil($db, '{root}/texmf-dist/web2c/fmtutil.cnf');
TeXLive::TLUtils::create_updmap($db, '{root}/texmf-dist/web2c/updmap.cfg');
"""], env=env, check=True)

    write_lsr(os.path.join(root, "texmf-dist"))
    write_lsr(os.path.join(root, "texmf-var"))

    # 2. Font maps, by TeX Live's updmap.pl.
    subprocess.run(["perl", f"{root}/texmf-dist/scripts/texlive/updmap.pl", "--sys", "--nohash", "--quiet"],
                   env=env, check=True, stdin=subprocess.DEVNULL)
    write_lsr(os.path.join(root, "texmf-var"))

    # 3. The format, as fmtutil.cnf says (pdflatex pdftex language.dat -translate-file=cp227.tcx *pdflatex.ini).
    line = next(ln for ln in open(f"{root}/texmf-dist/web2c/fmtutil.cnf") if ln.startswith("pdflatex pdftex "))
    print("fmtutil.cnf:", line.strip(), flush=True)
    fmtdir = os.path.join(root, "texmf-var", "web2c", "pdftex")
    os.makedirs(fmtdir, exist_ok=True)
    os.symlink(f"{eng}/texk/web2c/pdftex", os.path.join(im.dir, "pdflatex")) if not os.path.lexists(
        os.path.join(im.dir, "pdflatex")) else None
    args = line.split()[3:]
    r = subprocess.run([os.path.join(im.dir, "pdflatex"), "-ini", "-jobname=pdflatex", "-progname=pdflatex",
                        "-interaction=nonstopmode", *args], cwd=fmtdir, env=env, capture_output=True, text=True)
    if r.returncode or not os.path.exists(os.path.join(fmtdir, "pdflatex.fmt")):
        print(r.stdout[-3000:])
        sys.exit("format build failed")
    banner = subprocess.run([f"{eng}/texk/web2c/pdftex", "--version"], capture_output=True, text=True).stdout
    print(banner.splitlines()[0], flush=True)
    with open(os.path.join(im.dir, "engine.txt"), "w") as f:
        f.write(f"{eng}\n{banner.splitlines()[0]}\n")

    pairs = [f"texmf-var/{p}={root}/texmf-var/{p}" for p in GEN_VAR if os.path.exists(f"{root}/texmf-var/{p}")]
    pairs += [f"texmf-dist/{p}={root}/texmf-dist/{p}" for p in GEN_DIST]
    pairs += [f"texmf-var/web2c/pdftex/pdflatex.fmt={fmtdir}/pdflatex.fmt"]
    build.cmd_gen(im, pairs)
    if "--keep" not in a:
        shutil.rmtree(root)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
