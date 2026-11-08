#!/bin/sh
# GPL-2.0-or-later. Builds pdfTeX (and the driver) from TeX Live's source, out of tree:
#   stock: tag `stock` (apply.sh), a git worktree SRC-stock      -> BUILD/stock/texk/web2c/pdftex
#   live:  branch `taudot`, all of patches/SERIES               -> BUILD/live/texk/web2c/pdftex
#   SERIES=2025 sh clients/pdftex/build.sh [stock|live|driver|all]
# SERIES defaults to 2025: SRC ~/code/lab/taudot-ref/texlive-2025/src, BUILD ~/code/lab/taudot-ref/pdftex-build-2025.
# SERIES=trunk is Phase 1's: SRC ~/code/lab/taudot-ref/texlive-source, BUILD ~/code/lab/taudot-ref/pdftex-build.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
SERIES=${SERIES:-2025}
R=$HOME/code/lab/taudot-ref
case $SERIES in
trunk) SRC=${SRC:-$R/texlive-source} BUILD=${BUILD:-$R/pdftex-build} ;;
*)     SRC=${SRC:-$R/texlive-$SERIES/src} BUILD=${BUILD:-$R/pdftex-build-$SERIES} ;;
esac
what=${1:-all}
mkdir -p "$BUILD"

conf() { # SRCDIR BUILDDIR
  mkdir -p "$2"
  if [ ! -f "$2/Makefile" ]; then
    # --disable-all-pkgs turns web2c off too; turn it back on with only pdfTeX (and BibTeX, a web2c program).
    (cd "$2" && "$1/configure" -C --disable-all-pkgs --enable-web2c --enable-pdftex --disable-shared --without-x \
      --disable-tex --disable-etex --disable-ptex --disable-eptex --disable-uptex --disable-euptex --disable-aleph \
      --disable-hitex --disable-xetex --disable-luatex --disable-luajittex --disable-luahbtex --disable-luajithbtex \
      --disable-mf --disable-mf-nowin --disable-mflua --disable-mfluajit --disable-mp --disable-pmp --disable-upmp \
      --disable-native-texlive-build --enable-silent-rules > configure.log 2>&1) \
      || { tail -30 "$2/configure.log"; exit 1; }
  fi
  (cd "$2" && make -j"$(sysctl -n hw.ncpu)" > make.log 2>&1) || { tail -40 "$2/make.log"; exit 1; }
  ls -l "$2/texk/web2c/pdftex"
}

if [ "$what" = stock ] || [ "$what" = all ]; then
  sh "$here/apply.sh" "$SERIES" "$SRC" > /dev/null
  if [ -d "$SRC-stock" ]; then git -C "$SRC-stock" checkout -q --detach stock
  else git -C "$SRC" worktree add -q --detach "$SRC-stock" stock; fi
  conf "$SRC-stock" "$BUILD/stock"
fi
if [ "$what" = live ] || [ "$what" = all ]; then
  sh "$here/apply.sh" "$SERIES" "$SRC"
  conf "$SRC" "$BUILD/live"
fi
if [ "$what" = driver ] || [ "$what" = all ]; then
  cc -O2 -Wall -o "$BUILD/pdftex-live" "$here/live.c"
  ls -l "$BUILD/pdftex-live"
fi
