#!/bin/sh
# Fails if any Mach-O file in the app loads a library from outside the system and the bundle, or carries an rpath
# into the build machine, or if the bundle names a path on this Mac (the repo, ~/code, /opt/homebrew) in a script.
#   tools/release/audit.sh Taudot.app [--allow-agpl]
# Also lists AGPL libraries (MuPDF, jbig2dec): an error unless --allow-agpl (internal builds before nomupdf lands).
set -eu
app=$1
allow_agpl=${2:-}
bad=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
find "$app" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0 | xargs -0 file | grep 'Mach-O' | sed 's/ (for architecture.*//; s/:.*//' | sort -u > "$tmp/machos"
n=$(wc -l < "$tmp/machos" | tr -d ' ')
while IFS= read -r f; do
  otool -arch arm64 -L "$f" | tail -n +2 | awk '{print $1}' | while IFS= read -r l; do
    case "$l" in
      /System/*|/usr/lib/*|@rpath/*|@loader_path/*|@executable_path/*) ;;
      *) echo "audit: ${f#"$app"/} loads $l" ;;
    esac
  done
  otool -arch arm64 -l "$f" | awk '/LC_RPATH/ {getline; getline; print $2}' | while IFS= read -r r; do
    case "$r" in @loader_path*|@executable_path*) ;; *) echo "audit: ${f#"$app"/} has rpath $r" ;; esac
  done
done < "$tmp/machos" > "$tmp/out"
# Scripts and text that would send the app to this machine's files.
grep -rIl -e '/opt/homebrew' -e "$HOME/code" -e '/code/lab/' "$app/Contents" 2>/dev/null \
  | grep -v -e '/Acknowledgements' -e '\.md$' -e '/doc/' -e 'Resources/neovim/' -e 'Resources/nvim/doc' \
  | sed "s|^|audit: names a build path: |" >> "$tmp/out" || true
if [ -s "$tmp/out" ]; then cat "$tmp/out"; bad=1; fi
agpl=$(ls "$app/Contents/Frameworks" 2>/dev/null | grep -i -e mupdf -e jbig2dec || true)
if [ -n "$agpl" ]; then
  echo "audit: AGPL libraries in the bundle (txp-render still links MuPDF; the nomupdf agent removes it):" $agpl
  [ "$allow_agpl" = --allow-agpl ] || bad=1
fi
[ $bad = 0 ] && echo "audit: $n Mach-O files, all self-contained"
exit $bad
