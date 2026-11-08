// Keystroke → pixels: types into a doc through the engine (as Neovim does, doc.edit) and records the preview's window
// until its pixels change. The capture's frame times and the keystroke times are on the same clock (mach absolute
// time, read here through FFI), so each latency is "doc.edit sent" → "first frame on screen that differs".
//
//   deno run -A --unstable-ffi latency.ts --socket ENGINE.sock --path main.tex --at TEXT [--n 10] [--gap 2500]
//                                         [--owner Rex] [--label NAME] [--results FILE]
//   deno run -A --unstable-ffi latency.ts --txp-viewer DIR/main.tex --at TEXT ...
//       TeXpresso's own SDL viewer instead: starts it with -json, types into it over its stdin ("change"), records
//       its window. It shows the page the edit is on once it is asked for it with synctex-forward.
//
// Each keystroke inserts "x" after TEXT, the next one deletes it again. The region is the frontmost OWNER window minus
// its title bar and the bottom 60 pt (the preview's status line, which changes on its own when a compile starts).
// Frames are diffed as they arrive (only the previous one is kept). Per keystroke it reports the first change and the
// last change within the gap (some previews draw in steps: a page, then its neighbours).

import { parseArgs } from "jsr:@std/cli@1/parse-args";

const args = parseArgs(Deno.args, { string: ["socket", "path", "at", "n", "gap", "owner", "label", "results", "txp-viewer"] });
const viewer = args["txp-viewer"];
const here = new URL(".", import.meta.url).pathname;
const N = Number(args.n ?? 10), gap = Number(args.gap ?? 2500), owner = args.owner ?? (viewer ? "texpresso" : "Rex");
const enc = new TextEncoder(), dec = new TextDecoder();

const lib = Deno.dlopen("/usr/lib/libSystem.B.dylib", {
  mach_absolute_time: { parameters: [], result: "u64" },
  mach_timebase_info: { parameters: ["buffer"], result: "i32" },
});
const tb = new Uint32Array(2);
lib.symbols.mach_timebase_info(tb);
const nowMs = () => Number((lib.symbols.mach_absolute_time() as bigint) * BigInt(tb[0]) / BigInt(tb[1])) / 1e6;

// ---- edits: through the engine, or straight into TeXpresso's stdin ----
let edit: (k: number, del: boolean) => Promise<void>;
let pos = 0;
let finish = async () => {};
if (viewer) {
  const text = await Deno.readTextFile(viewer);
  const i = text.indexOf(String(args.at));
  if (i < 0) throw new Error("--at not found");
  pos = enc.encode(text.slice(0, i + String(args.at).length)).length;
  const line = text.slice(0, i).split("\n").length;
  const rel = viewer; // absolute: texpresso's change handler always makes the path relative to the document itself
  const bin = `${Deno.env.get("HOME")}/code/lab/taudot-ref/texpresso/build/texpresso`;
  const proc = new Deno.Command(bin, { args: ["-tectonic", "-json", viewer], stdin: "piped", stdout: "null", stderr: "null" }).spawn();
  const w = proc.stdin.getWriter();
  const send = (a: unknown[]) => w.write(enc.encode(JSON.stringify(a) + "\n"));
  await send(["open", rel, text]);
  await new Promise((r) => setTimeout(r, 2500));
  await send(["synctex-forward", rel, line]);
  await new Promise((r) => setTimeout(r, 1500));
  edit = (_k, del) => send(["change", rel, pos, del ? 1 : 0, del ? "" : "x"]);
  finish = async () => {
    try {
      proc.kill();
    } catch { /* gone */ }
    // the viewer leaves its TeX process and snapshots behind when killed: sweep the ones on this document
    await new Deno.Command("pkill", { args: ["-f", `texpresso-xetex .*-texpresso ${rel.split("/").pop()}`] }).output();
  };
} else {
  // ---- engine client ----
  const conn = await Deno.connect({ transport: "unix", path: String(args.socket) });
  let rid = 0, rbuf = "";
  const waiting = new Map<number, (m: { result?: any; error?: any }) => void>();
  (async () => {
    for await (const chunk of conn.readable) {
      rbuf += dec.decode(chunk, { stream: true });
      let nl;
      while ((nl = rbuf.indexOf("\n")) >= 0) {
        const m = JSON.parse(rbuf.slice(0, nl));
        rbuf = rbuf.slice(nl + 1);
        if (m.id !== undefined) {
          waiting.get(m.id)?.(m);
          waiting.delete(m.id);
        }
      }
    }
  })();
  const call = (method: string, params: unknown) =>
    new Promise<any>((res, rej) => {
      const i = ++rid;
      waiting.set(i, (m) => (m.error ? rej(new Error(JSON.stringify(m.error))) : res(m.result)));
      conn.write(enc.encode(JSON.stringify({ jsonrpc: "2.0", id: i, method, params }) + "\n"));
    });
  const proj = await call("project.open", {});
  const doc = await call("doc.open", { project_id: proj.project_id, path: args.path });
  let seq = doc.seq as number;
  const text = doc.text as string;
  const i = text.indexOf(String(args.at));
  if (i < 0) throw new Error("--at not found");
  pos = enc.encode(text.slice(0, i + String(args.at).length)).length;


  edit = async (_k, del) => {
    const edits = del ? [{ pos, del: 1, ins: "" }] : [{ pos, del: 0, ins: "x" }];
    const r = await call("doc.edit", { doc_id: doc.doc_id, seq, edits });
    seq = r.seq;
  };
  finish = async () => conn.close();
}

// ---- capture ----
const wl = new TextDecoder().decode(
  (await new Deno.Command(`${here}winlist`, { args: [owner, "400000"], stdout: "piped" }).output()).stdout,
).trim().split("\n")[0];
if (!wl) throw new Error(`no ${owner} window`);
const [wid, wx, wy, ww, wh] = wl.split(" ");
const rect = [Number(wx), Number(wy) + 40, Number(ww), Number(wh) - 40 - 60];
const secs = Math.ceil((N * gap + 1500) / 1000);
const cap = new Deno.Command(`${here}scrcap`, {
  args: [...rect.map(String), String(secs), "120"],
  stdout: "piped",
  stderr: "null",
  env: { SCRCAP_WINDOW: wid },
}).spawn();
const changes: number[] = []; // frame times (ms) whose pixels differ from the previous frame
let frames = 0;
const reader = (async () => {
  let buf = new Uint8Array(0);
  let prev: Uint8Array | undefined;
  for await (const chunk of cap.stdout) {
    const nb = new Uint8Array(buf.length + chunk.length);
    nb.set(buf);
    nb.set(chunk, buf.length);
    buf = nb;
    while (buf.length >= 16) {
      const dv = new DataView(buf.buffer, buf.byteOffset, 16);
      const t = Number(dv.getBigUint64(0, true)) / 1e6, w = dv.getUint32(8, true), h = dv.getUint32(12, true);
      if (buf.length < 16 + w * h) break;
      const img = buf.slice(16, 16 + w * h);
      buf = buf.slice(16 + w * h);
      frames++;
      if (prev && prev.length === img.length) {
        let n = 0;
        for (let k = 0; k < img.length; k += 5) if (Math.abs(img[k] - prev[k]) > 24) n++;
        if (n >= 3) changes.push(t);
      }
      prev = img;
    }
  }
})();

await new Promise((r) => setTimeout(r, 1200)); // capture running, screen quiet
const keys: number[] = [];
let inserted = false;
for (let k = 0; k < N; k++) {
  keys.push(nowMs());
  await edit(k, inserted);
  inserted = !inserted;
  await new Promise((r) => setTimeout(r, gap));
}
if (inserted) await edit(N, true);
await reader;
await cap.status;

const rows = keys.map((t, k) => {
  const end = keys[k + 1] ?? t + gap;
  const c = changes.filter((x) => x > t && x < end);
  return { first: c.length ? c[0] - t : NaN, last: c.length ? c.at(-1)! - t : NaN, frames: c.length };
});
const ok = rows.filter((r) => !isNaN(r.first));
const med = (a: number[]) => {
  const s = [...a].sort((x, y) => x - y);
  return s.length ? Math.round(s[Math.floor(s.length / 2)]) : NaN;
};
const summary = {
  label: args.label ?? "latency",
  keystrokes: N,
  seen: ok.length,
  first_ms: { median: med(ok.map((r) => r.first)), min: Math.round(Math.min(...ok.map((r) => r.first))), max: Math.round(Math.max(...ok.map((r) => r.first))) },
  last_ms: { median: med(ok.map((r) => r.last)), max: Math.round(Math.max(...ok.map((r) => r.last))) },
  per_key: rows.map((r) => `${Math.round(r.first)}/${Math.round(r.last)}`).join(" "),
  frames,
};
console.log(JSON.stringify(summary));
if (args.results) await Deno.writeTextFile(args.results, JSON.stringify(summary) + "\n", { append: true });
await finish();
Deno.exit(0);
