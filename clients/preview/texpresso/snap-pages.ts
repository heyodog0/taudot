// Writes PNGs of pages as txp-headless draws them, to compare with tectonic's PDF (pdftoppm) by eye.
//
//   deno run -A snap-pages.ts DIR/main.tex OUTDIR [--scale 1.5] [--rerun] PAGE...   (1-based pages)
//
// --rerun: also ask TeXpresso for its aux-convergence pass ("rerun-once") and wait for it, so \ref and \cite settle.

import { parseArgs } from "jsr:@std/cli@1/parse-args";
import { join } from "jsr:@std/path@1";
import { type PagesEvent, Txp } from "./client.ts";

const args = parseArgs(Deno.args, { string: ["scale"], boolean: ["rerun"] });
const [main, outDir, ...pages] = args._.map(String);
const scale = Number(args.scale ?? 1.5);
await Deno.mkdir(outDir, { recursive: true });

let last: PagesEvent | undefined;
let wake: (() => void) | undefined;
const txp = new Txp(main, (e) => {
  last = e;
  wake?.();
});
const until = async (pred: (e: PagesEvent) => boolean) => {
  while (!last || !pred(last)) await new Promise<void>((r) => (wake = r));
  return last;
};
let ev = await until((e) => e.done);
console.log(`${ev.n} pages`);
if (args.rerun) {
  // the idle rerun (on by default) and rerun-once re-run with the new .aux until it stops changing: wait for quiet
  await txp.send(["rerun-once"]);
  for (;;) {
    const g = last!.gen;
    await new Promise((r) => setTimeout(r, 1500));
    if (last!.gen === g && last!.done) break;
  }
  ev = last!;
  console.log(`after reruns: ${ev.n} pages (gen ${ev.gen})`);
}

function crc32(b: Uint8Array) {
  let c = ~0;
  for (const x of b) {
    c ^= x;
    for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1));
  }
  return ~c >>> 0;
}
function chunk(type: string, data: Uint8Array) {
  const out = new Uint8Array(12 + data.length);
  const dv = new DataView(out.buffer);
  dv.setUint32(0, data.length);
  out.set(new TextEncoder().encode(type), 4);
  out.set(data, 8);
  dv.setUint32(8 + data.length, crc32(out.subarray(4, 8 + data.length)));
  return out;
}
async function png(rgb: Uint8Array, w: number, h: number) {
  const raw = new Uint8Array((w * 3 + 1) * h);
  for (let y = 0; y < h; y++) raw.set(rgb.subarray(y * w * 3, (y + 1) * w * 3), y * (w * 3 + 1) + 1);
  const z = new Uint8Array(await new Response(new Blob([raw]).stream().pipeThrough(new CompressionStream("deflate"))).arrayBuffer());
  const ihdr = new Uint8Array(13);
  const dv = new DataView(ihdr.buffer);
  dv.setUint32(0, w);
  dv.setUint32(4, h);
  ihdr.set([8, 2, 0, 0, 0], 8);
  const parts = [new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", z), chunk("IEND", new Uint8Array())];
  return new Uint8Array(await new Blob(parts).arrayBuffer());
}

for (const p of pages) {
  const i = Number(p) - 1;
  const [pw, ph] = ev.sizes[i];
  const w = Math.ceil(pw * scale), h = Math.ceil(ph * scale);
  const rgbPath = join(outDir, `p${p}.rgb`);
  const r = await txp.render(i, scale, 0, 0, w, h, rgbPath, "");
  if (!r.ok) {
    console.log(`page ${p}: ${JSON.stringify(r)}`);
    continue;
  }
  await Deno.writeFile(join(outDir, `txp-${p}.png`), await png(await Deno.readFile(rgbPath), w, h));
  await Deno.remove(rgbPath);
  console.log(`wrote ${join(outDir, `txp-${p}.png`)}`);
}
txp.kill();
Deno.exit(0);
