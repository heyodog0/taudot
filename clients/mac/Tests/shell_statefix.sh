#!/bin/sh
# The window's state machines (TAUDOT_STATECHECK, docs/state-machines.md: A1, A2, A12…) in the real app, in the
# background, on a COPY of FILE.tex with the mock engine. ONLY=A12,A1 runs a subset; MODE=native the native editor.
# Exit 1 on a FAIL.
#   swift build --product taudot-app && clients/mac/Tests/shell_statefix.sh FILE.tex
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MAC=$(cd "$HERE/.." && pwd)
REPO=$(cd "$MAC/../.." && pwd)
. "$HERE/shell_lib.sh"
W=$(mktemp -d); mkdir -p "$W/proj" "$W/bin"; cp "$1" "$W/proj/main.tex"
printf '#!/bin/sh\necho "fake claude: ready"\nexec cat\n' > "$W/bin/fake-claude"; chmod +x "$W/bin/fake-claude"
ES=/tmp/txs-state$$.sock
deno run -A "$REPO/clients/mock-engine/main.ts" --folder "$W/proj" --socket "$ES" >"$W/mock.log" 2>&1 &
MOCK=$!; started $MOCK
on_exit 'rm -f "$ES"; rm -rf "$W"'
i=0; while [ ! -S "$ES" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.1; done
env TAUDOT_SOCKET="$ES" TAUDOT_CLAUDE="$W/bin/fake-claude" TAUDOT_NO_PDF=${NOPDF-1} TAUDOT_COMMENTS=shown TAUDOT_EDITOR_MODE="${MODE:-neovim}" \
  ${ONLY:+TAUDOT_STATECHECK_ONLY=$ONLY} TAUDOT_STATECHECK="$W/out.txt" "$APP_BIN" "$W/proj" >"$W/app.log" 2>&1 &
APP=$!; started $APP
i=0; while kill -0 $APP 2>/dev/null && [ $i -lt 900 ]; do i=$((i+1)); sleep 0.1; done
kill $APP 2>/dev/null
cat "$W/out.txt" 2>/dev/null || { echo "FAIL no output"; tail -20 "$W/app.log"; exit 1; }
! grep -q FAIL "$W/out.txt"
