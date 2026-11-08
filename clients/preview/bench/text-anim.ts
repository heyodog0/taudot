// Text that changes every PERIOD ms: the alternate screen shows a text file scrolled up one line per tick.
//   deno run -A text-anim.ts FILE [PERIOD_MS] [SECONDS]
const lines = (await Deno.readTextFile(Deno.args[0])).split("\n").filter((l) => l.trim());
const period = Number(Deno.args[1] ?? 8), secs = Number(Deno.args[2] ?? 4);
const { columns, rows } = Deno.consoleSize();
const enc = new TextEncoder();
const w = (s: string) => Deno.stdout.writeSync(enc.encode(s));
w("\x1b[?1049h\x1b[?25l");
const t0 = performance.now();
let i = 0;
while (performance.now() - t0 < secs * 1000) {
  let s = "\x1b[H";
  for (let r = 0; r < rows; r++) s += (lines[(i + r) % lines.length].slice(0, columns)).padEnd(columns) + (r < rows - 1 ? "\r\n" : "");
  w(s);
  i++;
  const next = t0 + i * period;
  while (performance.now() < next - 1) await new Promise((r) => setTimeout(r, 1));
}
w("\x1b[?25h\x1b[?1049l");
