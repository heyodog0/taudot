#!/bin/sh
# End-to-end check: pdfLaTeX on a copy of a project, in an empty TeX tree, every TeX Live file fetched from the
# store over HTTP and nothing from anywhere else.
#
#   tools/texstore/check-run.sh IMAGE PDFTEX PROJECT_DIR MAIN.tex WORK [BASE_URL]
#
# PDFTEX is a pdftex binary with kpathsea's fetch hook (clients/pdftex patch 0001) built for IMAGE. Without
# BASE_URL, tools/texstore/serve.py serves the local store on 127.0.0.1:8790 and logs each request. The project is
# copied into WORK (never touched in place). The fallback to svn is off: a file the store can't give fails the run.
# LOCAL_FMT=1: for an engine that isn't the image's own, dump a test-only format with it first (its inputs fetched
# from the store too) instead of using the store's format.
set -eu
IMAGE=$1 PDFTEX=$2 PROJ=$3 MAIN=$4 WORK=$5 BASE=${6:-}
HERE=$(cd "$(dirname "$0")" && pwd)
rm -rf "$WORK" && mkdir -p "$WORK/root" "$WORK/cnf" "$WORK/cache" "$WORK/bin"
if [ -z "$BASE" ]; then
  BASE=http://127.0.0.1:8790
  uv run --no-project python -I "$HERE/serve.py" 8790 --log "$WORK/server.log" > "$WORK/serve.out" 2>&1 &
  SERVER=$!
  trap 'kill $SERVER' EXIT
  sleep 1
fi
cat > "$WORK/cnf/texmf.cnf" <<EOF
TEXMFROOT = $WORK/root
TEXMFLOCAL = \$TEXMFROOT/texmf-local
TEXMFHOME = \$TEXMFROOT/texmf-home
TEXMFVAR = \$TEXMFROOT/texmf-var
TEXMFCONFIG = \$TEXMFROOT/texmf-config
TEXMFSYSVAR = \$TEXMFROOT/texmf-var
TEXMFSYSCONFIG = \$TEXMFROOT/texmf-config
EOF
ln -s "$PDFTEX" "$WORK/bin/pdflatex"
export TEXSTORE_URL=$BASE TEXSTORE_IMAGE=$IMAGE TEXSTORE_ROOT=$WORK/root TEXSTORE_CACHE=$WORK/cache \
  TEXSTORE_FALLBACK=0 TEXSTORE_LOG=$WORK/fetch.log
export TEXMFCNF="$WORK/cnf:$WORK/root/texmf-dist/web2c" TAUDOT_TL_FETCH=$HERE/tl-fetch
unset TEXINPUTS TEXFORMATS TAUDOT_TL_ROOT TAUDOT_TL_YEAR 2>/dev/null || true
t0=$(date +%s)
uv run --no-project python -I "$HERE/client.py" init
if [ "${LOCAL_FMT:-}" = 1 ]; then
  F=$WORK/root/texmf-var/web2c/pdftex
  mkdir -p "$F" && (cd "$F" && "$WORK/bin/pdflatex" -ini -jobname=pdflatex -progname=pdflatex \
    -interaction=batchmode -translate-file=cp227.tcx '*pdflatex.ini' > /dev/null 2>&1) || {
    echo "local format failed"; tail -20 "$F/pdflatex.log"; exit 1; }
  echo "local format: $(ls -la "$F/pdflatex.fmt" | awk '{print $5}') bytes, by $(head -1 "$F/pdflatex.log" | cut -c1-60)"
fi
cp -R "$PROJ" "$WORK/doc"
cd "$WORK/doc"
for pass in 1 2; do
  "$WORK/bin/pdflatex" -interaction=batchmode -recorder "$MAIN" > /dev/null 2>&1 || {
    echo "pdflatex pass $pass failed:"; tail -30 "${MAIN%.tex}.log"; exit 1; }
done
t1=$(date +%s)
echo "--- $(head -1 "${MAIN%.tex}.log")"
grep -m1 '^LaTeX2e' "${MAIN%.tex}.log" || true
grep -m1 'L3 programming layer' "${MAIN%.tex}.log" || true
echo "PDF: $(ls -la "${MAIN%.tex}.pdf" | awk '{print $5}') bytes, $(grep -c '' "${MAIN%.tex}.fls") recorder lines, $((t1 - t0)) s"
echo "fetch log: $(cut -f2 "$WORK/fetch.log" | sort | uniq -c | tr '\n' ' ')"
[ -f "$WORK/server.log" ] && echo "server: $(cut -f2 "$WORK/server.log" | sort | uniq -c | tr '\n' ' ')"
echo "files in the tree: $(find "$WORK/root" -type f | wc -l | tr -d ' '), $(du -sh "$WORK/root" | cut -f1)"
if grep -q fallback "$WORK/fetch.log"; then echo "FALLBACK USED"; exit 1; fi
# Every TeX Live file the run read came from the store: each is in the tree, and the tree only holds fetched files.
missing=0
for f in $(grep '^INPUT ' "${MAIN%.tex}.fls" | cut -c7- | grep "^$WORK/root/" | sort -u); do
  [ -f "$f" ] || missing=$((missing + 1))
done
echo "TeX Live inputs read: $(grep '^INPUT ' "${MAIN%.tex}.fls" | cut -c7- | grep -c "^$WORK/root/" ) lines, $missing missing"
