#!/bin/sh
# The first run on a clean account, without making a macOS user: Taudot.app run under sandbox-exec with the user's
# real home folder, /opt/homebrew and /usr/local unreadable, HOME (and CFFIXED_USER_HOME) an empty scratch folder and
# PATH=/usr/bin:/bin. So no TeX install, no Homebrew, no repo, no Tectonic, no caches of this Mac.
#
#   tools/release/clean-run.sh Taudot.app [WORK]        (WORK: a scratch folder outside your home; default mktemp)
#
# Checks, each printed as "ok:" or "FAIL:":
#   1. the bundle's programs start (taudot, nvim, texpresso-xetex, txp-render, the live pdfTeX) and load nothing
#      from outside the system and the bundle (DYLD_PRINT_LIBRARIES);
#   2. a local pdfLaTeX project typesets (the live pdfTeX, TeX Live fetched from the store);
#   3. a local XeLaTeX project typesets (TeXpresso, the TeX bundle fetched by the tectonic stand-in);
#   4. a CE project (created on the local Overleaf CE as user1, cloned by the bundle's engine) opens and typesets.
# The app runs off screen (TAUDOT_OFFSCREEN=1, background activation) and quits by itself. The engine runs as a child
# of the sandbox (TAUDOT_NO_SERVICE=1: a launch agent would run outside the sandbox; tools/release/agent-test.sh
# checks the agent on its own). CE credentials come from ~/code/lab/taudot/docker/.env.test (copied into WORK for the
# run, deleted after); skip check 4 with NO_CE=1.
set -u
app=$(cd "$1" && pwd)
work=${2:-$(mktemp -d /private/tmp/taudot-clean.XXXXXX)}
mkdir -p "$work"
work=$(cd "$work" && pwd -P)
case "$work" in "$HOME"/*) echo "WORK must be outside $HOME (the sandbox denies it)" >&2; exit 2 ;; esac
h="$work/home"
rm -rf "$h" && mkdir -p "$h" "$work/tmp" "$work/logs"
real_home=$HOME
fails=0
ok() { echo "ok: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

cat > "$work/clean.sb" <<SB
(version 1)
(allow default)
(deny file-read* file-write* file-map-executable process-exec
  (subpath "/opt/homebrew") (subpath "/usr/local") (subpath "$real_home"))
SB

# run CMD...: in the sandbox with the clean environment (extra VAR=value words may come first)
run() {
  sandbox-exec -f "$work/clean.sb" /usr/bin/env -i HOME="$h" CFFIXED_USER_HOME="$h" PATH=/usr/bin:/bin USER="$USER" \
    LOGNAME="$USER" SHELL=/bin/zsh TMPDIR="$work/tmp/" LANG=en_US.UTF-8 TAUDOT_NO_SERVICE=1 "$@"
}

# 0. the sandbox works: Homebrew's and the real home's files are out of reach
if run /bin/ls /opt/homebrew/bin >/dev/null 2>&1 || run /bin/ls "$real_home" >/dev/null 2>&1; then
  fail "the sandbox doesn't hide /opt/homebrew or $real_home"; exit 1
fi
ok "sandbox: /opt/homebrew, /usr/local and $real_home are unreadable"

# 1. every program starts; DYLD_PRINT_LIBRARIES lists what each one loads
c="$app/Contents"
check_libs() {  # NAME LOGFILE
  bad=$(grep -E '^dyld\[[0-9]+\]: <[^>]*> ' "$2" | sed 's/.*> //' | grep -v -e '^/System/' -e '^/usr/lib/' -e "^$c/" | sort -u)
  if [ -n "$bad" ]; then fail "$1 loaded $bad"; else ok "$1 starts, loads only the system's and the bundle's libraries"; fi
}
run DYLD_PRINT_LIBRARIES=1 "$c/MacOS/taudot" --version > "$work/logs/taudot.out" 2>&1 && check_libs taudot "$work/logs/taudot.out" || fail "taudot --version"
run DYLD_PRINT_LIBRARIES=1 "$c/Resources/neovim/bin/nvim" --headless -u NONE +q > "$work/logs/nvim.out" 2>&1 && check_libs nvim "$work/logs/nvim.out" || fail "nvim"
run DYLD_PRINT_LIBRARIES=1 "$c/Resources/texpresso/texpresso-xetex" --help > "$work/logs/xetex.out" 2>&1; check_libs texpresso-xetex "$work/logs/xetex.out"
echo '\relax' | run DYLD_PRINT_LIBRARIES=1 "$c/Resources/txp-render" /dev/null > "$work/logs/txp.out" 2>&1; check_libs txp-render "$work/logs/txp.out"
for y in "$c"/Resources/pdftex/*/; do
  run DYLD_PRINT_LIBRARIES=1 "$y/pdftex" --version > "$work/logs/pdftex.out" 2>&1; check_libs "pdftex $(basename "$y")" "$work/logs/pdftex.out"
done

# open FOLDER NAME: the app on FOLDER until the PDF pane says it typeset (or 240 s), then it quits.
open_project() {
  log="$work/logs/app-$2.log"
  set -m
  run TAUDOT_OFFSCREEN=1 TAUDOT_DEBUG=1 TAUDOT_TIMELINE=1 TAUDOT_SOCKET="$h/.taudot/engine.sock" \
    "$c/MacOS/taudot-app" "$1" > "$log" 2>&1 &
  pid=$!
  set +m
  t=0 typeset=""
  while [ $t -lt 240 ] && kill -0 $pid 2>/dev/null; do
    typeset=$(grep -m1 -E 'pdf status: [0-9]+ pages?, typeset' "$log")
    [ -n "$typeset" ] && break
    sleep 1; t=$((t + 1))
  done
  kill -TERM -- -$pid 2>/dev/null; sleep 2; kill -KILL -- -$pid 2>/dev/null
  if [ -n "$typeset" ]; then ok "$2: ${typeset#*pdf status: } (first PDF after ${t} s)"
  else fail "$2: no typeset PDF in ${t} s ($log: $(grep 'pdf status' "$log" | tail -1))"; fi
}

mkdir -p "$h/Documents/pdf-local" "$h/Documents/xe-local"
cat > "$h/Documents/pdf-local/main.tex" <<'TEX'
\documentclass{article}
\usepackage{amsmath,graphicx,hyperref}
\title{A clean account}
\begin{document}
\maketitle
\section{pdfLaTeX}
Typeset by the live pdfTeX inside Taudot.app, with TeX Live fetched on demand. $\int_0^1 x^2\,dx = \tfrac13$.
\end{document}
TEX
cat > "$h/Documents/xe-local/main.tex" <<'TEX'
\documentclass{article}
\usepackage{fontspec}
\setmainfont{Latin Modern Roman}
\usepackage{amsmath,amssymb,graphicx,xcolor,booktabs,geometry,hyperref}
\begin{document}
\section{XeLaTeX}
Typeset by TeXpresso inside Taudot.app — Unicode: café, naïve, Ελληνικά? $e^{i\pi}+1=0$.
\end{document}
TEX
open_project "$h/Documents/pdf-local" pdflatex-local
open_project "$h/Documents/xe-local" xelatex-local

# 4. a CE project of our own, cloned by the bundle's engine
envsrc="$real_home/code/lab/taudot/docker/.env.test"
if [ -z "${NO_CE:-}" ] && [ -f "$envsrc" ]; then
  cp "$envsrc" "$work/ce.env"
  url=$(sed -n 's/^OVERLEAF_URL=//p' "$work/ce.env")
  name="release-clean-$(date +%Y%m%d-%H%M%S)"
  r=$(run "$c/MacOS/taudot" rpc --home "$h/.taudot" --env-file "$work/ce.env" --user user1 project.create \
    "{\"url\":\"$url\",\"name\":\"$name\"}" 2>&1)
  id=$(printf '%s' "$r" | sed -n 's/.*"project_id": *"\([0-9a-f]*\)".*/\1/p')
  if [ -z "$id" ]; then fail "CE: project.create: $r"
  else
    if run "$c/MacOS/taudot" clone --home "$h/.taudot" --env-file "$work/ce.env" --user user1 "$url/project/$id" \
      "$h/Overleaf/$name" > "$work/logs/clone.log" 2>&1; then
      ok "CE: cloned $name ($id) with the bundle's engine"
      open_project "$h/Overleaf/$name" ce-project
    else fail "CE: clone: $(tail -2 "$work/logs/clone.log")"; fi
  fi
  rm -f "$work/ce.env"
fi

# the engine the runs started (a child of the sandbox): stop it by its socket's owner
sock="$h/.taudot/engine.sock"
for p in $(/usr/sbin/lsof -t "$sock" 2>/dev/null); do kill -TERM "$p" 2>/dev/null; done

echo "logs: $work/logs"
[ $fails = 0 ] && echo "clean run: all checks passed" || echo "clean run: $fails failed"
exit $fails
