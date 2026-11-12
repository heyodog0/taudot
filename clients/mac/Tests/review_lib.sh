# Sourced by the review_*.sh scripts: every process a script starts, and everything those start (the app's Neovim,
# TeXpresso and its forks, the capture helper), stops when the script ends, however it ends (EXIT, ^C, a kill).
# By process id (never by name: other taudot apps may be running).
#   . "$HERE/review_lib.sh"; some & txs_track $!; txs_on_exit 'rm -rf "$W"'
TXS_PIDS=""
txs_track() { TXS_PIDS="$TXS_PIDS $1"; }
# A process and its descendants (taken before any is killed: an orphan is re-parented and lost).
txs_tree() { for c in $(pgrep -P "$1" 2>/dev/null); do txs_tree "$c"; done; echo "$1"; }
txs_stop() {
  all=""
  for p in $TXS_PIDS; do all="$all $(txs_tree "$p")"; done
  [ -n "${all# }" ] || return 0
  kill $all 2>/dev/null
  i=0; while [ $i -lt 20 ]; do
    left=""; for p in $all; do kill -0 "$p" 2>/dev/null && left="$left $p"; done
    [ -z "$left" ] && break
    i=$((i+1)); sleep 0.1
  done
  [ -n "${left:-}" ] && kill -9 $left 2>/dev/null
  TXS_PIDS=""
  return 0
}
# The cleanup on every way out; `extra` runs after the processes are gone (temp files, defaults).
txs_on_exit() {
  TXS_EXTRA="$1"
  trap 'set +u; txs_stop; eval "$TXS_EXTRA"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}

# The user works on this Mac while tests run (docs/developing.md, "Tests stay off the screen"):
# app runs go in the background (TAUDOT_OFFSCREEN=1: never activates, its window behind and off to the side), and a
# script that needs the real screen or real input (ScreenCaptureKit, HID keys or scrolls, the window in front) runs
# only when asked: TAUDOT_ONSCREEN=1, rarely, batched, noted in the log. Otherwise it says so and exits 0.
txs_onscreen_only() {
  if [ "${TAUDOT_ONSCREEN:-}" != 1 ]; then
    echo "skip: $(basename "$0") needs the real screen ($1); run it with TAUDOT_ONSCREEN=1 (rarely, batched)"
    exit 0
  fi
}
