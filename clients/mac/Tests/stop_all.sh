# Sourced by test scripts: stop everything the script started when it exits, however it exits (EXIT, INT, TERM).
#   . "$repo/clients/mac/Tests/stop_all.sh"; stop_all_setup "$tmp" [ENGINE_PIDFILE...]
# The engine (pid files: it may have been restarted outside this shell's tree) gets SIGINT first, to write its
# backups; then the whole process tree under this shell (Neovim, EditorHost, Bob's node and Chromium, txp and its
# texpresso-xetex forks, mock engines), collected before any kill so forks are caught while still children; then
# SIGKILL for whatever is left. Then the temp dir goes.
_stop_tree() {
  for _c in $(pgrep -P "$1" 2>/dev/null); do _stop_tree "$_c"; echo "$_c"; done
}
stop_all() {
  _rc=$?
  trap - EXIT INT TERM
  set +e  # (a kill of something already gone must not become the script's exit status under set -e)
  for _f in $_stop_pidfiles; do
    [ -f "$_f" ] && kill -INT "$(cat "$_f")" 2>/dev/null
  done
  _pids=$(_stop_tree $$)
  [ -n "$_pids" ] && kill $_pids 2>/dev/null
  sleep 0.5
  _more=$(_stop_tree $$)
  for _f in $_stop_pidfiles; do [ -f "$_f" ] && _more="$_more $(cat "$_f")"; done
  [ -n "$_pids$_more" ] && kill -9 $_pids $_more 2>/dev/null
  [ -n "$_stop_tmp" ] && rm -rf "$_stop_tmp"
  return $_rc
}
stop_all_setup() {
  _stop_tmp=$1
  shift
  _stop_pidfiles="$*"
  trap 'stop_all' EXIT
  trap 'stop_all; exit 130' INT TERM
}
