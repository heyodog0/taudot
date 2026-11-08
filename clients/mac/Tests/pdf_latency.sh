#!/bin/sh
# Keystroke → changed page on screen, in the real app: taudot-app (CONFIG=debug|release, or APP_BIN) on a COPY of
# FOLDER (or $TAUDOT_PERF_DOC; never written; a long paper with main.tex), the mock engine, Neovim typing at human
# speed (Tests/pdf_latency.lua: the abstract, then a later section; PART_SECONDS each, default 60). The pane's
# self-check (TAUDOT_PDF_CHECK) logs each engine edit's arrival and the swap of the changed page in view; each
# keystroke is timed to the swap of the first edit that arrived after it. Prints p50/p95/max per part, the longest
# wait for any update while typing, and txp-headless restarts. Exit 1 when p50 > 150 ms, p95 > 400 ms, a wait over
# 1 s, or a restart. KEEP=1 keeps the logs.
#   swift build -c release --product taudot-app && CONFIG=release clients/mac/Tests/pdf_latency.sh [FOLDER]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MAC=$(cd "$HERE/.." && pwd)
REPO=$(cd "$MAC/../.." && pwd)
SRC=${1:-${TAUDOT_PERF_DOC:-}}
[ -n "$SRC" ] && [ -f "$SRC/main.tex" ] || { echo "pdf_latency.sh: pass FOLDER or set TAUDOT_PERF_DOC (a project folder with main.tex)" >&2; exit 2; }
W=$(mktemp -d)
mkdir -p "$W/proj"
cp -R "$SRC/." "$W/proj/"
rm -f "$W/proj/.taudot.json"
ES=/tmp/txs-pdflat$$.sock
deno run -A "$REPO/clients/mock-engine/main.ts" --folder "$W/proj" --socket "$ES" >"$W/mock.log" 2>&1 &
MOCK=$!
i=0; while [ ! -S "$ES" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.1; done
TYPE_LOG="$W/type.log" TAUDOT_SOCKET="$ES" TAUDOT_PDF_CHECK="$W/check.log" TAUDOT_TXP_LOG="$W/txp.log" \
  TAUDOT_EXEC="dofile('$HERE/pdf_latency.lua')" "${APP_BIN:-$MAC/.build/${CONFIG:-debug}/taudot-app}" "$W/proj" >"$W/app.log" 2>&1 &
APP=$!
i=0
while [ $i -lt 400 ] && ! grep -q '^end' "$W/type.log" 2>/dev/null; do kill -0 $APP 2>/dev/null || break; i=$((i+1)); sleep 1; done
sleep 4
kill $APP 2>/dev/null; kill $MOCK 2>/dev/null; rm -f "$ES"
uv run --no-project python - "$W" <<'PY'
import sys, re, statistics
w = sys.argv[1]
keys, parts = [], []
for l in open(f"{w}/type.log"):
    f = l.split()
    if f[0] == "key": keys.append(float(f[1]))
    elif f[0] == "part": parts.append((f[1], float(f[2])))
arrived, shown, restarts = [], [], 0
for l in open(f"{w}/check.log"):
    m = re.search(r"edit shown: arrived ([\d.]+) report ([\d.]+) shown ([\d.]+)", l)
    if m: shown.append((float(m[1]), float(m[3])))
    m = re.search(r"edit offscreen: arrived ([\d.]+)", l)
    if m: shown.append((float(m[1]), None))
    if "txp restarted" in l: restarts += 1
shown.sort()
fail = False
updates = sorted(s for _, s in shown if s)
for i, (name, t0) in enumerate(parts):
    t1 = parts[i + 1][1] if i + 1 < len(parts) else 1e18
    ks = [k for k in keys if t0 <= k < t1]
    lat, missing = [], 0
    for k in ks:
        nxt = next(((a, s) for a, s in shown if a >= k), None)
        if nxt is None or nxt[1] is None: missing += 1; continue
        lat.append((nxt[1] - k) * 1000)
    if not lat: print(f"{name}: no measurements"); fail = True; continue
    lat.sort()
    p50 = statistics.median(lat); p95 = lat[int(0.95 * (len(lat) - 1))]
    # the longest time typing went on with nothing new on screen
    up = [u for u in updates if ks[0] <= u <= ks[-1] + 2]
    gap = max([b - a for a, b in zip([ks[0]] + up, up + [ks[-1]])] or [0]) * 1000
    print(f"{name}: {len(ks)} keys, {len(lat)} timed ({missing} without a visible change): p50 {p50:.0f} ms, p95 {p95:.0f} ms, max {lat[-1]:.0f} ms; longest wait for an update while typing {gap:.0f} ms")
    if p50 > 150 or p95 > 400 or gap > 1000: fail = True
print(f"txp-headless restarts: {restarts}")
if restarts: fail = True
sys.exit(1 if fail else 0)
PY
r=$?
if [ "${KEEP:-}" = 1 ] || [ $r != 0 ]; then echo "logs: $W"; else rm -rf "$W"; fi
exit $r
