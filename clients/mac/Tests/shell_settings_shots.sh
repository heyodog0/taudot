#!/bin/sh
# Settings, every page, light and dark (the Taudot palette on Liquid Glass), plus
# the Reduce Transparency fallback (TAUDOT_REDUCE_TRANSPARENCY=1) of two pages, a sheet of them all, and a side-by-side
# with the Projects window (home_shots.sh's home-list-*.png) so they read as one family. taudot-app
# (CONFIG=debug|release) off screen (TAUDOT_SETTINGSSHOT); the previews' theme and font pinned by read-only launch
# arguments (nothing is written to the user's settings). Window captures into OUT (default /tmp/txs-settings-final).
#   swift build --product taudot-app && clients/mac/Tests/shell_settings_shots.sh [OUT]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MAC=$(cd "$HERE/.." && pwd)
REPO=$(cd "$MAC/../.." && pwd)
. "$HERE/shell_lib.sh"
OUT=${1:-/tmp/txs-settings-final}; mkdir -p "$OUT"
W=$(mktemp -d)
on_exit 'rm -rf "$W"'
FONT=${SHOT_FONT:-Menlo}
shot() {  # page look reduce name
  rm -f "$W/win"
  theme=dusk; [ $2 = light ] && theme=paper
  TAUDOT_SETTINGSSHOT=$1 TAUDOT_SETTINGS_APPEARANCE=$2 TAUDOT_REDUCE_TRANSPARENCY=$3 TAUDOT_SETTINGS_WINFILE="$W/win" \
    TAUDOT_NO_PREWARM=1 "$APP_BIN" \
    -taudot.editorTheme $theme -taudot.fontFamily "$FONT" -taudot.fontSize 13 \
    -taudot.commentStyle tint -taudot.showResolved NO -taudot.floatingCards YES -taudot.vimKeys NO -taudot.editorMode neovim \
    -taudot.appearance system -taudot.accent system -taudot.pdfMarkColor accent -taudot.pdfPage white \
    -taudot.pdfHighlightFollows NO -taudot.pdfComments YES -taudot.comments.connectors selected -taudot.maxTextWidth 0 \
    >"$W/app.log" 2>&1 &
  started $!
  i=0; while [ ! -s "$W/win" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.1; done
  N=$(cat "$W/win" 2>/dev/null)
  [ -n "$N" ] || { echo "FAIL: no window for $4"; tail -5 "$W/app.log"; exit 1; }
  screencapture -x -o -l"$N" "$OUT/$4.png"
  echo "$OUT/$4.png"
  stop_all
}
for look in light dark; do
  for page in Appearance Editor PDF Comments Account; do
    shot $page $look 0 "$(echo $page | tr A-Z a-z)-$look"
  done
  shot Editor $look 1 "editor-$look-solid"
  shot Comments $look 1 "comments-$look-solid"
done
uv run --no-project --with pillow python -I "$HERE/shell_settings_sheet.py" "$OUT" "$REPO/docs/agents/home-shots"
