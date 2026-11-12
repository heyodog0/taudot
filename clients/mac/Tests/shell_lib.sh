# Sourced by the shell_*.sh tests: whatever they start is stopped when they end, by exit, Ctrl-C, kill or HUP.
# After `cmd &`, `started $!` records it (job control is on, so it gets a process group of its own). `stop_all` (run
# on exit, or by hand between runs) stops the recorded processes and the script's other children, all their descendants and those descendants'
# process groups: the app's nvim --embed and txp-render each get a group from Foundation, and txp-render's
# texpresso-xetex forks live in its group. TERM, up to 3 s, then KILL. Only processes this script started are touched.
# `on_exit 'rm -rf …'` adds cleanup run after that.
set -m
STARTED="" KNOWN="" GROUPS_="" ON_EXIT=""
started() { STARTED="$STARTED $1"; }
on_exit() { ON_EXIT="${ON_EXIT:+$ON_EXIT; }$1"; }
_desc() { for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; _desc "$c"; done; }
# Adds the live recorded processes and their descendants (and the groups those lead) to KNOWN / GROUPS_.
_collect() {
  for p in $STARTED $KNOWN $(pgrep -P $$ 2>/dev/null); do
    kill -0 "$p" 2>/dev/null || continue
    for q in $p $(_desc "$p"); do
      case " $KNOWN " in *" $q "*) ;; *) KNOWN="$KNOWN $q" ;; esac
      g=$(ps -o pgid= -p "$q" 2>/dev/null | tr -d ' ')
      [ "$g" = "$q" ] && case " $GROUPS_ " in *" $g "*) ;; *) GROUPS_="$GROUPS_ $g" ;; esac
    done
  done
}
_alive() {
  for p in $KNOWN; do kill -0 "$p" 2>/dev/null && return 0; done
  for g in $GROUPS_; do kill -0 -- "-$g" 2>/dev/null && return 0; done
  return 1
}
stop_all() {
  _collect
  for g in $GROUPS_; do kill -TERM -- "-$g" 2>/dev/null; done
  for p in $KNOWN; do kill -TERM "$p" 2>/dev/null; done
  i=0; while _alive && [ $i -lt 30 ]; do i=$((i+1)); _collect; sleep 0.1; done
  for g in $GROUPS_; do kill -KILL -- "-$g" 2>/dev/null; done
  for p in $KNOWN; do kill -KILL "$p" 2>/dev/null; done
  STARTED="" KNOWN="" GROUPS_=""
}
trap 'stop_all; eval "$ON_EXIT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
# The app stays off the user's screen: no Dock icon, never activated, windows right of every screen
# (docs/developing.md). TAUDOT_ONSCREEN=1 (opt-in, rare) puts them on screen, still behind.
[ -n "${TAUDOT_ONSCREEN:-}" ] || export TAUDOT_OFFSCREEN=1
# The app with settings of its own: an unbundled build keeps them in a defaults domain named after its executable
# (taudot-app), which the rename's migration filled from the installed app's (the user's look, a floating Claude
# panel, the native editor…), so checks run it through a link with a fresh name, migration marked done, and drop that
# domain on exit. $APP_BIN is the link (needs $MAC; CONFIG=debug|release).
APP_DOMAIN="taudot-check-$$"
APP_BIN_DIR=$(mktemp -d)
APP_BIN="$APP_BIN_DIR/$APP_DOMAIN"
ln -s "$MAC/.build/${CONFIG:-debug}/taudot-app" "$APP_BIN"
defaults write "$APP_DOMAIN" taudot.migratedFromTexsync -bool YES
on_exit 'defaults delete "$APP_DOMAIN" >/dev/null 2>&1; rm -f "$HOME/Library/Preferences/$APP_DOMAIN.plist"; rm -rf "$APP_BIN_DIR"'
