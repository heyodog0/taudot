#!/bin/sh
# Typing in the real app while the PDF follows: taudot-app (CONFIG=debug|release) on a COPY of FOLDER (or
# $TAUDOT_PERF_DOC; never written; a long paper with main.tex, as the Lua script's line numbers assume 400+ lines),
# the mock engine, Neovim driven by Tests/pdf_typing.lua (PDF_TYPING=race|human|both). In the background, ~1-2 minutes.
#   swift build --product taudot-app && clients/mac/Tests/pdf_typing.sh [FOLDER]
# Fails when: the app dies; the last edit (ZEBRAFINAL, inserted in one edit at the end) never reaches a typeset PDF
# with pages; and, with the pane's self-check (TAUDOT_PDF_CHECK, TaudotPDF), when the pane goes blank, its copy of a
# doc drifts from the engine's text, or the main thread stalls over 1 s. KEEP=1 keeps the work folder.
# APP_BIN=path runs another build (e.g. one from before a fix).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MAC=$(cd "$HERE/.." && pwd)
REPO=$(cd "$MAC/../.." && pwd)
SRC=${1:-${TAUDOT_PERF_DOC:-}}
[ -n "$SRC" ] && [ -f "$SRC/main.tex" ] || { echo "pdf_typing.sh: pass FOLDER or set TAUDOT_PERF_DOC (a project folder with main.tex)" >&2; exit 2; }
W=$(mktemp -d)
mkdir -p "$W/proj"
cp -R "$SRC/." "$W/proj/"
rm -f "$W/proj/.taudot.json"
ES=/tmp/txs-pdftyping$$.sock
deno run -A "$REPO/clients/mock-engine/main.ts" --folder "$W/proj" --socket "$ES" >"$W/mock.log" 2>&1 &
MOCK=$!
i=0; while [ ! -S "$ES" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.1; done
TYPE_LOG="$W/type.log" TAUDOT_SOCKET="$ES" TAUDOT_PDF_CHECK="$W/check.log" TAUDOT_TXP_LOG="$W/txp.log" \
  TAUDOT_EXEC="dofile('$HERE/pdf_typing.lua')" "${APP_BIN:-$MAC/.build/${CONFIG:-debug}/taudot-app}" "$W/proj" >"$W/app.log" 2>&1 &
APP=$!
fail=0
i=0
while [ $i -lt 240 ] && ! grep -q ' end$' "$W/type.log" 2>/dev/null; do
  kill -0 $APP 2>/dev/null || break
  i=$((i+1)); sleep 1
done
sleep 15  # the final edit typeset, SyncTeX fetched, a self-check pass
if kill -0 $APP 2>/dev/null; then kill $APP; else echo "FAIL the app exited during the run"; fail=1; fi
kill $MOCK 2>/dev/null; rm -f "$ES"
grep -q ' end$' "$W/type.log" 2>/dev/null || { echo "FAIL the typing script didn't finish"; fail=1; }

# the final edit, then a typeset PDF with pages after it
if awk '/ZEBRAFINAL/ && /"change"/ { seen = 1 } seen && /"ev":"pages"/ && /"done":true/ && !/"n":0,/ { ok = 1 } END { exit !ok }' "$W/txp.log"; then
  echo "ok   the last edit reached a typeset PDF"
else
  echo "FAIL no typeset PDF with pages after the last edit (TeXpresso stuck?)"; fail=1
fi
lost=$(grep -c 'No fences, assuming process finished' "$W/txp.log")
recovered=$(grep -c 'lost start:' "$W/txp.log")
restarts=$(grep -c 'txp restarted' "$W/check.log" 2>/dev/null)
echo "note TeXpresso lost its start $lost time(s): txp-headless recovered $recovered, the app restarted it ${restarts:-?}"
if [ -s "$W/check.log" ]; then
  for what in BLANK DRIFT; do
    if grep -q "$what" "$W/check.log"; then echo "FAIL $what:"; grep "$what" "$W/check.log" | head -3; fail=1; else echo "ok   no $what"; fi
  done
  worst=$(awk '/STALL/ { v = $5 + 0; if (v > m) m = v } END { print m + 0 }' "$W/check.log")
  if [ "$worst" -gt 1000 ]; then echo "FAIL main thread stalled $worst ms"; fail=1; else echo "ok   longest main-thread stall ${worst} ms"; fi
  grep 'state:' "$W/check.log" | tail -1 | sed 's/^[0-9.]* /note /'
else
  echo "note no self-check log (a build without TAUDOT_PDF_CHECK)"
fi
if [ "${KEEP:-}" = 1 ] || [ $fail = 1 ]; then echo "logs: $W"; else rm -rf "$W"; fi
exit $fail
