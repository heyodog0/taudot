#!/bin/sh
# AGPL-3.0-or-later. Builds everything the benchmark runs, from source, into $BENCH_DIR (default
# ~/code/lab/taudot-ref/bench), outside the repo. Shallow clones; build trees removed once the binaries are out.
# Needs: TeX Live 2026's store tree and stock engines (clients/universal/build-engines.sh, build-formats.sh),
# Homebrew's mupdf, sdl2, pkgconf, cmake; rustup.
#   sh bench/build.sh [taudot|rtex|typst|texpresso|rosina|tl|all]
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
R=${TAUDOT_REF:-$HOME/code/lab/taudot-ref}
B=${BENCH_DIR:-$R/bench}
S=$B/src O=$B/build
mkdir -p "$S" "$O/bin"
what=${1:-all}
clone() { [ -d "$S/$2" ] || git clone -q --depth 1 ${3:+--branch "$3"} "https://github.com/$1.git" "$S/$2"; }

if [ "$what" = taudot ] || [ "$what" = all ]; then
  # patched pdfTeX from this checkout's patches, on TeX Live 2026's release source (a detached worktree, removed after)
  W=$O/texlive-src
  git -C "$R/texlive-2026/src" worktree add -q --detach "$W" release
  git -C "$W" -c user.name=taudot -c user.email=taudot@localhost am -q "$here"/clients/pdftex/patches/2026/*.patch
  mkdir -p "$O/pdftex"
  (cd "$O/pdftex" && "$W/configure" -C --disable-all-pkgs --enable-web2c --enable-pdftex --disable-shared --without-x \
    --disable-tex --disable-etex --disable-ptex --disable-eptex --disable-uptex --disable-euptex --disable-aleph \
    --disable-hitex --disable-xetex --disable-luatex --disable-luajittex --disable-luahbtex --disable-luajithbtex \
    --disable-mf --disable-mf-nowin --disable-mflua --disable-mfluajit --disable-mp --disable-pmp --disable-upmp \
    --disable-native-texlive-build --enable-silent-rules > configure.log 2>&1 && make -j"$(sysctl -n hw.ncpu)" > make.log 2>&1)
  ln -sf pdftex "$O/pdftex/texk/web2c/pdflatex"
  git -C "$R/texlive-2026/src" worktree remove --force "$W"
  rm -rf "$O/pdftex/libs" "$O/pdftex/utils" "$O/pdftex/auxdir"
  cc -O2 -o "$O/pdftex-live" "$here/clients/pdftex/live.c"
  . "$here/clients/universal/env.sh"
  unset TAU_TLROOT TEXSTORE_URL
  mkdir -p "$O/fmt-pdftex"
  (cd "$O/fmt-pdftex" && "$O/pdftex/texk/web2c/pdftex" -ini -jobname=pdflatex -progname=pdflatex \
    -translate-file=cp227.tcx '*pdflatex.ini' < /dev/null > /dev/null)
  # libtau, tau-live, tau-tdl from this checkout (objects in our own folder)
  mkdir -p "$O/universal"
  sed -e "s|^here=.*|here=$here/clients/universal|" -e "s|^O=.*|O=$O/obj-tdl|" "$here/clients/universal/build.sh" \
    | BIN=$O/universal sh -s
fi
if [ "$what" = rtex ] || [ "$what" = all ]; then
  clone HenryXiaoYang/realtime-tex realtime-tex
  (cd "$S/realtime-tex" && cargo +1.90 build --release -q && cp target/release/rtex "$O/bin/" && rm -rf target)
fi
if [ "$what" = typst ] || [ "$what" = all ]; then
  clone typst/typst typst v0.15.1
  rustup toolchain install 1.92 --profile minimal > /dev/null
  (cd "$S/typst" && cargo +1.92 build --release -q -p typst-cli && cp target/release/typst "$O/bin/" && rm -rf target)
fi
if [ "$what" = texpresso ] || [ "$what" = all ]; then
  clone let-def/texpresso texpresso
  T=$S/texpresso BREW=$(brew --prefix)
  (cd "$T" && make config > /dev/null && make -j8 all > /dev/null)
  mkdir -p "$O/txp"
  set --
  for o in sprotocol.o state.o fs.o incdvi.o myabort.o engine_pdf.o engine_dvi.o synctex.o prot_parser.o \
    sexp_parser.o json_parser.o editor.o; do set -- "$@" "$T/build/frontend/$o"; done
  gcc -O2 -c -o "$O/txp/engine_tex.o" -I"$BREW/include" -I"$T/src/dvi" -I"$T/src/include" "$T/src/frontend/engine_tex.c"
  # shellcheck disable=SC2046
  gcc -O2 -DXETEX_PATH="\"$T/build/texpresso-xetex\"" -o "$O/txp/txp-headless" \
    "$here/clients/preview/texpresso/txp-headless.c" "$@" "$O/txp/engine_tex.o" "$T/build/frontend/libmydvi.a" \
    "$T/build/common/libcommon.a" -I"$T/src/frontend" -I"$T/src/dvi" -I"$T/src/include" -I"$BREW/include" \
    -L"$BREW/lib" -lmupdf $(cd "$T" && CC=gcc ./mupdf-config.sh -L"$BREW/lib") -lz -ljpeg -lharfbuzz -lfreetype -lSDL2 \
    -lm -lc++
  # Overleaf's TeX Live image lacks kanjix.map and ckx.map, which TeXpresso's DVI reader insists on: empty ones
  X=$O/txp/texmf
  mkdir -p "$X/fonts/map/dvipdfmx"
  : > "$X/fonts/map/dvipdfmx/kanjix.map"
  : > "$X/fonts/map/dvipdfmx/ckx.map"
  printf '%% ls-R -- filename database for kpathsea; do not change this line.\n./fonts/map/dvipdfmx:\nckx.map\nkanjix.map\n' \
    > "$X/ls-R"
fi
if [ "$what" = rosina ] || [ "$what" = all ]; then
  clone PetalAdrift/liveTeX-Rosina liveTeX-Rosina
  (cd "$S/liveTeX-Rosina" && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ > /dev/null && cmake --build build --parallel > /dev/null && rm -rf build/_deps build/CMakeFiles)
fi
if [ "$what" = tl ] || [ "$what" = all ]; then
  # TeX Live's layout over the store tree, for the systems that find TeX through PATH (engines as real files:
  # Rosina finds the tree three levels above the binary)
  TL=$O/tl U=$R/universal
  mkdir -p "$TL/bin/aarch64-darwin"
  for e in pdflatex xelatex lualatex pdftex xetex luahbtex; do cp -L "$U/bin-static/$e" "$TL/bin/aarch64-darwin/$e"; done
  ln -sf luahbtex "$TL/bin/aarch64-darwin/luatex"
  ln -sf "$U/bin-static/bibtex" "$TL/bin/aarch64-darwin/bibtex"
  ln -sf "$U/bin/xdvipdfmx" "$TL/bin/aarch64-darwin/xdvipdfmx"
  ln -sf "$U/build-2026/texk/kpathsea/kpsewhich" "$TL/bin/aarch64-darwin/kpsewhich"
  ln -sf "$U/build-2026/texk/web2c/synctex" "$TL/bin/aarch64-darwin/synctex"
  for f in texmf-dist texmf-var; do ln -sfn "$R/texlive-2026/store-root/$f" "$TL/$f"; done
  ln -sf "$R/texlive-2026/store-root-cnf/texmf.cnf" "$TL/texmf.cnf"
  . "$here/clients/universal/env.sh"
  (cd "$here" && uv run tools/texstore/client.py warm lm currfile preview filehook kvoptions > /dev/null)
fi
du -sh "$B"
