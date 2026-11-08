#!/bin/sh
# Keystroke → frame written, from the preview's own trace, in a background Rex session (nothing is brought to the
# front, so no pixels: "drawn" is when the frame with the changed page was written to the terminal).
#   trace-latency.sh CONFIG DOC_DIR AT LINE N [ZOOM_KEYS]
# CONFIG: tectonic | txp-file | txp-live. ZOOM_KEYS: keys sent to the preview first, e.g. "++++" to get tiled pages.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
pv="$here/.."
config=$1 doc=$2 at=$3 line=$4 n=$5 zoom=${6:-}
work="${TMPDIR:-/tmp}/txp-trace-bench"
rm -rf "$work"; mkdir -p "$work"
cp -R "$doc" "$work/doc"
F="$work/doc"
esock="$work/engine.sock" psock="$work/pv.sock"
deno run -A "$pv/../mock-engine/main.ts" --folder "$F" --socket "$esock" >"$work/engine.log" 2>&1 &
mock=$!
sid=""
trap 'kill $mock 2>/dev/null || true; [ -n "$sid" ] && rex kill "$sid" </dev/null >/dev/null 2>&1 || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$esock" ] && break; sleep 0.3; done
extra=""
case $config in
  tectonic) ;;
  txp-file) extra="--engine texpresso" ;;
  txp-live) extra="--engine texpresso --taudot-socket $esock" ;;
esac
# shellcheck disable=SC2086
sid=$(rex new txp-trace -c "$F" --json -- deno run -A "$pv/preview.ts" --folder "$F" --listen "$psock" \
  --trace "$work/trace.jsonl" --out "$work/out" $extra </dev/null | jq -r .session_id)
sleep 5
if [ -n "$zoom" ]; then printf '{"input":"%s"}\n' "$zoom" | nc -U -w 1 "$psock" || true; sleep 2; fi
printf '{"cursor":{"path":"main.tex","line":%s}}\n' "$line" | nc -U -w 1 "$psock" || true
sleep 3
deno run -A - "$esock" "$at" "$n" <<'EOF'
const [sock, at, n] = Deno.args;
const conn = await Deno.connect({ transport: "unix", path: sock });
const enc = new TextEncoder(), dec = new TextDecoder();
let id = 0, buf = "";
const waiting = new Map();
(async () => { for await (const c of conn.readable) { buf += dec.decode(c, { stream: true }); let nl;
  while ((nl = buf.indexOf("\n")) >= 0) { const m = JSON.parse(buf.slice(0, nl)); buf = buf.slice(nl + 1);
    if (m.id !== undefined) { waiting.get(m.id)?.(m.result); waiting.delete(m.id); } } } })();
const call = (method, params) => new Promise((r) => { const i = ++id; waiting.set(i, r);
  conn.write(enc.encode(JSON.stringify({ jsonrpc: "2.0", id: i, method, params }) + "\n")); });
const p = await call("project.open", {});
const d = await call("doc.open", { project_id: p.project_id, path: "main.tex" });
let seq = d.seq;
const pos = enc.encode(d.text.slice(0, d.text.indexOf(at) + at.length)).length;
for (let k = 0; k < Number(n); k++) {
  const r = await call("doc.edit", { doc_id: d.doc_id, seq, edits: k % 2 ? [{ pos, del: 1, ins: "" }] : [{ pos, del: 0, ins: "x" }] });
  seq = r.seq;
  console.log(JSON.stringify({ key: k, t: Date.now() }));
  await new Promise((r) => setTimeout(r, 3000));
}
Deno.exit(0);
EOF
echo "trace: $work/trace.jsonl" >&2
