// How fast does the terminal take in a Kitty image, by transfer method? Run it in a pane:
//
//   deno run -A clients/preview/bench-transfer.ts PDF [--scale S] [--runs N] [--out results.json]
//
// For each method it transmits one page image N times. After each one it sends DA1 (CSI c) and times the reply:
// the terminal answers only after it has parsed everything before it, so the round trip is how long it took to
// take in the image (read, decompress or decode, store). Our own cost to prepare the payload is timed separately.
// Nothing is placed, so this measures transfer, not drawing.

import { parseArgs } from "jsr:@std/cli@1/parse-args";
import { encodeBase64 } from "jsr:@std/encoding@1/base64";
import { deflateSync } from "node:zlib";
import { parsePpm } from "./lib.ts";

const args = parseArgs(Deno.args, { string: ["scale", "runs", "out"] });
const pdf = String(args._[0] ?? "");
if (!pdf) {
  console.log("usage: bench-transfer.ts PDF [--scale S] [--runs N] [--out FILE]");
  Deno.exit(2);
}
const scale = Number(args.scale ?? 2.7); // ~1650 px wide for a letter page
const runs = Number(args.runs ?? 8);
const enc = new TextEncoder(), dec = new TextDecoder();
const tmp = await Deno.makeTempDir({ prefix: "taudot-bench-" });

async function pdftoppm(extra: string[]): Promise<Uint8Array> {
  const r = await new Deno.Command("pdftoppm", {
    args: ["-f", "1", "-l", "1", "-r", String(scale * 72), ...extra, "-singlefile", pdf],
    stdout: "piped",
  }).output();
  return r.stdout;
}

const ppm = parsePpm(await pdftoppm([]))!;
const t0png = performance.now();
const png = await pdftoppm(["-png"]);
const pngMs = performance.now() - t0png;
const { w, h, rgb } = ppm;
const rgba = new Uint8Array(w * h * 4);
for (let i = 0, j = 0; i < rgb.length; i += 3, j += 4) {
  rgba[j] = rgb[i];
  rgba[j + 1] = rgb[i + 1];
  rgba[j + 2] = rgb[i + 2];
  rgba[j + 3] = 255;
}

// stdin raw, read replies
Deno.stdin.setRaw(true);
let inbuf = "";
let waiter: (() => void) | undefined;
(async () => {
  const b = new Uint8Array(4096);
  while (true) {
    const n = await Deno.stdin.read(b);
    if (n === null) break;
    inbuf += dec.decode(b.subarray(0, n));
    if (/\x1b\[\?[\d;]*c/.test(inbuf)) {
      inbuf = inbuf.replace(/\x1b\[\?[\d;]*c/, "");
      waiter?.();
    }
  }
})();
function write(s: string) {
  const b = enc.encode(s);
  let n = 0;
  while (n < b.length) n += Deno.stdout.writeSync(b.subarray(n));
}
async function da1(payload: string): Promise<number> {
  const got = new Promise<void>((r) => (waiter = r));
  const t = performance.now();
  write(payload + "\x1b[c");
  await Promise.race([got, new Promise((r) => setTimeout(r, 5000))]);
  return performance.now() - t;
}
function chunked(head: string, b64: string): string {
  const parts: string[] = [];
  for (let i = 0; i < b64.length; i += 4096) {
    const more = i + 4096 < b64.length ? 1 : 0;
    parts.push(
      i === 0 ? `\x1b_G${head},m=${more};${b64.slice(i, i + 4096)}\x1b\\` : `\x1b_Gm=${more},q=2;${b64.slice(i, i + 4096)}\x1b\\`,
    );
  }
  return parts.join("");
}

interface Method {
  name: string;
  prep: () => Promise<{ payload: string; bytes: number }>; // bytes = what crosses the pty or is read from disk
}
const id = 7_400_000;
const methods: Method[] = [
  {
    name: "raw RGB, file (t=f f=24)",
    prep: async () => {
      const f = `${tmp}/a.rgb`;
      await Deno.writeFile(f, rgb);
      return { payload: `\x1b_Ga=t,f=24,s=${w},v=${h},t=f,i=${id},q=2;${btoa(f)}\x1b\\`, bytes: rgb.length };
    },
  },
  {
    name: "raw RGBA, file (t=f f=32)",
    prep: async () => {
      const f = `${tmp}/a.rgba`;
      await Deno.writeFile(f, rgba);
      return { payload: `\x1b_Ga=t,f=32,s=${w},v=${h},t=f,i=${id},q=2;${btoa(f)}\x1b\\`, bytes: rgba.length };
    },
  },
  {
    name: "zlib RGB, file (t=f o=z)",
    prep: async () => {
      const z = deflateSync(rgb);
      const f = `${tmp}/a.rgb.z`;
      await Deno.writeFile(f, z);
      return { payload: `\x1b_Ga=t,f=24,s=${w},v=${h},o=z,t=f,i=${id},q=2;${btoa(f)}\x1b\\`, bytes: z.length };
    },
  },
  {
    name: "zlib RGB, direct (t=d o=z)",
    prep: () => {
      const b64 = encodeBase64(deflateSync(rgb));
      return Promise.resolve({ payload: chunked(`a=t,f=24,s=${w},v=${h},o=z,t=d,i=${id},q=2`, b64), bytes: b64.length });
    },
  },
  {
    name: "PNG, file (t=f f=100)",
    prep: async () => {
      const f = `${tmp}/a.png`;
      await Deno.writeFile(f, png);
      return { payload: `\x1b_Ga=t,f=100,t=f,i=${id},q=2;${btoa(f)}\x1b\\`, bytes: png.length };
    },
  },
  {
    name: "PNG, direct (t=d f=100)",
    prep: () => {
      const b64 = encodeBase64(png);
      return Promise.resolve({ payload: chunked(`a=t,f=100,t=d,i=${id},q=2`, b64), bytes: b64.length });
    },
  },
];

const median = (a: number[]) => [...a].sort((x, y) => x - y)[Math.floor(a.length / 2)];
const results: Record<string, unknown>[] = [];
write("\x1b[?1049h\x1b[H\x1b[2J");
const base: number[] = [];
for (let i = 0; i < runs; i++) base.push(await da1(""));
for (const m of methods) {
  const prep: number[] = [], term: number[] = [];
  let bytes = 0;
  for (let i = 0; i < runs; i++) {
    const t = performance.now();
    const p = await m.prep();
    prep.push(performance.now() - t);
    bytes = p.bytes;
    term.push(await da1(p.payload));
    await da1(`\x1b_Ga=d,d=I,i=${id},q=2\x1b\\`);
  }
  results.push({
    method: m.name,
    w,
    h,
    bytes,
    prep_ms: +median(prep).toFixed(1),
    terminal_ms: +median(term).toFixed(1),
    terminal_ms_max: +Math.max(...term).toFixed(1),
  });
}
write("\x1b[?1049l");
Deno.stdin.setRaw(false);
const report = {
  image: `${w}x${h}`,
  png_encode_ms_by_pdftoppm: +pngMs.toFixed(0),
  da1_empty_ms: +median(base).toFixed(2),
  results,
};
if (args.out) await Deno.writeTextFile(args.out, JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, null, 2));
await Deno.remove(tmp, { recursive: true });
Deno.exit(0);
