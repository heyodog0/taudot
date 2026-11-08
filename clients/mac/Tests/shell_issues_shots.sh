#!/bin/sh
# Screenshots of LaTeX errors (docs/agents/errors.md): a small broken project (an unbalanced }, an unknown command, an
# undefined citation and reference, an overfull line) typeset for real in taudot-app (CONFIG=debug|release), off
# screen (TAUDOT_ISSUESSHOT): the issues strip over the PDF collapsed, expanded, atop the editor column with the PDF
# hidden, then "Fix all with Claude" (the prompt typed in Claude's pane, here a fake `claude` that echoes). Window
# captures (`screencapture -l`) into OUT (default /tmp/txs-issues-shots): issues-strip-collapsed.png,
# issues-strip-expanded.png, issues-strip-editor.png, issues-fix-all.png.
#   swift build --product taudot-app && clients/mac/Tests/shell_issues_shots.sh [OUT]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MAC=$(cd "$HERE/.." && pwd)
REPO=$(cd "$MAC/../.." && pwd)
. "$HERE/shell_lib.sh"
OUT=${1:-/tmp/txs-issues-shots}; mkdir -p "$OUT"
W=$(mktemp -d); mkdir -p "$W/proj" "$W/bin"
printf '#!/bin/sh\necho "claude (fake, for the screenshot)"\nexec cat\n' > "$W/bin/claude"; chmod +x "$W/bin/claude"
cat > "$W/proj/main.tex" <<'TEX'
\documentclass{article}
\begin{document}
\section{Introduction}
Error handling should be clean and minimal, as in \cite{knuth84,lamport94}.
We define the operator \foobar{x} and use it below.
The result holds for every $n$ } as shown in Section~\ref{sec:proof}.
\hbox to 2in{This sentence is much too long for a two inch box.}
\bibliographystyle{plain}
\bibliography{refs}
\end{document}
TEX
cat > "$W/proj/refs.bib" <<'BIB'
@article{lamport94,
  author = {Leslie Lamport},
  title = {A Document Preparation System},
  journal = {},
  year = {1994}
}
BIB
ES=/tmp/txs-shots$$.sock
on_exit 'rm -f "$ES"; rm -rf "$W"'
deno run -A "$REPO/clients/mock-engine/main.ts" --folder "$W/proj" --socket "$ES" >"$W/mock.log" 2>&1 &
started $!
i=0; while [ ! -S "$ES" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.1; done
TAUDOT_SOCKET="$ES" TAUDOT_CLAUDE="$W/bin/claude" TAUDOT_ISSUESSHOT="$W/win.txt" TAUDOT_COMMENTS=hidden TAUDOT_DEBUG=1 \
  "$APP_BIN" "$W/proj" >"$W/app.log" 2>&1 &
started $!
for state in collapsed expanded editor fixall; do
  i=0; while ! grep -q "^$state " "$W/win.txt" 2>/dev/null && [ $i -lt 400 ]; do i=$((i+1)); sleep 0.1; done
  N=$(sed -n "s/^$state //p" "$W/win.txt")
  [ -n "$N" ] || { echo "FAIL: no $state state"; tail -20 "$W/app.log"; exit 1; }
  case $state in collapsed) f=issues-strip-collapsed;; expanded) f=issues-strip-expanded;; editor) f=issues-strip-editor;; fixall) f=issues-fix-all;; esac
  screencapture -x -o -l"$N" "$OUT/$f.png"
  echo "$OUT/$f.png"
done
cp "$W/app.log" "$OUT/app.log"
# The typesetter's log reached the app (TaudotPDFPane.onDriverLine): both errors and the undefined citation and
# reference (warnings, lines 4 and 6), not just errors; the overfull box (line 7) isn't shown (engine-dependent).
# BibTeX's .blg (onBibIssues): the missing knuth84 and lamport94's empty journal, both at their \cite (line 4;
# BibTeX gives no .bib line for these): with TeX's undefined citation, three warnings on line 4.
GOT=$(sed -n 's/^issues //p' "$W/win.txt")
echo "issues: $GOT"
case " $GOT " in *" B"*) echo "FAIL: a badbox is shown"; exit 1;; esac
for want in E5 E6 W4 W6; do
  case " $GOT " in *" $want "*) ;; *) echo "FAIL: no $want in the issues (from TeX's log and BibTeX's)"; exit 1;; esac
done
[ "$(echo "$GOT" | tr ' ' '\n' | grep -cx W4)" -ge 3 ] || { echo "FAIL: BibTeX's warnings aren't at their \\cite (line 4)"; exit 1; }
echo "ok   errors and warnings from TeX's log and BibTeX's"
