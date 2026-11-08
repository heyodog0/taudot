#!/bin/sh
# MIT. Builds STOCK pdfTeX, XeTeX, LuaHBTeX (+ BibTeX, xdvipdfmx, makeindex) from TeX Live's release source,
# with no Taudot patches, out of tree:
#   SRC   ~/code/lab/taudot-ref/universal/src-2026  (git worktree of texlive-2026/src at tag `release`)
#   BUILD ~/code/lab/taudot-ref/universal/build-2026
set -eu
R=$HOME/code/lab/taudot-ref/universal
YEAR=${YEAR:-2026}
SRC=${SRC:-$R/src-$YEAR}
BUILD=${BUILD:-$R/build-$YEAR}
if [ ! -d "$SRC" ]; then
  git -C "$HOME/code/lab/taudot-ref/texlive-$YEAR/src" worktree add -q --detach "$SRC" release
fi
mkdir -p "$BUILD"
cd "$BUILD"
if [ ! -f Makefile ]; then
  "$SRC/configure" -C --disable-all-pkgs --enable-web2c --enable-pdftex --enable-xetex --enable-luahbtex \
    --enable-dvipdfm-x --enable-makeindexk --disable-shared --without-x \
    --disable-tex --disable-etex --disable-ptex --disable-eptex --disable-uptex --disable-euptex --disable-aleph \
    --disable-hitex --disable-luatex --disable-luajittex --disable-luajithbtex --disable-mflua --disable-mfluajit \
    --disable-mf --disable-mf-nowin --disable-mp --disable-pmp --disable-upmp \
    --disable-native-texlive-build --enable-silent-rules > configure.log 2>&1 || { tail -30 configure.log; exit 1; }
fi
# ICU 77 headers need C++17; web2c asks for C++11 (XeTeX)
J=$(sysctl -n hw.ncpu)
make -j$J > make.log 2>&1 || \
  { (cd texk/web2c && make -j$J CXXFLAGS="-g -O2 -std=c++17") >> make.log 2>&1 && make -j$J >> make.log 2>&1; } || \
  { tail -40 make.log; exit 1; }
ls -l texk/web2c/pdftex texk/web2c/xetex texk/web2c/luahbtex texk/web2c/bibtex texk/dvipdfm-x/xdvipdfmx

# The same engines linked against TeX Live's own zlib as a dylib (same source, same bytes): deflate becomes a dylib
# call, so libtau can cache compressed streams across rollbacks (docs/universal.md, "zcache").
if [ "${DZ:-1}" = 1 ]; then
  Z=$R/zlib-$YEAR
  mkdir -p "$Z/include"
  if [ ! -f "$Z/libz.dylib" ]; then
    cp "$BUILD"/libs/zlib/include/zlib.h "$BUILD"/libs/zlib/include/zconf.h "$Z/include/"
    (cd "$SRC/libs/zlib/zlib-src" && cc -O2 -fPIC -DZ_HAVE_UNISTD_H -DHAVE_UNISTD_H -I"$Z/include" -dynamiclib -install_name "$Z/libz.dylib" \
      -o "$Z/libz.dylib" adler32.c compress.c crc32.c deflate.c gzclose.c gzlib.c gzread.c gzwrite.c infback.c \
      inffast.c inflate.c inftrees.c trees.c uncompr.c zutil.c)
  fi
  mkdir -p "$BUILD-dz"
  cd "$BUILD-dz"
  if [ ! -f Makefile ]; then
    "$SRC/configure" -C --disable-all-pkgs --enable-web2c --enable-pdftex --enable-xetex --enable-luahbtex \
      --enable-dvipdfm-x --enable-makeindexk --disable-shared --without-x --with-system-zlib \
      ZLIB_INCLUDES="-I$Z/include" ZLIB_LIBS="-L$Z -lz" \
      --disable-tex --disable-etex --disable-ptex --disable-eptex --disable-uptex --disable-euptex --disable-aleph \
      --disable-hitex --disable-luatex --disable-luajittex --disable-luajithbtex --disable-mflua --disable-mfluajit \
      --disable-mf --disable-mf-nowin --disable-mp --disable-pmp --disable-upmp \
      --disable-native-texlive-build --enable-silent-rules > configure.log 2>&1 || { tail -30 configure.log; exit 1; }
  fi
  make -j$J > make.log 2>&1 || \
    { (cd texk/web2c && make -j$J CXXFLAGS="-g -O2 -std=c++17") >> make.log 2>&1 && make -j$J >> make.log 2>&1; } || \
    { tail -40 make.log; exit 1; }
  # configure keeps ZLIB_LIBS=-lz (the system's 1.2.12): relink the engines against ours
  (cd texk/web2c && rm -f pdftex xetex luahbtex bibtex && \
    make -j$J ZLIB_LIBS="-L$Z -lz" CXXFLAGS="-g -O2 -std=c++17" pdftex xetex luahbtex bibtex) >> make.log 2>&1
  otool -L texk/web2c/pdftex | grep libz
fi
