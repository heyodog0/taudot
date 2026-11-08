#!/bin/sh
# Cycling through comments with real keys (TAUDOT_CYCLECHECK): ⌥⌘↓/↑, the review bar, ]r/[r, in one editor mode.
# taudot-app on a COPY of FILE.tex with the mock engine. Opt-in (TAUDOT_ONSCREEN=1): brings the app to the front for ~10 s.
#   swift build --product taudot-app && clients/mac/Tests/review_cycle.sh FILE.tex native-vim|native|neovim
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/review_lib.sh"
txs_onscreen_only "HID-level keys with the window in front"
MAC=$(cd "$HERE/.." && pwd)
REPO=$(cd "$MAC/../.." && pwd)
W=$(mktemp -d); mkdir -p "$W/proj"; cp "$1" "$W/proj/main.tex"
txs_on_exit 'rm -f "$ES"; rm -rf "$W"'
ES=/tmp/txs-cycle$$.sock
deno run -A "$REPO/clients/mock-engine/main.ts" --folder "$W/proj" --socket "$ES" >"$W/mock.log" 2>&1 &
MOCK=$!
txs_track $MOCK
i=0; while [ ! -S "$ES" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.1; done
case "$2" in
  native-vim) MODE=native; VIM='<true/>' ;;
  native) MODE=native; VIM='<false/>' ;;
  *) MODE=neovim; VIM='<false/>' ;;
esac
TAUDOT_SOCKET="$ES" TAUDOT_NO_PDF=1 TAUDOT_COMMENTS=shown TAUDOT_EDITOR_MODE=$MODE TAUDOT_CYCLECHECK="$W/out.txt" \
  "$MAC/.build/${CONFIG:-debug}/taudot-app" "$W/proj" -taudot.vimKeys $VIM >"$W/app.log" 2>&1 &
APP=$!
txs_track $APP
i=0; while kill -0 $APP 2>/dev/null && [ $i -lt 400 ]; do i=$((i+1)); sleep 0.1; done
txs_stop  # (the app with its Neovim and TeXpresso, and the engine)
cat "$W/out.txt" 2>/dev/null || { echo "FAIL no output"; tail -30 "$W/app.log"; exit 1; }
! grep -q FAIL "$W/out.txt"
