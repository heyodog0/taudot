#!/bin/sh
# Checks out upstream TeXpresso at the pinned commit in DIR and applies our patch series as commits on branch
# `taudot`. DIR is cloned if missing. Safe to rerun: the branch is rebuilt from the pin each time.
# TeXpresso's Makefiles don't track headers, so when the result differs from the last run here (recorded in
# DIR/build/.taudot-head) the whole build/ is removed and the next `make all` starts clean.
#   sh clients/render/texpresso/apply.sh DIR
# TEXPRESSO_URL overrides the clone source (a local clone is faster).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
PIN=e8df770
URL="${TEXPRESSO_URL:-https://github.com/let-def/texpresso.git}"
[ $# -eq 1 ] || { echo "usage: $0 DIR" >&2; exit 2; }
D=$1
if [ ! -d "$D/.git" ]; then
  git clone -q "$URL" "$D"
fi
git -C "$D" cat-file -e "$PIN^{commit}" 2>/dev/null || git -C "$D" fetch -q origin
if [ -n "$(git -C "$D" status --porcelain --untracked-files=no)" ]; then
  echo "$D has local changes; commit or discard them first" >&2; exit 1
fi
git -C "$D" checkout -q -B taudot "$PIN"
set -- "$here"/patches/*.patch
[ -e "$1" ] || set --
[ $# -eq 0 ] || git -C "$D" -c user.name=taudot -c user.email=taudot@localhost am -q --committer-date-is-author-date "$@"
head=$(git -C "$D" rev-parse HEAD)
if [ "$(cat "$D/build/.taudot-head" 2>/dev/null)" != "$head" ]; then
  [ -d "$D/build" ] && echo "series changed: removing $D/build (make all rebuilds it)"
  rm -rf "$D/build"
  mkdir -p "$D/build"
  echo "$head" > "$D/build/.taudot-head"
fi
echo "applied $# patches to $D ($(git -C "$D" rev-parse --short HEAD) on $PIN)"
