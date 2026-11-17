#!/bin/sh
# Outside edits on the local Overleaf CE (syncfix): taudot-app off screen on a fresh project our own engine mirrors
# (Alice, user1). Another process edits the folder as a Claude session does (in-place saves to the open file and to an
# \input file, `taudot rpc project.open`, bursts), then Bob's engine (user2) sends multi-hunk doc.edit batches with
# non-ASCII text, one hunk in the preamble, as another machine's engine would. After each step, every marker on disk
# must be in the window's newest PDF exactly once.
#   swift build --product taudot-app && cargo build -p taudot-engine && clients/mac/Tests/outside_ce.sh [native|neovim]
# TAUDOT_UNIVERSAL picks the tau-live build (default: the app's). Before the fix to fresh engines (tau-live passes
# TAU_SEQ) the first edit that started one froze the PDF for good.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
MAC=$REPO/clients/mac
. "$HERE/shell_lib.sh"
env_file=${TAUDOT_ENV_FILE:-$HOME/code/lab/taudot/docker/.env.test}
ENG=${ENG:-$REPO/target/debug/taudot}
H=$(mktemp -d /tmp/oce.XXXX); H2=$(mktemp -d /tmp/oce.XXXX)  # (engine sockets: short paths)
W=$(mktemp -d); mkdir -p "$W/proj" "$W/seed/sections"
on_exit "rm -rf $H $H2 $W"
cat > "$W/seed/main.tex" <<'EOF'
\documentclass{article}
\begin{document}
\section{Alpha}
Alpha one is the first paragraph of the main file and it has some words in it.

Alpha two is the second paragraph of the main file and it has some words in it.

\input{sections/intro}

\section{Omega}
Omega one closes the main file with a few more words in it.
\end{document}
EOF
cat > "$W/seed/sections/intro.tex" <<'EOF'
\section{Intro}
Intro one is the first paragraph of the input file with words.

Intro two is the second paragraph of the input file with words.
EOF
pid_project=$(TAUDOT_ENV_FILE=$env_file "$REPO/docker/seed.sh" --name "outside edits" --from "$W/seed" --reset) || exit 1
printf '{"project": "%s"}\n' "$pid_project" > "$W/proj/.taudot.json"
url=$(sed -n 's/^OVERLEAF_URL=//p' "$env_file")
"$ENG" serve --url "$url" --env-file "$env_file" --user user1 --home "$H" >"$W/engine.log" 2>&1 &
started $!
i=0; while [ ! -S "$H/engine.sock" ] && [ $i -lt 200 ]; do i=$((i+1)); sleep 0.05; done
rpc() { "$ENG" rpc --home "$H" "$@"; }
rpc project.open "{\"folder\": \"$W/proj\"}" >/dev/null || exit 1
env TAUDOT_SOCKET="$H/engine.sock" TAUDOT_EDITOR_MODE=${1:-native} TAUDOT_OFFSCREEN=1 \
  TAUDOT_PDF_CHECK="$W/check.log" \
  ${TAUDOT_UNIVERSAL:+TAUDOT_UNIVERSAL=$TAUDOT_UNIVERSAL} \
  "$MAC/.build/debug/taudot-app" "$W/proj" >"$W/app.log" 2>&1 &
APP=$!; started $APP

LT=$(getconf DARWIN_USER_TEMP_DIR)
on_exit "rm -rf $LT/taudot-live-$APP-*"
newest_pdf() { f=$(find "$LT" -maxdepth 1 -name "taudot-live-$APP-*" 2>/dev/null); [ -n "$f" ] || return; find $f -name "*.pdf" -size +1k -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1; }

# Claude's Edit tool: read, replace one exact string, write the file in place.
edit() { uv run --no-project python - "$W/proj/$1" "$2" "$3" <<'PY'
import sys
p, a, b = sys.argv[1:]
t = open(p).read()
assert t.count(a) == 1, (p, a, t.count(a))
open(p, "w").write(t.replace(a, b))
PY
}
fails=0
last=""
check() {  # STEP: every marker on disk once in the newest PDF, no marker that's gone from disk
  sleep "${WAIT:-6}"
  pdf=$(newest_pdf)
  m=$(stat -f %Fm "$pdf" 2>/dev/null); if [ -z "$pdf" ] || [ "$m" = "$last" ]; then echo "FAIL $1: no new PDF";  fails=$((fails+1)); return; fi
  last=$m
  pdftotext -raw "$pdf" "$W/pdf.txt" 2>/dev/null || { echo "FAIL $1: unreadable $pdf"; fails=$((fails+1)); return; }
  cat "$W/proj/main.tex" "$W/proj/sections/intro.tex" > "$W/disk.txt"
  bad=""
  for m in $(grep -o 'MK[0-9a-z]*' "$W/disk.txt" | sort -u); do
    n=$(grep -ow "$m" "$W/pdf.txt" | wc -l | tr -d ' '); want=$(grep -ow "$m" "$W/disk.txt" | wc -l | tr -d ' ')
    [ "$n" = "$want" ] || bad="$bad $m:$n/$want"
  done
  for m in $(grep -o 'MK[0-9a-z]*' "$W/pdf.txt" | sort -u); do grep -qw "$m" "$W/disk.txt" || bad="$bad gone:$m"; done
  if [ -n "$bad" ]; then echo "FAIL $1:$bad"; fails=$((fails+1)); else echo "ok   $1"; fi
}
i=0; while [ -z "$(newest_pdf)" ] && [ $i -lt 600 ]; do i=$((i+1)); sleep 0.1; done
sleep 3; last=$(stat -f %Fm "$(newest_pdf)")

edit main.tex "Alpha one is" "Alpha one MKa1 is"; check "main.tex edit"
edit sections/intro.tex "Intro one is" "Intro one MKi1 is"; check "input file edit"
rpc project.open "{\"folder\": \"$W/proj\"}" >/dev/null; echo "(second session's project.open)"
edit main.tex "Alpha two is" "Alpha two MKa2 is"; check "main.tex after project.open"
edit sections/intro.tex "Intro two is" "Intro two MKi2 is"; check "input after project.open"
for k in 1 2 3 4 5; do edit main.tex "Omega one" "Omega MKb$k one"; edit main.tex "Omega MKb$k one" "Omega one MKb$k"; sleep 0.15; done
WAIT=8 check "burst in main.tex"
for k in 1 2 3 4; do edit sections/intro.tex "Intro one" "Intro one MKc$k"; sleep 0.1; done
WAIT=8 check "burst in input file"
edit main.tex "MKa1 " ""; edit sections/intro.tex "MKi1 " ""; check "deletes"
"$ENG" serve --url "$url" --env-file "$env_file" --user user2 --home "$H2" >"$W/engine2.log" 2>&1 &
started $!
i=0; while [ ! -S "$H2/engine.sock" ] && [ $i -lt 200 ]; do i=$((i+1)); sleep 0.05; done
bob() { uv run --no-project python "$HERE/outside_ce_bob.py" "$H2/engine.sock" "$pid_project" "$@"; }
bob main.tex '\begin{document}=>% Bob é\n\begin{document}' 'Alpha two=>Alpha two MKr1 café' 'Omega one=>Omega one “MKr2” — ü'
check "remote 3 hunks (preamble, non-ASCII)"
bob sections/intro.tex 'Intro one=>Intro one MKr3 naïve' 'Intro two=>Intro two — MKr4'
check "remote 2 hunks in input file"
bob main.tex 'MKr1 café=>MKr5 thé' '“MKr2” — ü=>MKr6 Æ'
check "remote replaces"
bob main.tex '% Bob é=>% Bob ö again'
check "remote preamble edit"
grep -E "DRIFT|bad " "$W/check.log" | head
echo "fails: $fails"
[ "$fails" = 0 ]
