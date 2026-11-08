#!/bin/sh
# MIT. pdflatex.fmt, xelatex.fmt, lualatex.fmt built by the stock engines in BIN (fmtutil.cnf's lines), into FMT.
# TeX Live files missing from the tree are fetched through libtau (TAU_TLROOT, TEXSTORE_URL; see env.sh).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
. "$here/env.sh"
BIN=${BIN:-$UBIN}
FMT=${FMT:-$UFMT}
mkdir -p "$FMT"
cd "$FMT"
export DYLD_INSERT_LIBRARIES="$UBIN/libtau.dylib" TAU_PROJECT=/nonexistent
"$BIN/pdftex" -ini -jobname=pdflatex -progname=pdflatex -translate-file=cp227.tcx '*pdflatex.ini' > pdflatex.out 2>&1
"$BIN/xetex" -ini -jobname=xelatex -progname=xelatex -etex xelatex.ini > xelatex.out 2>&1
"$BIN/luahbtex" -ini -jobname=lualatex -progname=lualatex lualatex.ini > lualatex.out 2>&1
ls -l "$FMT"/*.fmt
