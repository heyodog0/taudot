#!/bin/sh
# Build a Rex session for a taudot project folder:
#   tab "editor":  Neovim with the taudot plugin | the PDF preview (clients/preview)
#                  + a floating activity feed, created hidden (toggle it with --toggle-activity)
#   tab "engine":  the mock engine with its bot, when no engine is running
#
#   taudot-layout.sh [--no-bot] [--no-show] [--texpresso] FOLDER
#     --texpresso: the preview typesets with TeXpresso (clients/preview/texpresso, built first) from the engine's
#     live edits instead of running tectonic on file saves. Also TAUDOT_PREVIEW_ENGINE=texpresso.
#   taudot-layout.sh --toggle-activity [SESSION]      (default: $REX_SESSION, else the last one built)
#   taudot-layout.sh --close [SESSION]                close the session (and its mock engine)
#
# Needs rex, nvim 0.12, deno, jq, tectonic, pdftoppm.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
state_dir="$HOME/.taudot/rex"
flavor=com.superlogical.terminal.shell
float_bounds='[0.52,0.5,0.46,0.46]'

die() { echo "taudot-layout: $*" >&2; exit 1; }
api() { rex api call "$1" "$2"; }

state_for() {
  s=${1:-${REX_SESSION:-}}
  if [ -n "$s" ] && [ -f "$state_dir/$s.json" ]; then echo "$state_dir/$s.json"; return; fi
  [ -n "${1:-}" ] && die "no taudot layout recorded for session $1"
  f=$(ls -t "$state_dir"/*.json 2>/dev/null | head -1)
  [ -n "$f" ] || die "no taudot layout recorded"
  echo "$f"
}

toggle_activity() {
  st=$(state_for "${1:-}")
  s=$(jq -r .session_id "$st"); a=$(jq -r .activity_block "$st"); e=$(jq -r .editor_block "$st")
  where=$(api session.list_blocks "{\"session_id\":\"$s\"}" | jq -r --arg a "$a" '.blocks[] | select(.block_id==$a) | .window_id // ""')
  if [ -n "$where" ]; then
    # shown: take it out of the window. The block keeps running, detached.
    api session.detach_block "{\"session_id\":\"$s\",\"block_id\":\"$a\"}" >/dev/null
    echo hidden
  else
    # hidden: put it beside the editor, then float it
    api session.move_block "{\"session_id\":\"$s\",\"block_id\":\"$a\",\"anchor_block_id\":\"$e\",\"direction\":\"horizontal\",\"side\":\"after\"}" >/dev/null
    api session.float_block "{\"session_id\":\"$s\",\"block_id\":\"$a\",\"bounds\":$float_bounds}" >/dev/null
    echo shown
  fi
}

close_layout() {
  st=$(state_for "${1:-}")
  s=$(jq -r .session_id "$st")
  rex kill "$s" >/dev/null 2>&1 || true
  sock=$(jq -r '.mock_socket // ""' "$st")
  [ -n "$sock" ] && rm -f "$sock"
  psock=$(jq -r '.preview_socket // ""' "$st")
  [ -n "$psock" ] && rm -f "$psock"
  rm -f "$st"
  echo "closed $s"
}

bot=--bot
show=1
engine=${TAUDOT_PREVIEW_ENGINE:-tectonic}
while [ $# -gt 0 ]; do
  case $1 in
    --toggle-activity) shift; toggle_activity "${1:-}"; exit ;;
    --close) shift; close_layout "${1:-}"; exit ;;
    --no-bot) bot=; shift ;;
    --no-show) show=0; shift ;;
    --texpresso) engine=texpresso; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit ;;
    -*) die "unknown option $1" ;;
    *) break ;;
  esac
done
[ $# -eq 1 ] || die "usage: taudot-layout.sh [--no-bot] [--no-show] [--texpresso] FOLDER"
if [ "$engine" = texpresso ] && [ ! -x "$here/../preview/texpresso/txp-headless" ]; then
  die "--texpresso: build clients/preview/texpresso first (see its README)"
fi
for c in rex nvim deno jq tectonic pdftoppm; do command -v $c >/dev/null || die "$c not found"; done
folder=$(cd "$1" && pwd) || die "no folder $1"
name=$(basename "$folder")

main="$folder/main.tex"
[ -f "$main" ] || main=$(ls "$folder"/*.tex 2>/dev/null | head -1)
[ -n "$main" ] || die "no .tex file in $folder"

# Use a running engine if there is one, else a mock engine of our own on a private socket.
sock=${TAUDOT_SOCKET:-$HOME/.taudot/engine.sock}
mock=0
if [ -S "$sock" ] && [ -f "$(dirname "$sock")/engine.json" ] &&
   kill -0 "$(jq -r .pid "$(dirname "$sock")/engine.json")" 2>/dev/null; then
  echo "using the engine at $sock"
else
  mock=1
  sock="${TMPDIR:-/tmp}/taudot-$$.sock"
  sock=$(echo "$sock" | sed 's#//#/#g')
fi

# The preview listens here; Neovim connects for SyncTeX (double-click in the PDF jumps, the cursor is followed).
mkdir -p "$state_dir"
psock="$state_dir/preview-$$.sock"

# Neovim waits for the socket, so it can start before the engine. The plugin is added after the user's config, since
# plugin managers such as lazy.nvim reset 'runtimepath'.
editor_cmd='i=0; while [ ! -S "$1" ] && [ $i -lt 150 ]; do sleep 0.1; i=$((i+1)); done
exec env TAUDOT_SOCKET="$1" TAUDOT_PREVIEW_SOCKET="$5" nvim -n -c "set rtp^=$2 | runtime plugin/taudot.lua | Taudot open $3" "$4"'
created=$(rex new "taudot-$name" -c "$folder" --window editor --json -- \
  sh -c "$editor_cmd" _ "$sock" "$repo/clients/nvim" "$folder" "$main" "$psock")
session=$(echo "$created" | jq -er .session_id)
window=$(echo "$created" | jq -er '.initial_windows[0].window_id')
editor=$(echo "$created" | jq -er '.initial_windows[0].block_ids[0]')

api session.set_block_label "{\"session_id\":\"$session\",\"block_id\":\"$editor\",\"label\":\"nvim\"}" >/dev/null || true

# The PDF preview: compiles the folder with tectonic on every change and draws the pages with Kitty graphics.
preview=$(rex split -s "$session" -b "$editor" --split=right --ratio 40 --label preview --focus=false --json -- \
  deno run -A "$repo/clients/preview/preview.ts" --folder "$folder" --main "${main#"$folder"/}" \
  --listen "$psock" --editor-block "$editor" --fps "${TAUDOT_PREVIEW_FPS:-120}" \
  ${TAUDOT_PREVIEW_TRACE:+--trace "$TAUDOT_PREVIEW_TRACE"} \
  $( [ "$engine" = texpresso ] && echo "--engine texpresso --taudot-socket $sock" ) | jq -er '.block_ids[0]')

# Trackpad pinch for the preview, if the helper is built (clients/rex/pinch/README.md). One instance serves every layout.
pinch_app="$here/pinch/build.noindex/TaudotPinch.app"
if [ -d "$pinch_app" ] && ! pgrep -xq taudot-pinch; then open -g "$pinch_app" || true; fi

# The activity feed: a floating layer, then detached so it starts hidden but keeps running.
layer=$(api session.new_layer "$(jq -nc --arg s "$session" --arg w "$window" --arg f "$flavor" --arg cwd "$folder" \
  --arg sock "$sock" --arg act "$here/activity.ts" --arg folder "$folder" --argjson b "$float_bounds" '{
    session_id: $s, window_id: $w, bounds: $b, focus: false,
    layout: {block: {flavor: $f, label: "activity", options: {cwd: $cwd,
      command: ["env", ("TAUDOT_SOCKET=" + $sock), "deno", "run", "-A", $act, "--folder", $folder]}}}}')")
activity=$(echo "$layer" | jq -er '.block_ids[0]')
api session.detach_block "{\"session_id\":\"$session\",\"block_id\":\"$activity\"}" >/dev/null

engine=
if [ $mock = 1 ]; then
  engine=$(rex window new -s "$session" engine -c "$folder" --focus=false --keep-open --json -- \
    deno run -A "$repo/clients/mock-engine/main.ts" --folder "$folder" --socket "$sock" $bot | jq -er '.block_ids[0]')
  api session.set_block_label "{\"session_id\":\"$session\",\"block_id\":\"$engine\",\"label\":\"mock engine\"}" >/dev/null || true
  rex focus -s "$session" "$window" >/dev/null 2>&1 || true
fi
rex focus -s "$session" "$editor" >/dev/null 2>&1 || true

mkdir -p "$state_dir"
jq -n --arg s "$session" --arg w "$window" --arg e "$editor" --arg p "$preview" --arg a "$activity" \
  --arg g "$engine" --arg f "$folder" --arg sock "$sock" --arg ps "$psock" --argjson mock $mock '{
    session_id: $s, window_id: $w, editor_block: $e, preview_block: $p, activity_block: $a,
    engine_block: (if $g == "" then null else $g end), folder: $f, socket: $sock, preview_socket: $ps,
    mock_socket: (if $mock == 1 then $sock else null end)}' > "$state_dir/$session.json"

if [ $show = 1 ]; then
  client=$(rex client ls --json 2>/dev/null | jq -r '[.clients[] | select(.info.kind=="app" and .connection_state=="connected")][0].client_id // ""')
  [ -n "$client" ] && rex -C "$client" do session.select session_id="$session" >/dev/null 2>&1 || true
fi
echo "$session"
