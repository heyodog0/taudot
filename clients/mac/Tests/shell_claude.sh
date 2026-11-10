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

# Item 7: claude behind tau-attach in a Rex session, on a Rex server of this test's own (never the user's).
TA="$MAC/../attach/tau-attach"; [ -x "$TA" ] || sh "$MAC/../attach/build.sh"
RD=$(mktemp -d "${TMPDIR:-/tmp}/trx.XXXX"); RS="unix://$RD/s"
: > "$RD/init.lua"
rex server run --listen "$RS" --state-dir "$RD/state" --restore=false --config "$RD/init.lua" --autostart=false >"$W/rex.log" 2>&1 &
RPID=$!; started $RPID
rx() { rex -S "$RS" --autostart=false "$@"; }
i=0; while ! rx server status >/dev/null 2>&1 && [ $i -lt 50 ]; do i=$((i+1)); sleep 0.1; done
SOCKS="$W/socks"; mkdir -p "$SOCKS"
rexrun() {  # mode [extra env...]
  m=$1; shift
  env "$@" TAUDOT_SOCKET="$ES" TAUDOT_NO_PDF=1 TAUDOT_CLAUDE="$W/bin/fake-claude" TAUDOT_CLAUDE_SOCKETS="$SOCKS" \
    TAUDOT_CLAUDECHECK="$W/out-rex-$m.txt" TAUDOT_CLAUDECHECK_REX=$m TAUDOT_CLAUDECHECK_PIDFILE="$W/claude.pid" "$APP_BIN" "$W/proj" >"$W/app-rex-$m.log" 2>&1 &
  APP=$!; started $APP
  i=0; while kill -0 $APP 2>/dev/null && [ $i -lt 600 ]; do i=$((i+1)); sleep 0.1; done
  kill $APP 2>/dev/null
  cat "$W/out-rex-$m.txt" 2>/dev/null || { echo "FAIL rex $m: no output"; tail -20 "$W/app-rex-$m.log"; fail=1; }
  grep -q FAIL "$W/out-rex-$m.txt" 2>/dev/null && fail=1
}
rexrun start TAUDOT_REX_SERVER="$RS" TAUDOT_CLAUDE_KEEP=1
# the same conversation in the Rex block: its screen, and keys sent there reach claude
SID=$(rx ls --json | sed -n 's/.*"session_id": *"\([^"]*\)".*/\1/p' | head -1)
BID=$(rx block ls -s "$SID" --json 2>/dev/null | sed -n 's/.*"block_id": *"\([^"]*\)".*/\1/p' | head -1)
LBL=$(rx ls --json | sed -n 's/.*"label": *"\([^"]*\)".*/\1/p' | head -1)
[ "$LBL" = "taudot-proj" ] && echo "ok   rex: the project's session is taudot-proj" || { echo "FAIL rex: session label '$LBL'"; fail=1; }
i=0; while ! rx capture -s "$SID" -b "$BID" 2>/dev/null | grep -q frompane && [ $i -lt 30 ]; do i=$((i+1)); sleep 0.1; done
rx capture -s "$SID" -b "$BID" 2>/dev/null | grep -q frompane && echo "ok   rex: the Rex block shows what the pane typed" || { echo "FAIL rex: the block doesn't show the pane's input"; fail=1; }
rx send -s "$SID" -b "$BID" 'fromrex' >/dev/null && rx send-key -s "$SID" -b "$BID" Enter >/dev/null
sleep 0.5
# reopening the project attaches to the same claude and shows what Rex typed
rexrun reopen TAUDOT_REX_SERVER="$RS" TAUDOT_CLAUDE_KEEP=1 TAUDOT_CLAUDECHECK_EXPECT=fromrex
# the end of claude: the pane's claude and the Rex session go; nothing left behind
p=$("$TA" status "$SOCKS"/*.s 2>/dev/null); [ -n "$p" ] && kill "$p"
sleep 0.5
rx kill "$SID" >/dev/null 2>&1
# without a Rex server answering: started here (and ended with the app)
rexrun down TAUDOT_REX_SERVER="unix://$RD/none"
sleep 0.5
left=$(ls "$SOCKS" 2>/dev/null | wc -l | tr -d ' ')
[ "$left" = 0 ] && echo "ok   nothing left behind (no claude sockets)" || { echo "FAIL $left claude socket(s) left in $SOCKS"; fail=1; }
[ -z "$(rx ls --json | sed -n 's/.*"session_id".*/x/p')" ] && echo "ok   no Rex sessions left on the test server" || { echo "FAIL Rex sessions left"; fail=1; }
rx api call server.stop '{}' >/dev/null 2>&1
i=0; while kill -0 $RPID 2>/dev/null && [ $i -lt 30 ]; do i=$((i+1)); sleep 0.1; done
kill $RPID 2>/dev/null
rm -f "$RD/s" "$RD/init.lua"; rm -rf "$RD/state"; rmdir "$RD" 2>/dev/null
exit $fail
