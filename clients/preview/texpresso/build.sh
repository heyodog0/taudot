#!/bin/sh
# Builds txp-headless against a built TeXpresso clone (make all in $TEXPRESSO_DIR first).
set -e
cd "$(dirname "$0")"
V="$(pwd)/../../../vendor/texpresso"
[ -d "$V" ] && D="$V" || D="$HOME/code/lab/taudot-ref/texpresso"
T="${TEXPRESSO_DIR:-$D}"
B="$T/build/frontend"
BREW="$(brew --prefix)"
OBJS="sprotocol.o state.o fs.o incdvi.o myabort.o engine_pdf.o engine_dvi.o synctex.o prot_parser.o sexp_parser.o json_parser.o editor.o"
set --
for o in $OBJS; do set -- "$@" "$B/$o"; done
EXTRA="$(cd "$T" && CC=gcc ./mupdf-config.sh -L"$BREW/lib" 2>/dev/null)"
# engine_tex.c is compiled here: TXP_SNAPSHOT_MS (TeX time between snapshots, TeXpresso's default 500) needs the
# one-line patch in the clone that turns its constant into this macro.
SNAP="${TXP_SNAPSHOT_MS:-500}"
gcc -O2 -g -c -o engine_tex.o -DTXP_SNAPSHOT_MS="$SNAP" -I. -I"$BREW/include" -I"$T/src/dvi" -I"$T/src/include" \
  "$T/src/frontend/engine_tex.c"
set -- "$@" engine_tex.o
gcc -O2 -g -DXETEX_PATH="\"$T/build/texpresso-xetex\"" -o txp-headless txp-headless.c "$@" "$B/libmydvi.a" "$T/build/common/libcommon.a" \
  -I"$T/src/frontend" -I"$T/src/dvi" -I"$T/src/include" -I"$BREW/include" \
  -L"$BREW/lib" -lmupdf $EXTRA -lz -ljpeg -lharfbuzz -lfreetype -lSDL2 -lm -lc++
echo built "$(pwd)/txp-headless"
