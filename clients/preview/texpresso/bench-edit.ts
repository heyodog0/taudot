// Edit latency of txp-headless: keystroke (a byte change on stdin) → "pages" event for the page in view → that page
// rendered as a fit-width image. Also times tectonic's full compile of the same document for comparison.
//
//   deno run -A bench-edit.ts DIR/main.tex [--at TEXT] [--n 10] [--page P] [--scale 2] [--tectonic]
//
// --at: insert after the first occurrence of TEXT in main.tex (default: the middle of the file). Each run inserts one
// character ("x"), then deletes it on the next run, like typing and backspacing. --page: the page in view (the goal);
// default: the page the edit lands on, found from the first run's `changed`.

import { parseArgs } from "jsr:@std/cli@1/parse-args";
import { dirname, join } from "jsr:@std/path@1";

const args = parseArgs(Deno.args, { string: ["at", "n", "page", "scale", "file"], boolean: ["tectonic"] });
const main = String(args._[0]);
const N = Number(args.n ?? 10);
const scale = Number(args.scale ?? 2);
const here = dirname(new URL(import.meta.url).pathname);
const bin = join(here, "txp-headless");
const xetex = Deno.env.get("TEXPRESSO_XETEX") ?? `${Deno.env.get("HOME")}/code/lab/taudot-ref/texpresso/build/texpresso-xetex`;
const tmp = await Deno.makeTempDir({ prefix: "txp-bench-" });

const mainDir = dirname(main);
const rel = args.file ?? main.split("/").pop()!;
const text = await Deno.readTextFile(join(mainDir, rel));
const enc = new TextEncoder();
const bytes = enc.encode(text);
let at = Math.floor(bytes.length / 2);
if (args.at) {
  const i = text.indexOf(args.at);
  if (i < 0) throw new Error(`--at text not found`);
  at = enc.encode(text.slice(0, i + args.at.length)).length;
} else {
  // land on a space so the edit stays inside a word boundary
  while (at < bytes.length && bytes[at] !== 32) at++;
}

const proc = new Deno.Command(bin, {
  args: ["-tectonic", main],
  env: { TEXPRESSO_XETEX: xetex },
  stdin: "piped",
  stdout: "piped",
  stderr: "piped",
}).spawn();
const w = proc.stdin.getWriter();
const send = (a: unknown[]) => w.write(enc.encode(JSON.stringify(a) + "\n"));
// keep stderr drained (TeXpresso is chatty)
const errLog = await Deno.open(join(tmp, "stderr.txt"), { write: true, create: true });
proc.stderr.pipeTo(errLog.writable);

type Ev = Record<string, unknown>;
const queue: Ev[] = [];
let wake: (() => void) | undefined;
(async () => {
  let buf = "";
  for await (const chunk of proc.stdout.pipeThrough(new TextDecoderStream())) {
    buf += chunk;
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      if (!line.startsWith("{")) continue;
      queue.push(JSON.parse(line) as Ev);
      wake?.();
    }
  }
})();
/** The first queued event matching pred (others stay queued). */
async function next(pred: (e: Ev) => boolean = () => true): Promise<Ev> {
  for (;;) {
    const i = queue.findIndex(pred);
    if (i >= 0) return queue.splice(i, 1)[0];
    await new Promise<void>((r) => (wake = r));
  }
}

const t0 = performance.now();
const first = await next((e) => e.ev === "pages" && e.done === true);
const initMs = performance.now() - t0;
console.log(`initial run: ${first.n} pages in ${initMs.toFixed(0)} ms`);
await send(["open", rel, text]);
// wait in case open caused a rerun (it shouldn't: same text)
await new Promise((r) => setTimeout(r, 300));
queue.length = 0;

let rid = 0;
async function render(page: number, sizes: number[][]) {
  const [pw, ph] = sizes[page];
  const W = Math.ceil(pw * scale), H = Math.ceil(ph * scale);
  const id = ++rid;
  const t = performance.now();
  await send(["render", id, page, scale, 0, 0, W, H, join(tmp, "p.rgb"), join(tmp, "p.z")]);
  const r = await next((e) => e.id === id);
  if (!r.ok) throw new Error(JSON.stringify(r));
  return { ms: performance.now() - t, cpu: Number(r.cpu_us) / 1000, W, H };
}

let goal = args.page !== undefined ? Number(args.page) : -1;
const rows: { pages: number; render: number; total: number; changed: string; step: number }[] = [];
let inserted = false;
for (let k = 0; k < N + 1; k++) {
  if (goal >= 0) await send(["goal", goal]);
  const t = performance.now();
  if (!inserted) await send(["change", rel, at, 0, "x"]);
  else await send(["change", rel, at, 1, ""]);
  inserted = !inserted;
  const ev = await next((e) => e.ev === "pages");
  const tPages = performance.now() - t;
  const changed = ev.changed as number[];
  if (goal < 0) {
    goal = changed.length ? changed[0] : 0;
    console.log(`edit lands on page ${goal + 1}; goal set`);
    // let it finish, then measure from the next edit
    if (!ev.done) await next((e) => e.ev === "pages" && e.done === true);
    continue;
  }
  const r = await render(goal, ev.sizes as number[][]);
  rows.push({
    pages: tPages,
    render: r.ms,
    total: tPages + r.ms,
    changed: changed.length > 6 ? `${changed.slice(0, 3).join(",")}..${changed.length}` : changed.join(","),
    step: Number(ev.step_us) / 1000,
  });
  // let the engine finish the document before the next keystroke, like a pause in typing
  if (!ev.done) await next((e) => e.ev === "pages" && e.done === true);
}

const med = (a: number[]) => [...a].sort((x, y) => x - y)[Math.floor(a.length / 2)];
console.table(rows.map((r) => ({ ...r, pages: r.pages.toFixed(1), render: r.render.toFixed(1), total: r.total.toFixed(1), step: r.step.toFixed(1) })));
console.log(
  `median: edit→page ${med(rows.map((r) => r.pages)).toFixed(1)} ms, render ${med(rows.map((r) => r.render)).toFixed(1)} ms, total ${med(rows.map((r) => r.total)).toFixed(1)} ms (page ${goal + 1}, ${scale}x)`,
);

if (args.tectonic) {
  const times: number[] = [];
  for (let i = 0; i < 3; i++) {
    const t = performance.now();
    const r = await new Deno.Command("tectonic", {
      args: ["-X", "compile", "--outdir", tmp, "--synctex", main],
      stdout: "piped",
      stderr: "piped",
    }).output();
    if (!r.success) throw new Error("tectonic failed: " + new TextDecoder().decode(r.stderr).slice(-600));
    times.push(performance.now() - t);
  }
  console.log(`tectonic full compile: ${times.map((t) => t.toFixed(0)).join(", ")} ms`);
}
await w.close().catch(() => {});
proc.kill();
Deno.exit(0);
