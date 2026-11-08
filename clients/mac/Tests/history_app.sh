#!/bin/sh
# History in the real app window (TAUDOT_HISTORYCHECK), in the background, against a running engine and a project
# folder it mirrors (a throwaway CE project: crates/engine/tests/ce/history.sh makes one). Checks the History tab,
# the diff over the editor, Back to Editing; leaves OUT.png, a picture of the window. Exit 1 on a FAIL.
#   swift build --product taudot-app && clients/mac/Tests/history_app.sh ENGINE_SOCKET FOLDER OUT [native|neovim] [pdf]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MAC=$(cd "$HERE/.." && pwd)
REPO=$(cd "$MAC/../.." && pwd)
. "$HERE/shell_lib.sh"
SOCK=$1 FOLDER=$2 OUT=$3 MODE=${4:-neovim}
# a 5th argument "pdf": the PDF pane shown too (the version PDF and its marks are checked)
NOPDF=1; [ "${5:-}" = pdf ] && NOPDF=
rm -f "$OUT" "$OUT.png"
env ${NOPDF:+TAUDOT_NO_PDF=1} TAUDOT_SOCKET="$SOCK" TAUDOT_COMMENTS=shown TAUDOT_EDITOR_MODE="$MODE" TAUDOT_HISTORYCHECK="$OUT" \
  "$APP_BIN" "$FOLDER" >"$OUT.log" 2>&1 &
APP=$!; started $APP
i=0; while kill -0 $APP 2>/dev/null && [ $i -lt 1800 ]; do i=$((i+1)); sleep 0.1; done
kill $APP 2>/dev/null
cat "$OUT" 2>/dev/null || { echo "FAIL no output"; tail -20 "$OUT.log"; exit 1; }
! grep -q FAIL "$OUT"
