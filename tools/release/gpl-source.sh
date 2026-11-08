#!/bin/sh
# The complete source of the GPL programs in Taudot.app (the live pdfTeX: pdftex, pdftex-live; BibTeX; universal's
# stock pdftex, xetex, luahbtex, xdvipdfmx, bibtex), for a release:
#   tools/release/gpl-source.sh VERSION OUTDIR [COMMIT]     → OUTDIR/taudot-gpl-source-VERSION.tar.gz
# It holds clients/pdftex at COMMIT (default HEAD: the release commit) — our patches for each TeX Live year, apply.sh
# (which names each TeX Live source release with its URL and SHA-512), build.sh and the driver — plus SOURCES.txt,
# which says how to rebuild the shipped binaries from it. The TeX Live source tarballs themselves are TeX Live's
# published releases; SOURCES.txt names them exactly. (If we ever must ship them too, add them here.)
set -eu
[ $# -ge 2 ] || { echo "usage: $0 VERSION OUTDIR [COMMIT]" >&2; exit 2; }
version=$1
out=$2
commit=${3:-HEAD}
repo=$(cd "$(dirname "$0")/../.." && pwd)
rev=$(git -C "$repo" rev-parse "$commit")
name="taudot-gpl-source-$version"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/$name" "$out"
git -C "$repo" archive --format=tar "$rev" clients/pdftex clients/render/bibtex \
  clients/universal/build-engines.sh clients/universal/build-formats.sh clients/universal/env.sh | tar -x -C "$tmp/$name"
cp "$repo/tools/release/COPYING-GPL-2" "$tmp/$name/COPYING"
{
  echo "Taudot $version: source of the GPL programs it ships"
  echo
  echo "Taudot.app/Contents/Resources/pdftex/<year>/ holds, per TeX Live year, pdftex (a modified pdfTeX),"
  echo "pdftex-live (its driver), bibtex and pdflatex.fmt; Taudot.app/Contents/Resources/bibtex/ holds BibTeX."
  echo "They are free software under the GNU General Public License, version 2 or later (COPYING)."
  echo
  echo "Taudot repository commit: $rev"
  echo
  echo "TeX Live source releases the patches apply to (from clients/pdftex/apply.sh, with their SHA-512):"
  sed -n 's/^ *\(20[0-9][0-9]\)) TAR=\(.*\)$/  \1: \2.tar.xz/p' "$repo/clients/pdftex/apply.sh"
  echo "  from https://ftp.math.utah.edu/pub/tex/historic/systems/texlive/<year>/"
  grep -E '^ *SHA=' "$repo/clients/pdftex/apply.sh" | sed 's/^ */  sha512 /; s/SHA=//; s/ *;;//'
  echo
  echo "To rebuild, for each YEAR in 2024 2025 2026:"
  echo "  SERIES=YEAR sh clients/pdftex/build.sh all"
  echo "(apply.sh fetches the TeX Live release, checks its SHA-512 and applies clients/pdftex/patches/YEAR/;"
  echo "clients/pdftex/README.md describes the patches and the build.)"
  echo
  echo "Taudot.app/Contents/Resources/universal/bin/ holds pdftex, xetex, luahbtex (run as pdflatex, xelatex,"
  echo "lualatex), xdvipdfmx and bibtex built WITHOUT changes from the TeX Live 2026 source release above"
  echo "(texlive-20260301-source.tar.xz, the same SHA-512), with TeX Live's own libraries; universal/fmt/ holds the"
  echo "formats those engines built. To rebuild: unpack that release, then"
  echo "  sh clients/universal/build-engines.sh     (configure flags and the zlib-as-a-dylib relink are in it)"
  echo "  sh clients/universal/build-formats.sh"
} > "$tmp/$name/SOURCES.txt"
tar -C "$tmp" -czf "$out/$name.tar.gz" "$name"
echo "$out/$name.tar.gz"
