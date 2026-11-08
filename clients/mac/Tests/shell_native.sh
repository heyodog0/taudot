#!/bin/sh
# The app in native editor mode (TAUDOT_EDITOR_MODE=native, TAUDOT_NATIVECHECK): the native editor wired in place of
# Neovim. taudot-app (CONFIG=debug|release) on a COPY of FILE.tex with the mock engine, in the background.
#   swift build --product taudot-app && clients/mac/Tests/shell_native.sh FILE.tex
# SYNC=1 typesets it too and checks SyncTeX both ways (double-clicks on the PDF and in the editor).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MAC=$(cd "$HERE/.." && pwd)
REPO=$(cd "$MAC/../.." && pwd)
. "$HERE/shell_lib.sh"
W=$(mktemp -d); mkdir -p "$W/proj" "$W/bin"
if [ -d "$1" ]; then cp -R "$1/." "$W/proj/"; rm -f "$W/proj/.taudot.json"; else cp "$1" "$W/proj/main.tex"; fi
# A fake `claude` (echoes what is typed): ⌘3 and "Ask Claude to fix" start Claude.
printf '#!/bin/sh\necho "fake claude"\nexec cat\n' > "$W/bin/fake-claude"; chmod +x "$W/bin/fake-claude"
ES=/tmp/txs-native$$.sock
deno run -A "$REPO/clients/mock-engine/main.ts" --folder "$W/proj" --socket "$ES" >"$W/mock.log" 2>&1 &
MOCK=$!; started $MOCK
on_exit 'rm -f "$ES"; rm -rf "$W"'
i=0; while [ ! -S "$ES" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.1; done
# The theme through the argument domain (nothing written to defaults).
if [ "${SYNC:-}" = 1 ]; then NOPDF=; else NOPDF=1; fi
env ${NOPDF:+TAUDOT_NO_PDF=1} TAUDOT_SOCKET="$ES" TAUDOT_CLAUDE="$W/bin/fake-claude" TAUDOT_EDITOR_MODE=native TAUDOT_NATIVECHECK="$W/out.txt" TAUDOT_NATIVECHECK_THEME=solarized-dark ${APP_WRAP:-} \
  "$APP_BIN" "$W/proj" -taudot.editorTheme solarized-dark ${APP_ARGS:-} >"$W/app.log" 2>&1 &
APP=$!; started $APP
i=0; while kill -0 $APP 2>/dev/null && [ $i -lt 1500 ]; do i=$((i+1)); sleep 0.1; done
kill $APP 2>/dev/null
cat "$W/out.txt" 2>/dev/null || { echo "FAIL no output"; tail -20 "$W/app.log"; exit 1; }
! grep -q FAIL "$W/out.txt"
