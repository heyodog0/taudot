// Generic on-screen measurement: what a window region shows, frame by frame, while a trigger runs.
//
//   deno run -A measure.ts --label NAME [--owner Rex] [--rect X,Y,W,H] [--secs S] [--delay MS] [--results FILE]
//                          -- TRIGGER COMMAND...
//
// Records the region with scrcap in window-capture mode (the frontmost large window of OWNER containing it; default
// region: a 160 pt strip through the middle of that window's content), starts TRIGGER after --delay ms, and reports
// changed frames/s, frame intervals, and the vertical content shift per frame (2D matching), so it covers both
// "how often does it update" (text, images, UI animations) and "how smoothly does it move" (scrolling).
// Nothing but the summary is kept.

import { parseArgs } from "jsr:@std/cli@1/parse-args";

const args = parseArgs(Deno.args, { string: ["label", "owner", "rect", "secs", "delay", "results", "dump"], "--": true });
const here = new URL(".", import.meta.url).pathname;
const owner = args.owner ?? "Rex";
const secs = Number(args.secs ?? 3);
const delay = Number(args.delay ?? 400);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const cmd = async (c: string, a: string[]) =>
  new TextDecoder().decode((await new Deno.Command(c, { args: a, stdout: "piped", stderr: "null" }).output()).stdout);

// window bounds (front-to-back list), to place the default strip and find the window id
async function frontWindow(): Promise<{ id: string; x: number; y: number; w: number; h: number } | undefined> {
  const out = await cmd(`${here}winlist`, [owner, args.rect ? "20000" : "400000"]);
  const first = out.trim().split("\n")[0];
  if (!first) return undefined;
  const [id, x, y, w, h] = first.split(" ");
  return { id, x: +x, y: +y, w: +w, h: +h };
}
const win = await frontWindow();
if (!win) throw new Error(`no ${owner} window on screen`);
const [rx, ry, rw, rh] = args.rect
  ? args.rect.split(",").map(Number)
  : [win.x + win.w / 2 - 80, win.y + 90, 160, win.h - 150];

const cap = new Deno.Command(`${here}scrcap`, {
  args: [String(rx), String(ry), String(rw), String(rh), String(secs), "120"],
  stdout: "piped",
  stderr: "piped",
  env: { SCRCAP_WINDOW: win.id },
}).spawn();

interface F {
  t: number;
  img: Uint8Array;
  w: number;
  h: number;
}
const frames: F[] = [];
const reader = (async () => {
  let buf = new Uint8Array(0);
  for await (const chunk of cap.stdout) {
    const nb = new Uint8Array(buf.length + chunk.length);
    nb.set(buf);
    nb.set(chunk, buf.length);
    buf = nb;
    while (buf.length >= 16) {
      const dv = new DataView(buf.buffer, buf.byteOffset, 16);
      const t = Number(dv.getBigUint64(0, true)) / 1e6, w = dv.getUint32(8, true), h = dv.getUint32(12, true);
      if (buf.length < 16 + w * h) break;
      const img = buf.subarray(16, 16 + w * h);
      const hw = w >> 1, hh = h >> 1, small = new Uint8Array(hw * hh);
      for (let y = 0; y < hh; y++) {
        const r0 = 2 * y * w, r1 = r0 + w;
        for (let x = 0; x < hw; x++) {
          small[y * hw + x] = (img[r0 + 2 * x] + img[r0 + 2 * x + 1] + img[r1 + 2 * x] + img[r1 + 2 * x + 1]) >> 2;
        }
      }
      frames.push({ t, img: small, w: hw, h: hh });
      buf = buf.slice(16 + w * h);
    }
  }
})();
let capErr = "";
const errReader = (async () => {
  for await (const c of cap.stderr) capErr += new TextDecoder().decode(c);
})();
while (!capErr.includes("started")) await sleep(5);
await sleep(delay);
const trig = args["--"]?.length ? new Deno.Command(args["--"][0], { args: args["--"].slice(1) }).spawn() : undefined;
await cap.status;
await reader;
await errReader;
if (trig) await trig.status.catch(() => {});

// vertical shift between frames, 2D
function shift(a: F, b: F, maxD: number) {
  const w = a.w, h = a.h, md = Math.round(maxD / 2);
  const cost = (d: number, step: number) => {
    let s = 0, c = 0;
    const y0 = Math.max(0, d), y1 = Math.min(h, h + d);
    for (let y = y0; y < y1; y += step) {
      const rb = y * w, ra = (y - d) * w;
      for (let x = 0; x < w; x += step) s += Math.abs(b.img[rb + x] - a.img[ra + x]);
      c += Math.ceil(w / step);
    }
    return c > (w * h) / (4 * step * step) ? s / c : Infinity;
  };
  let best = 0, bc = Infinity;
  for (let d = -md; d <= md; d++) {
    const c = cost(d, 3);
    if (c < bc) [best, bc] = [d, c];
  }
  let fine = best, fc = Infinity;
  for (let d = best - 2; d <= best + 2; d++) {
    const c = cost(d, 1);
    if (c < fc) [fine, fc] = [d, c];
  }
  return { d: fine * 2, err: fc };
}
if (args.dump && frames.length) {
  for (const [name, f] of [["first", frames[0]], ["mid", frames[frames.length >> 1]], ["last", frames.at(-1)!]] as const) {
    Deno.writeFileSync(`${args.dump}-${name}.pgm`, new Uint8Array([...new TextEncoder().encode(`P5\n${f.w} ${f.h}\n255\n`), ...f.img]));
  }
}
const med = (a: number[]) => a.length ? [...a].sort((x, y) => x - y)[Math.floor(a.length / 2)] : NaN;
const pct = (a: number[], q: number) =>
  a.length ? [...a].sort((x, y) => x - y)[Math.min(a.length - 1, Math.floor(a.length * q))] : NaN;
const r1 = (v: number) => Math.round(v * 10) / 10;

// frames whose pixels differ from the previous one (window capture also reports redraws that change nothing)
const diffT: number[] = [];
for (let i = 1; i < frames.length; i++) {
  const a = frames[i - 1].img, b = frames[i].img;
  let n = 0;
  for (let k = 0; k < a.length; k += 7) if (Math.abs(a[k] - b[k]) > 24) n++;
  if (n > a.length / 7 / 2000) diffT.push(frames[i].t);
}
const diffI = diffT.slice(1).map((t, i) => t - diffT[i]);
const steps = frames.slice(1).map((b, i) => {
  const a = frames[i];
  const s = shift(a, b, 300);
  return { t: b.t, dt: b.t - a.t, d: -s.d, err: s.err };
});
// active span: from the first to the last changed frame after the trigger started
const span = steps.length ? steps.at(-1)!.t - steps[0].t + steps[0].dt : 0;
const dts = steps.map((s) => s.dt);
const moving = steps.filter((s) => Math.abs(s.d) >= 1);
const summary = {
  label: args.label ?? "measure",
  owner,
  window: win.id,
  rect_pt: [rx, ry, rw, rh].map((v) => Math.round(v)).join(","),
  changed_frames: frames.length,
  changed_fps: r1(steps.length / (span / 1000 || 1)),
  interval_ms: { median: r1(med(dts)), p10: r1(pct(dts, 0.1)), p90: r1(pct(dts, 0.9)) },
  intervals: {
    "<=10ms": dts.filter((d) => d <= 10).length,
    "10-20ms": dts.filter((d) => d > 10 && d <= 20).length,
    ">20ms": dts.filter((d) => d > 20).length,
  },
  pixel_change_frames: diffT.length,
  pixel_change_fps: r1(diffT.length / (((diffT.at(-1) ?? 0) - (diffT[0] ?? 0)) / 1000 || 1)),
  pixel_change_interval_ms: { median: r1(med(diffI)), p10: r1(pct(diffI, 0.1)), p90: r1(pct(diffI, 0.9)) },
  moving_frames: moving.length,
  moving_interval_ms_median: r1(med(moving.slice(1).map((s, i) => s.t - moving[i].t))),
  moving_intervals: (() => {
    const m = moving.slice(1).map((s, i) => s.t - moving[i].t);
    return { "<=10ms": m.filter((d) => d <= 10).length, "10-20ms": m.filter((d) => d > 10 && d <= 20).length, ">20ms": m.filter((d) => d > 20).length };
  })(),
  step_px: { median: r1(med(moving.map((s) => Math.abs(s.d)))), max: Math.max(0, ...moving.map((s) => Math.abs(s.d))) },
  capture: capErr.trim().split("\n").at(-1),
};
console.log(JSON.stringify(summary, null, 2));
if (args.results) await Deno.writeTextFile(args.results, JSON.stringify(summary) + "\n", { append: true });
