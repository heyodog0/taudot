#!/bin/sh
# The engine's launch agent from the bundle (`taudot service ensure`, what the app runs at launch), with a scratch
# HOME and engine home, so its label is app.taudot.engine.<hash> and never the user's agent:
#   1. first launch installs it, pointing into the bundle, and the engine answers;
#   2. an agent left by a repo build (another binary) is repointed at the bundle;
#   3. the app moved: repointed at the new place;
#   4. the app updated in place (a new copy of the bundle at the same path): the engine restarts;
#   5. nothing changed: nothing done;
#   6. the app itself runs ensure at launch (its log says so).
# Then the agent is uninstalled.   tools/release/agent-test.sh Taudot.app [WORK]   (WORK: a short path, outside ~)
set -u
app=$(cd "$1" && pwd)
work=${2:-$(mktemp -d /private/tmp/tda.XXXXXX)}
mkdir -p "$work" && work=$(cd "$work" && pwd -P)
h="$work/home" eh="$work/home/.taudot"
rm -rf "$h" "$work/A" "$work/B" && mkdir -p "$h" "$work/A" "$work/B"
fails=0
ok() { echo "ok: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
e() { env -i HOME="$h" PATH=/usr/bin:/bin USER="$USER" "$@"; }
ensure() { e "$1/Contents/MacOS/taudot" service ensure --home "$eh" --json 2>&1; }
action() { printf '%s' "$1" | sed -n 's/.*"action":"\([^"]*\)".*/\1/p'; }
plist_exe() { /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$h"/Library/LaunchAgents/app.taudot.engine.*.plist 2>/dev/null; }
pid() { e "$app/Contents/MacOS/taudot" service status --home "$eh" --json | sed -n 's/.*"pid":"\{0,1\}\([0-9]*\).*/\1/p'; }
answers() { e "$app/Contents/MacOS/taudot" service status --home "$eh" --json | grep -q '"engine_answers":true'; }

label=$(e "$app/Contents/MacOS/taudot" service status --home "$eh" --json | sed -n 's/.*"label":"\([^"]*\)".*/\1/p')
case "$label" in app.taudot.engine.*) ok "test label $label (not the user's)" ;; *) echo "refusing: label '$label'"; exit 1 ;; esac

ditto "$app" "$work/A/Taudot.app"
r=$(ensure "$work/A/Taudot.app")
[ "$(action "$r")" = installed ] && [ "$(plist_exe)" = "$work/A/Taudot.app/Contents/MacOS/taudot" ] && answers \
  && ok "1. installed, runs $(plist_exe), engine answers" || fail "1. $r / $(plist_exe)"

# 2. a repo build's agent: same label, another binary
repo_bin=$(cd "$(dirname "$0")/../.." && pwd)/target/release/taudot
if [ -x "$repo_bin" ]; then
  cp "$repo_bin" "$work/repo-taudot"
  e "$work/repo-taudot" service install --home "$eh" >/dev/null 2>&1
  [ "$(plist_exe)" = "$work/repo-taudot" ] || fail "2. couldn't set up the repo agent ($(plist_exe))"
  r=$(ensure "$work/A/Taudot.app")
  [ "$(action "$r")" = repointed ] && [ "$(plist_exe)" = "$work/A/Taudot.app/Contents/MacOS/taudot" ] && answers \
    && ok "2. a repo build's agent repointed at the bundle" || fail "2. $r"
fi

# 3. moved
mv "$work/A/Taudot.app" "$work/B/Taudot.app"
r=$(ensure "$work/B/Taudot.app")
[ "$(action "$r")" = repointed ] && [ "$(plist_exe)" = "$work/B/Taudot.app/Contents/MacOS/taudot" ] && answers \
  && ok "3. moved app: repointed" || fail "3. $r"

# 4. updated in place (Sparkle replaces the bundle: new files at the same path)
p1=$(pid)
sleep 1
rm -rf "$work/B/Taudot.app" && ditto "$app" "$work/B/Taudot.app"
r=$(ensure "$work/B/Taudot.app")
p2=$(pid)
[ "$(action "$r")" = restarted ] && [ -n "$p2" ] && [ "$p1" != "$p2" ] && answers \
  && ok "4. updated app: engine restarted (pid $p1 → $p2)" || fail "4. $r ($p1 → $p2)"

# 5. nothing to do
r=$(ensure "$work/B/Taudot.app")
[ "$(action "$r")" = "up to date" ] && ok "5. relaunch: up to date" || fail "5. $r"

# 6. the app runs ensure itself (off screen, quits after 8 s)
e TAUDOT_OFFSCREEN=1 TAUDOT_NO_PREWARM=1 TAUDOT_SOCKET="$eh/engine.sock" TAUDOT_QUIT_TEST=quit:8 CFFIXED_USER_HOME="$h" \
  "$work/B/Taudot.app/Contents/MacOS/taudot-app" > "$work/app.log" 2>&1
grep -q 'taudot service ensure: {"action":"up to date"' "$work/app.log" && ok "6. the app ran ensure at launch" \
  || fail "6. $(grep 'service ensure' "$work/app.log")"

e "$app/Contents/MacOS/taudot" service uninstall --home "$eh" >/dev/null
[ -z "$(ls "$h/Library/LaunchAgents")" ] && ! launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 && ok "uninstalled" || fail "agent left behind"
[ $fails = 0 ] && echo "agent test: all checks passed" || echo "agent test: $fails failed"
exit $fails
