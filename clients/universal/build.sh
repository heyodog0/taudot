#!/bin/sh
# MIT. Builds the interposer and the driver into BUILD (default $TAUDOT_REF/universal/bin).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
TAUDOT_REF=${TAUDOT_REF:-$HOME/code/lab/taudot-ref}
BIN=${BIN:-$TAUDOT_REF/universal/bin}
mkdir -p "$BIN"
cc -O2 -Wall -dynamiclib -undefined dynamic_lookup -o "$BIN/libtau.dylib" "$here/interpose/tau.c" "$here/interpose/zcache.c"
if [ -f "$here/driver/tau-live.c" ]; then cc -O2 -Wall -o "$BIN/tau-live" "$here/driver/tau-live.c"; fi
ls -l "$BIN"

# tau-tdl (readers/): TeXpresso's DVI interpreter and the renderer's runtime and TDL device, from clients/render (not
# modified, compiled into our own objects), and kpathsea from the engines' build.
R=$(cd "$here/../render" && pwd)
O=$TAUDOT_REF/universal/obj-tdl
K=$TAUDOT_REF/universal/build-2026-dz/texk
KS=$TAUDOT_REF/universal/src-2026/texk
BREW=$(brew --prefix)
CF="-O2 -g -w -I$R/rt -I$R/dvi -I$R/dvi/include -I$R/dvi/frontend -I$BREW/include $(pkg-config --cflags freetype2) -I$K -I$KS"
mkdir -p "$O"
set --
for s in dvi/dvi_context.c dvi/dvi_interp.c dvi/dvi_prim.c dvi/dvi_special.c dvi/dvi_scratch.c dvi/dvi_fonttable.c \
  dvi/dvi_resmanager.c dvi/tex_tfm.c dvi/tex_fontmap.c dvi/tex_vf.c dvi/tex_enc.c dvi/vstack.c dvi/pdf_lexer.c \
  dvi/frontend/incdvi.c dvi/frontend/myabort.c rt/fitz.c rt/fonts.c rt/apple.c fonts/taudot_font.c fonts/glyphlists.c; do
  o="$O/$(basename "$s" .c).o"
  set -- "$@" "$o"
  if [ ! -f "$o" ] || [ "$R/$s" -nt "$o" ]; then cc $CF -c -o "$o" "$R/$s" & fi
done
wait
cc $CF -c -o "$O/tau-tdl.o" "$here/readers/tau-tdl.c"
FT="$BREW/opt/freetype/lib/libfreetype.a $BREW/opt/libpng/lib/libpng16.a $BREW/opt/brotli/lib/libbrotlidec.a $BREW/opt/brotli/lib/libbrotlicommon.a"
cc -o "$BIN/tau-tdl" "$O/tau-tdl.o" "$@" "$K/kpathsea/.libs/libkpathsea.a" $FT -lz -lbz2 -lhvf \
  -framework CoreGraphics -framework ImageIO -framework CoreFoundation -framework CoreText
ls -l "$BIN/tau-tdl"

# tau-pdfmx (pdfmx/): xdvipdfmx kept resident. Links the stock build's dvipdfm-x objects, unmodified, with
# dvipdfmx.c compiled again with main renamed; the program is GPL as a whole (a separate program, like the engines).
D=$TAUDOT_REF/universal/build-2026/texk/dvipdfm-x
DS=$TAUDOT_REF/universal/src-2026/texk/dvipdfm-x
L=$TAUDOT_REF/universal/build-2026
DI="-DHAVE_CONFIG_H -I$D -I$DS -I$L/texk -I$TAUDOT_REF/universal/src-2026/texk -I$L/libs/libpng/include -I$L/libs/zlib/include -I$L/libs/libpaper/include"
mkdir -p "$O/pdfmx"
cc -g -O2 -w $DI -Dmain=dvipdfmx_stock_main -c -o "$O/pdfmx/dvipdfmx.o" "$DS/dvipdfmx.c"
cc -O2 -Wall $DI -c -o "$O/pdfmx/tau-pdfmx.o" "$here/pdfmx/tau-pdfmx.c"
cc -o "$BIN/tau-pdfmx" "$O/pdfmx/tau-pdfmx.o" "$O/pdfmx/dvipdfmx.o" $(ls "$D"/*.o | grep -v '/dvipdfmx\.o$') \
  "$L/texk/kpathsea/.libs/libkpathsea.a" "$L/libs/libpng/libpng.a" "$L/libs/zlib/libz.a" "$L/libs/libpaper/libpaper.a"
ls -l "$BIN/tau-pdfmx"
