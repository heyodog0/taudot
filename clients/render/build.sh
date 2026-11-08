#!/bin/sh
# Builds txp-render: driver.c (our copy of txp-headless.c), our verbs, and TeXpresso's interpreter copied into dvi/
# (dvi/README.md), on Taudot's own drawing runtime (rt/: no MuPDF) and font loader (fonts/: FreeType). Pages are drawn
# by TaudotRender (swift/), linked in as a static library. From a built TeXpresso clone it still takes the file
# providers (build/common/libcommon.a) and the engine binary (build/texpresso-xetex). Objects go to obj/.
set -e
cd "$(dirname "$0")"
V="$(pwd)/../../vendor/texpresso"
[ -d "$V" ] && D="$V" || D="$HOME/code/lab/taudot-ref/texpresso"
T="${TEXPRESSO_DIR:-$D}"
BREW="$(brew --prefix)"
# engine_tex.c: TXP_SNAPSHOT_MS is TeX time between snapshots (TeXpresso's default 500).
SNAP="${TXP_SNAPSHOT_MS:-500}"
CFLAGS="-O2 -g -fPIC -Irt -Idvi -Idvi/include -Idvi/frontend -I$BREW/include $(pkg-config --cflags freetype2)"
mkdir -p obj
SRCS="dvi/dvi_context.c dvi/dvi_interp.c dvi/dvi_prim.c dvi/dvi_special.c dvi/dvi_scratch.c dvi/dvi_fonttable.c
  dvi/dvi_resmanager.c dvi/tex_tfm.c dvi/tex_fontmap.c dvi/tex_vf.c dvi/tex_enc.c dvi/vstack.c dvi/pdf_lexer.c
  dvi/frontend/sprotocol.c dvi/frontend/state.c dvi/frontend/fs.c dvi/frontend/incdvi.c dvi/frontend/myabort.c
  dvi/frontend/engine_dvi.c dvi/frontend/engine_tex.c dvi/frontend/synctex.c dvi/frontend/prot_parser.c
  dvi/frontend/sexp_parser.c dvi/frontend/json_parser.c dvi/frontend/editor.c
  rt/fitz.c rt/fonts.c rt/apple.c fonts/taudot_font.c fonts/glyphlists.c"
set --
for s in $SRCS; do
  o="obj/$(basename "$s" .c).o"
  set -- "$@" "$o"
  if [ ! -f "$o" ] || [ "$s" -nt "$o" ] || [ -n "$(find dvi rt fonts -name '*.h' -newer "$o" | head -1)" ] || [ build.sh -nt "$o" ]; then
    rm -f "$o"; gcc $CFLAGS -DTXP_SNAPSHOT_MS="$SNAP" -c -o "$o" "$s" &
  fi
done
wait
for o in "$@"; do [ -f "$o" ] || { echo "build.sh: $o failed" >&2; exit 1; }; done
# TaudotRender, as a static library: the `render` verb draws tiles with it
(cd swift && swift build -c release --product TaudotRenderC >/dev/null) || { echo "build.sh: swift build failed" >&2; exit 1; }
gcc $CFLAGS -DXETEX_PATH="\"$T/build/texpresso-xetex\"" -c -o obj/txp-render.o txp-render.c
rm -f txp-render.new
# FreeType (and what it reads fonts with) linked in statically: txp-render needs only the system's libraries
FT_LIBS="$BREW/opt/freetype/lib/libfreetype.a $BREW/opt/libpng/lib/libpng16.a $BREW/opt/brotli/lib/libbrotlidec.a $BREW/opt/brotli/lib/libbrotlicommon.a"
for a in $FT_LIBS; do [ -f "$a" ] || FT_LIBS="$(pkg-config --libs freetype2)"; done
# swiftc links: it brings the Swift runtime TaudotRender needs
xcrun swiftc -o txp-render.new obj/txp-render.o "$@" "$T/build/common/libcommon.a" swift/.build/release/libTaudotRenderC.a \
  $FT_LIBS -lz -lbz2 -lhvf -lc++ -Xlinker -framework -Xlinker CoreGraphics -Xlinker -framework -Xlinker ImageIO \
  2>&1 | grep -v "warning: " || true
[ -x txp-render.new ] || exit 1
mv -f txp-render.new txp-render
echo built "$(pwd)/txp-render"
