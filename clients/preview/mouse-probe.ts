// Shows which mouse events the terminal passes to a program, one line per event kind, with a count.
//
//   deno run -A clients/preview/mouse-probe.ts            (q to quit)
//
// Turns on the same mouse modes as the preview (1002 drag, 1006 SGR, 1016 SGR pixels). Try plain wheel, trackpad
// scroll, Ctrl/Alt(Option)/Shift/Cmd + wheel, pinch, clicks and double-clicks; anything Rex keeps for itself never
// shows up here.

import { splitInput } from "./lib.ts";

const enc = new TextEncoder(), dec = new TextDecoder();
const out = (s: string) => Deno.stdout.writeSync(enc.encode(s));
Deno.stdin.setRaw(true);
out("\x1b[?1049h\x1b[?25l\x1b[?1002h\x1b[?1006h\x1b[?1016h\x1b[H\x1b[2J");
const counts = new Map<string, number>();
const order: string[] = [];
let lastClick = 0;

function draw(last: string) {
  out("\x1b[H\x1b[2J\x1b[1mmouse probe\x1b[22m  (q quits)\r\n\x1b[2mtry: wheel, trackpad, Ctrl/Option/Shift/Cmd + wheel, " +
    "pinch, click, double-click\x1b[22m\r\n\r\n");
  for (const k of order) out(`  ${String(counts.get(k)).padStart(5)}  ${k}\r\n`);
  out(`\r\n\x1b[2mlast: ${last}\x1b[22m\r\n`);
}
draw("");

const buf = new Uint8Array(4096);
while (true) {
  const n = await Deno.stdin.read(buf);
  if (n === null) break;
  const raw = dec.decode(buf.subarray(0, n));
  const { keys, mouse } = splitInput(raw);
  if (keys.includes("q") || keys.includes("\x03")) break;
  for (const m of mouse) {
    const mods = [m.ctrl && "ctrl", m.alt && "alt", m.shift && "shift"].filter(Boolean).join("+");
    let kind = m.wheel ? `wheel ${m.wheel}` : `button ${m.button}${m.motion ? " drag" : ""}${m.release ? " release" : ""}`;
    if (!m.wheel && !m.motion && !m.release && m.button === 0) {
      const now = Date.now();
      if (now - lastClick < 400) kind += " (2nd within 400 ms)";
      lastClick = now;
    }
    if (mods) kind += ` [${mods}]`;
    if (!counts.has(kind)) order.push(kind);
    counts.set(kind, (counts.get(kind) ?? 0) + 1);
  }
  if (mouse.length) draw(JSON.stringify(raw).slice(1, -1).slice(0, 60));
}
out("\x1b[?1016l\x1b[?1006l\x1b[?1002l\x1b[?25h\x1b[?1049l");
Deno.stdin.setRaw(false);
console.log([...order].map((k) => `${counts.get(k)}\t${k}`).join("\n"));
