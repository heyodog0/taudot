#!/bin/sh
# The find bar in the app (FindCheck.swift, TAUDOT_FINDCHECK), off screen, against the mock engine, in both editor
# modes: ⌘F, typing, counts, Enter / ⌘G / ⇧⌘G, Esc, `/` and n, replace one and all, undo, keystroke timing.
#   swift build --product taudot-app && clients/mac/Tests/find_app.sh [native|neovim|both] [FOLDER-OR-FILE.tex]
# Without a file: a small made-up paper (safe to screenshot). SHOTS=DIR: window captures there (find-<mode>*.png).
# THEME=<editor theme id> for native mode (default tokyo-night; catppuccin-latte for light). WORD=<word to search>.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MAC=$(cd "$HERE/.." && pwd)
REPO=$(cd "$MAC/../.." && pwd)
. "$HERE/shell_lib.sh"
MODES=${1:-both}
[ "$MODES" = both ] && MODES="native neovim"
SRC=${2:-}
W=$(mktemp -d)
on_exit 'rm -rf "$W"'
FAILED=0
for MODE in $MODES; do
  rm -rf "$W/proj"; mkdir -p "$W/proj"
  if [ -z "$SRC" ]; then
    cat > "$W/proj/main.tex" <<'TEX'
\documentclass{article}
\usepackage{amsmath}
\title{Learning to Explore with a World Model}
\begin{document}
\maketitle
\section{Introduction}
A world model predicts what comes next. We train the model on short clips and ask
the model to imagine longer ones; a good model keeps objects where they were.
\section{Method}
Our Model has two parts: an encoder $f_\theta$ and a dynamics model $g_\phi$, with
\begin{equation}
  z_{t+1} = g_\phi(z_t, a_t), \qquad z_0 = f_\theta(x_0).
\end{equation}
\section{Results}
The model explores twice as far as the baseline (Table~\ref{tab:main}).
\end{document}
TEX
  elif [ -d "$SRC" ]; then cp -R "$SRC/." "$W/proj/"; rm -f "$W/proj/.taudot.json"
  else cp "$SRC" "$W/proj/main.tex"; fi
  ES=/tmp/txs-find$$.sock
  rm -f "$ES"
  deno run -A "$REPO/clients/mock-engine/main.ts" --folder "$W/proj" --socket "$ES" >"$W/mock.log" 2>&1 &
  started $!
  i=0; while [ ! -S "$ES" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.1; done
  rm -f "$W/out.txt"
  env TAUDOT_NO_PDF=1 TAUDOT_SOCKET="$ES" TAUDOT_EDITOR_MODE="$MODE" TAUDOT_FINDCHECK="$W/out.txt" \
    ${SHOTS:+TAUDOT_FINDCHECK_SHOTS="$SHOTS"} ${WORD:+TAUDOT_FINDCHECK_WORD="$WORD"} TAUDOT_COMMENTS=hidden \
    "$APP_BIN" "$W/proj" -taudot.editorTheme "${THEME:-tokyo-night}" >"$W/app.log" 2>&1 &
  APP=$!; started $APP
  i=0; while kill -0 $APP 2>/dev/null && [ ! -s "$W/out.txt" ] && [ $i -lt 1200 ]; do i=$((i+1)); sleep 0.1; done
  echo "== $MODE"
  if [ -s "$W/out.txt" ]; then cat "$W/out.txt"; else echo "FAIL no output"; tail -30 "$W/app.log"; FAILED=1; fi
  grep -q FAIL "$W/out.txt" 2>/dev/null && FAILED=1
  stop_all
  rm -f "$ES"
done
exit $FAILED
