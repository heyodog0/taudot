#!/bin/sh
# Scrolling on the CE replica "Demo Paper (replica)" (docs/agents/README.md): the real engine as alice on the local
# CE, the app on a fresh mirror folder, the shell's TAUDOT_SCROLLTRACE flicks and TAUDOT_MARGIN_TRACE per frame.
# Output stays outside the repo (the paper belongs to the user's collaborators): pass an OUTDIR outside it.
#   swift build --product taudot-app && clients/mac/Tests/review_replica_trace.sh OUTDIR [replica name]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/review_lib.sh"
MAC=$(cd "$HERE/.." && pwd)
OUT=$1
NAME=${2:-demo-paper}
ENGINE=${TAUDOT_ENGINE:-$HOME/code/lab/taudot/target/debug/taudot}
ENV_FILE=${TAUDOT_ENV_FILE:-$HOME/code/lab/taudot/docker/.env.test}
REP="$HOME/.taudot/replicas/$NAME/replica.json"
PID=$(sed -n 's/.*"project_id": "\([0-9a-f]*\)".*/\1/p' "$REP")
URL=$(sed -n 's/^OVERLEAF_URL=//p' "$ENV_FILE")
mkdir -p "$OUT"
W=$(mktemp -d); mkdir -p "$W/home" "$W/proj"
txs_on_exit 'rm -rf "$W"'
printf '{"project": "%s"}\n' "$PID" > "$W/proj/.taudot.json"
"$ENGINE" serve --url "$URL" --env-file "$ENV_FILE" --user user1 --home "$W/home" > "$W/engine.log" 2>&1 &
ENG=$!
txs_track $ENG
i=0; while [ ! -S "$W/home/engine.sock" ] && [ $i -lt 200 ]; do i=$((i+1)); sleep 0.05; done
TAUDOT_SOCKET="$W/home/engine.sock" TAUDOT_NO_PDF=1 TAUDOT_COMMENTS=shown \
  TAUDOT_SCROLLTRACE="$OUT/scroll.txt" TAUDOT_MARGIN_TRACE="$OUT/margin.txt" \
  "$MAC/.build/${CONFIG:-debug}/taudot-app" "$W/proj" >"$OUT/app.log" 2>&1 &
APP=$!
txs_track $APP
i=0; while kill -0 $APP 2>/dev/null && [ $i -lt 1800 ]; do i=$((i+1)); sleep 0.1; done
txs_stop  # (the app with its Neovim and TeXpresso, and the engine)
cp "$W/engine.log" "$OUT/engine.log"
echo "out: $OUT"
