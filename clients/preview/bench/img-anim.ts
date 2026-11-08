// An image that moves every PERIOD ms: one page image sent once, then its placement's source rectangle moved down
// 4 px per tick, so the picture scrolls up. Options add what the preview's frames carry, to find what costs frames:
//   --status     rewrite a status line of text every frame
//   --tiles N    split the picture into N horizontal bands, each its own image and placement
//   --underlay   an extra scaled (c/r) placement under it at z=-1
//   --nosync     no synchronized-output brackets
//   deno run -A img-anim.ts PDF [PERIOD_MS] [SECONDS] [options]
import { parseArgs } from "jsr:@std/cli@1/parse-args";
const args = parseArgs(Deno.args, { boolean: ["status", "underlay", "nosync", "mouse"], string: ["tiles", "transmit", "trace"] });
const transmitEvery = Number(args.transmit ?? 0); // send a fresh 512x512 zlib tile image every N frames (as a scrolling preview does)
import { deflateSync } from "node:zlib";
const tileZ = transmitEvery ? deflateSync(new Uint8Array(512 * 512 * 3).map((_, k) => (k * 2654435761) >>> 24)) : new Uint8Array();
const tileFile = transmitEvery ? await Deno.makeTempFile({ suffix: ".z" }) : "";
if (transmitEvery) await Deno.writeFile(tileFile, tileZ);
const pdf = String(args._[0]), period = Number(args._[1] ?? 8), secs = Number(args._[2] ?? 4);
const tilesN = Number(args.tiles ?? 1);
const enc = new TextEncoder(), dec = new TextDecoder();
const w = (s: string) => Deno.stdout.writeSync(enc.encode(s));
const { columns, rows } = Deno.consoleSize();
Deno.stdin.setRaw(true);
w("\x1b[?1049h\x1b[?25l\x1b[16t");
if (args.mouse) w("\x1b[?1003h\x1b[?1006h\x1b[?1016h"); // as the preview: all-motion SGR pixel mouse reporting
const b = new Uint8Array(64);
const n = await Deno.stdin.read(b);
const m = dec.decode(b.subarray(0, n ?? 0)).match(/\x1b\[6;(\d+);(\d+)t/);
const [ch, cw] = m ? [Number(m[1]), Number(m[2])] : [16, 8];
const areaRows = rows - (args.status ? 2 : 0);
const W = columns * cw, H = areaRows * ch;
const file = await Deno.makeTempFile({ suffix: ".png" });
await new Deno.Command("pdftoppm", { args: ["-f", "1", "-l", "1", "-scale-to-x", String(W), "-scale-to-y", "-1", "-png", "-singlefile", pdf, file.slice(0, -4)] }).output();
const ID = 4242;
// N images that are the same picture; each placement shows its own band of the view
for (let k = 0; k < tilesN; k++) w(`\x1b_Ga=t,f=100,t=f,i=${ID + k},q=2;${btoa(file)}\x1b\\`);
if (args.underlay) w(`\x1b_Ga=t,f=100,t=f,i=${ID + 100},q=2;${btoa(file)}\x1b\\`);
const PH = Math.floor(W * 1.29);
const stamps: number[] = [];
const t0 = performance.now();
let i = 0;
while (performance.now() - t0 < secs * 1000) {
  const y = (i * 4) % Math.max(1, PH - H);
  let s = args.nosync ? "" : "\x1b[?2026h";
  if (args.underlay) s += `\x1b[1;1H\x1b_Ga=p,i=${ID + 100},p=1,x=0,y=${y},w=${W},h=${H},c=${columns},r=${areaRows},z=-1,C=1,q=2\x1b\\`;
  const band = Math.ceil(H / tilesN);
  for (let k = 0; k < tilesN; k++) {
    const by = k * band, bh = Math.min(band, H - by);
    const row = Math.floor(by / ch), Y = by % ch;
    s += `\x1b[${row + 1};1H\x1b_Ga=p,i=${ID + k},p=1,x=0,y=${y + by},w=${W},h=${bh},Y=${Y},z=0,C=1,q=2\x1b\\`;
  }
  if (transmitEvery && i % transmitEvery === 0) s += `\x1b_Ga=t,f=24,s=512,v=512,o=z,t=f,i=${ID + 200 + (i / transmitEvery) % 20},q=2;${btoa(tileFile)}\x1b\\`;
  if (args.status) s += `\x1b[${rows};1H\x1b[2K\x1b[1m ${i} \x1b[22m frame ${(performance.now() - t0).toFixed(0)} ms`;
  if (!args.nosync) s += "\x1b[?2026l";
  w(s);
  if (args.trace) stamps.push(performance.now());
  i++;
  const next = t0 + i * period;
  while (performance.now() < next - 1) await new Promise((r) => setTimeout(r, 1));
}
if (args.trace) await Deno.writeTextFile(args.trace, JSON.stringify(stamps));
w("\x1b[?1016l\x1b[?1006l\x1b[?1003l");
w("\x1b_Ga=d,d=A,q=2\x1b\\\x1b[?25h\x1b[?1049l");
Deno.stdin.setRaw(false);
