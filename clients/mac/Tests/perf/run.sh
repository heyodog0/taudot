#!/bin/sh
# The bench: fixed documents, fixed scripts, both editor modes, both PDF paths; p50/p95/p99/max per stage from the
# app's own latency probes (Sources/TaudotShared/Latency.swift) and the outside capture. Off the user's screen.
#
#   clients/mac/Tests/perf/run.sh [-n RUNS] [-o OUT] [-m "native neovim"] [-e "live texpresso"]
#                                 [-s "type hold scroll jump"] [-d DOC] [--write]
#   clients/mac/Tests/perf/run.sh --compare REV_A REV_B [-n RUNS] [--margin PCT] [-m ...] [-e ...] [-s ...]
#
# DOC: a folder copied (cp -R) for every run, served by the mock engine (default $TAUDOT_PERF_DOC; no built-in
# default). It needs a main.tex of 400+ lines with running text at line 177: any long paper of your own works.
# --write puts the summary into clients/mac/Tests/perf/README.md (between the "bench:begin/end" markers) with the commit.
# --compare builds taudot-app at each revision (both must have the probes: 2026-11-06 or later) into copies of the
# bundle, then runs A and B alternately (A B A B ...: the machine's load hits both alike) and fails (exit 1) if B's
# key → presented or key → committed p95/p99 is worse than A's by more than PCT % (default 15) and 2 ms.
# PERF_APP=<taudot-app> another build for the plain mode. The bundle must exist: clients/mac/bundle.sh.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
mac=$(cd "$here/../.." && pwd)
repo=$(cd "$mac/../.." && pwd)
runs=3 out= modes="native neovim" engines="live texpresso" scripts="type hold scroll jump" doc="${TAUDOT_PERF_DOC:-}"
write= compare= revA= revB= margin=15
while [ $# -gt 0 ]; do
  case $1 in
    -n) runs=$2; shift 2;; -o) out=$2; shift 2;; -m) modes=$2; shift 2;; -e) engines=$2; shift 2;;
    -s) scripts=$2; shift 2;; -d) doc=$2; shift 2;; --write) write=1; shift;; --margin) margin=$2; shift 2;;
    --compare) compare=1; revA=$2; revB=$3; shift 3;;
    *) echo "run.sh: unknown $1" >&2; exit 2;;
  esac
done
out=${out:-$(mktemp -d /tmp/taudot-bench.XXXXXX)}
mkdir -p "$out"; out=$(cd "$out" && pwd)
bundle="$mac/build.noindex/Taudot.app"
[ -n "$doc" ] && [ -f "$doc/main.tex" ] || { echo "run.sh: pass -d DOC or set TAUDOT_PERF_DOC (a project folder with main.tex)" >&2; exit 2; }
[ -d "$bundle" ] || { echo "run.sh: no $bundle; run clients/mac/bundle.sh" >&2; exit 2; }

# The scripts (probe.swift's language). Each starts at the same place: line 177 of DOC's main.tex (in the
# maintainer's paper, a paragraph of the introduction); with Vim keys (the user's setting) `177G` and `o` open a line below it.
mkscript() {  # $1 name, $2 file
  case $1 in
    type) cat > "$2" <<'EOF'
wait-window @TITLE@
at 3 keys 177G
at 3.5 keys o
at 4 type 125 Sampling a paragraph of text at eight characters per second gives the latency probes something to chew on.
at 20 key esc
EOF
    ;;
    hold) cat > "$2" <<'EOF'
wait-window @TITLE@
at 3 keys 177G
at 3.5 keys o
at 4 type 33 xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
at 9 key esc
at 9.5 keys u
EOF
    ;;
    scroll) cat > "$2" <<'EOF'
wait-window @TITLE@
at 3 keys gg
at 4 key ctrl+d
at 4.3 key ctrl+d
at 4.6 key ctrl+d
at 4.9 key ctrl+d
at 5.2 key ctrl+d
at 5.5 key ctrl+d
at 5.8 key ctrl+d
at 6.1 key ctrl+d
at 6.4 key ctrl+u
at 6.7 key ctrl+u
at 7.0 key ctrl+u
at 7.3 key ctrl+u
at 7.6 key ctrl+u
at 7.9 key ctrl+u
at 8.2 key ctrl+u
at 8.5 key ctrl+u
EOF
    ;;
    jump) cat > "$2" <<'EOF'
wait-window @TITLE@
at 3 keys G
at 3.6 keys gg
at 4.2 keys 424G
at 4.8 keys 767G
at 5.4 keys gg
at 6 keys G
at 6.6 keys 177G
EOF
    ;;
  esac
  sed -i '' "s/@TITLE@/$title/" "$2"
}
secs() { case $1 in type) echo 24;; hold) echo 13;; scroll) echo 12;; jump) echo 10;; esac; }

title=$(basename "$doc")

# A copy of the bundle under its own bundle ID (app.taudot.bench), so runs never write into the user's defaults
# (per-folder window frames, split positions, sidebar keys: each run's temp folder would add its own, and the
# domain's size slows every launch: clients/mac/Tests/perf/README.md). The bench domain gets the user's global settings (taudot.* keys
# without a path in them: theme, font, Vim keys...), once per bench.
mkapp() {  # $1 taudot-app binary, $2 destination .app
  rm -rf "$2"; cp -R "$bundle" "$2"
  [ "$1" = "$bundle/Contents/MacOS/taudot-app" ] || cp "$1" "$2/Contents/MacOS/taudot-app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.taudot.bench" "$2/Contents/Info.plist"
  codesign -f -s - "$2" 2>/dev/null
}
seed() {
  defaults delete app.taudot.bench >/dev/null 2>&1 || true
  uv run -q --no-project python - <<'PY'
import plistlib, subprocess
src = subprocess.run(["defaults", "export", "app.taudot.Taudot", "-"], capture_output=True).stdout
d = plistlib.loads(src) if src else {}
keep = {k: v for k, v in d.items() if k.startswith("taudot.") and "/" not in k}
keep["taudot.migratedFromTexsync"] = True
subprocess.run(["defaults", "import", "app.taudot.bench", "-"], input=plistlib.dumps(keep), check=True)
PY
}
seed
mock_pid=
cleanup() { [ -n "$mock_pid" ] && kill "$mock_pid" 2>/dev/null || true; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# one run: $1 app binary, $2 dir, $3 mode, $4 engine, $5 script
one() {
  d=$2; rm -rf "$d"; mkdir -p "$d"
  cp -R "$doc" "$d/$title"
  echo '{"project": "bench-copy"}' > "$d/$title/.taudot.json"
  sock="/tmp/tdb-$$.sock"; rm -f "$sock"
  deno run -A "$repo/clients/mock-engine/main.ts" --folder "$d/$title" --socket "$sock" > "$d/mock.log" 2>&1 &
  mock_pid=$!
  i=0; while [ ! -S "$sock" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  mkscript "$5" "$d/script"
  # a fresh page cache per run, with the last run's pages: the launch shows them, typing re-typesets (as for the user)
  PERF_APP=$1 "$here/keys.sh" "$d" "$d/$title" "$sock" "$d/script" "$(secs "$5")" \
    TAUDOT_EDITOR_MODE="$3" TAUDOT_ENGINE="$4" TAUDOT_PAGE_CACHE="$d/cache" >/dev/null 2>&1 || true
  kill "$mock_pid" 2>/dev/null || true; mock_pid=
  rm -rf "$d/$title" "$d/cache"
  uv run -q "$here/latency.py" "$d" --json > "$d/latency.json" 2>/dev/null || echo '{}' > "$d/latency.json"
}

if [ -n "$compare" ]; then
  for side in A B; do
    rev=$revA; [ $side = B ] && rev=$revB
    wt="$out/src-$side"
    [ -d "$wt" ] || git -C "$repo" worktree add -q --detach "$wt" "$rev"
    git -C "$wt" checkout -q --detach "$rev"
    (cd "$wt/clients/mac" && swift build -c release --product taudot-app >/dev/null 2>&1) || { echo "run.sh: build of $rev failed" >&2; exit 2; }
    mkapp "$(cd "$wt/clients/mac" && swift build -c release --show-bin-path)/taudot-app" "$out/$side.app"
  done
  for m in $modes; do for e in $engines; do for s in $scripts; do
    k=1
    while [ $k -le "$runs" ]; do
      for side in A B; do
        echo "run.sh: $side $m $e $s $k" >&2
        one "$out/$side.app/Contents/MacOS/taudot-app" "$out/$side/$m-$e-$s-$k" "$m" "$e" "$s"
      done
      k=$((k + 1))
    done
  done; done; done
  for side in A B; do git -C "$repo" worktree remove --force "$out/src-$side" 2>/dev/null || true; done
  uv run -q "$here/benchsum.py" --compare "$out/A" "$out/B" --margin "$margin" --labels "$revA" "$revB" | tee "$out/compare.md"
  exit "$(cat "$out/compare.status" 2>/dev/null || echo 0)"
fi

mkapp "${PERF_APP:-"$bundle/Contents/MacOS/taudot-app"}" "$out/bench.app"
app="$out/bench.app/Contents/MacOS/taudot-app"
for m in $modes; do for e in $engines; do for s in $scripts; do
  k=1
  while [ $k -le "$runs" ]; do
    echo "run.sh: $m $e $s $k" >&2
    one "$app" "$out/$m-$e-$s-$k" "$m" "$e" "$s"
    k=$((k + 1))
  done
done; done; done
commit=$(git -C "$repo" rev-parse --short HEAD)$(git -C "$repo" diff --quiet || echo "+dirty")
uv run -q "$here/benchsum.py" "$out" --commit "$commit" --load "$(sysctl -n vm.loadavg)" | tee "$out/summary.md"
[ -n "$write" ] && uv run -q "$here/benchsum.py" "$out" --commit "$commit" --load "$(sysctl -n vm.loadavg)" --write "$repo/clients/mac/Tests/perf/README.md"
echo "run.sh: $out" >&2
