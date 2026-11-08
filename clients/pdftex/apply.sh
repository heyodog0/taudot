#!/bin/sh
# GPL-2.0-or-later. Puts TeX Live's source for a series in DIR and applies our patches as commits on branch `taudot`.
#   sh clients/pdftex/apply.sh SERIES DIR
# Series (patches/SERIES/):
#   trunk  texlive-source on GitHub at a pinned commit (pdfTeX 1.40.29): Phase 1's numbers
#   2026   the TeX Live 2026 release source, texlive-20260301-source.tar.xz (pdfTeX 1.40.29, as on Overleaf)
#   2025   the TeX Live 2025 release source, texlive-20250308-source.tar.xz (pdfTeX 1.40.27, as on Overleaf)
#   2024   the TeX Live 2024 release source, texlive-20240312-source.tar.xz (pdfTeX 1.40.26, as on Overleaf)
# Stock (unpatched typesetting) is tag `stock`: the base plus the kpathsea fetch patch where the series has one.
# Safe to rerun: the branch is rebuilt from the base.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
[ $# -eq 2 ] || { echo "usage: $0 SERIES DIR" >&2; exit 2; }
S=$1 D=$2
case $S in
trunk)
  PIN=73900753804455f80d9e04cbed39eea2b415968e
  URL="${TEXLIVE_URL:-https://github.com/TeX-Live/texlive-source.git}"
  [ -d "$D/.git" ] || git clone -q --depth 1 "$URL" "$D"
  git -C "$D" cat-file -e "$PIN^{commit}" 2>/dev/null || git -C "$D" fetch -q --depth 1 origin "$PIN"
  BASE=$PIN NSTOCK=0 ;;
2026|2025|2024)
  case $S in
  2026) TAR=texlive-20260301-source
    SHA=c2ea189fee82475e3013e5e6d7bdbbeef80fe33d3636b99b35bf7c8d0ff06b48dcc54d12f4c3959a0fc9e24b80f9c4878a417d4b55ef4880ff238aefbcf189a3 ;;
  2025) TAR=texlive-20250308-source
    SHA=0837c935488b96cfc8dd79f1298f283b467ab68b4163cee9cb04b79e80195982fdc5ae8a80058dc7d3e99206bfda8b3bdd11340425b08f60cbef70d5a0e22702 ;;
  2024) TAR=texlive-20240312-source
    SHA=e7ed4eb419da789f82d4295819ba72d10766398fd20c8675742fcec985851917b2005d259e4c9bb952790472855115644297d92257878882a66315cc940b9210 ;;
  esac
  URL=https://ftp.math.utah.edu/pub/tex/historic/systems/texlive/$S/$TAR.tar.xz
  if [ ! -d "$D/.git" ]; then
    P=$(dirname "$D")
    [ -f "$P/$TAR.tar.xz" ] || curl -sf -o "$P/$TAR.tar.xz" "$URL"
    [ "$(shasum -a 512 "$P/$TAR.tar.xz" | cut -d' ' -f1)" = "$SHA" ] || { echo "bad checksum: $P/$TAR.tar.xz" >&2; exit 1; }
    (cd "$P" && tar xJf "$TAR.tar.xz" && mv "$TAR" "$D")
    git -C "$D" init -q && git -C "$D" add -A
    git -C "$D" -c user.name=taudot -c user.email=taudot@localhost commit -qm "$TAR" && git -C "$D" tag release
  fi
  BASE=release NSTOCK=1 ;;
*) echo "unknown series $S" >&2; exit 2 ;;
esac
if [ -n "$(git -C "$D" status --porcelain --untracked-files=no)" ]; then
  echo "$D has local changes; commit or discard them first" >&2; exit 1
fi
git -C "$D" checkout -q -B taudot "$BASE"
set -- "$here/patches/$S"/*.patch
[ -e "$1" ] || set --
[ $# -eq 0 ] || git -C "$D" -c user.name=taudot -c user.email=taudot@localhost am -q --committer-date-is-author-date "$@"
git -C "$D" tag -f stock "taudot~$(($# - NSTOCK))" > /dev/null
echo "applied $# patches to $D ($(git -C "$D" rev-parse --short HEAD); stock $(git -C "$D" rev-parse --short stock))"
