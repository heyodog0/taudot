#!/bin/sh
# The Claude pane in the real app (TAUDOT_CLAUDECHECK), with a fake `claude` that prints 200 lines and echoes its
# input: ⌘J start / hide / show (same job), the focus cycle and zoom, ⌘L's @file#La-b at the prompt without Return,
# Esc Esc; then a run without claude (the install note). taudot-app (CONFIG=debug|release) on a COPY of FILE.tex,
# mock engine, in the background. Exit 1 on a FAIL.
#   swift build --product taudot-app && clients/mac/Tests/shell_claude.sh FILE.tex
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MAC=$(cd "$HERE/.." && pwd)
REPO=$(cd "$MAC/../.." && pwd)
. "$HERE/shell_lib.sh"
W=$(mktemp -d); mkdir -p "$W/proj" "$W/bin"; cp "$1" "$W/proj/main.tex"
printf '#!/bin/sh\nseq 1 200\necho "fake claude: ready in $(basename "$PWD")"\nexec cat\n' > "$W/bin/fake-claude"; chmod +x "$W/bin/fake-claude"
ES=/tmp/txs-claude$$.sock
deno run -A "$REPO/clients/mock-engine/main.ts" --folder "$W/proj" --socket "$ES" >"$W/mock.log" 2>&1 &
MOCK=$!; started $MOCK
on_exit 'rm -f "$ES"; rm -rf "$W"'
i=0; while [ ! -S "$ES" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.1; done
fail=0
for run in fake missing; do
  if [ $run = fake ]; then CL="$W/bin/fake-claude"; MISSING=; else CL="$W/bin/no-such-claude"; MISSING=1; fi
  env TAUDOT_SOCKET="$ES" TAUDOT_NO_PDF=1 TAUDOT_CLAUDE="$CL" TAUDOT_CLAUDECHECK="$W/out-$run.txt" \
    ${MISSING:+TAUDOT_CLAUDECHECK_MISSING=1} "$APP_BIN" "$W/proj" >"$W/app-$run.log" 2>&1 &
  APP=$!; started $APP
  i=0; while kill -0 $APP 2>/dev/null && [ $i -lt 600 ]; do i=$((i+1)); sleep 0.1; done
  kill $APP 2>/dev/null
  cat "$W/out-$run.txt" 2>/dev/null || { echo "FAIL $run: no output"; tail -20 "$W/app-$run.log"; fail=1; }
  grep -q FAIL "$W/out-$run.txt" 2>/dev/null && fail=1
done
exit $fail
