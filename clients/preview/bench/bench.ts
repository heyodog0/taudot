// On-screen smoothness bench for the preview: what reaches the display, not what we write.
//
//   deno run -A clients/preview/bench/bench.ts --socket SOCK --scenario scroll|zoom --zoom fit|360 --label NAME
//                                              [--results FILE] [--keep-tool]
//
// 1. Calibrate: asks the preview (over its socket) to draw magenta squares on the first and last cell of its page
//    area, takes one screenshot, finds them, deletes the screenshot. That gives the area in screen points.
// 2. Sets the zoom (fit-width, or 360%) and scrolls to the top, by injected input, and waits for tiles.
// 3. Records a vertical strip through the middle of the area with scrcap (ScreenCaptureKit, up to 120 fps, only frames
//    that changed, with their display times) while it injects the same event script every run.
// 4. Per displayed frame: how far the content moved (row-profile matching for scroll, scale matching about the pointer
//    for zoom) and how sharp it is. Prints a summary and appends it to --results.
// Nothing is written to disk but the summary; frames are reduced to profiles as they arrive.

import { parseArgs } from "jsr:@std/cli@1/parse-args";

const args = parseArgs(Deno.args, { string: ["socket", "scenario", "zoom", "label", "results", "fps", "dump", "owner"] });
const scenario = args.scenario ?? "scroll";
const zoomMode = args.zoom ?? "fit";
const label = args.label ?? `${scenario}-${zoomMode}`;
if (!args.socket) {
  console.error("usage: bench.ts --socket SOCK --scenario scroll|zoom --zoom fit|360 --label NAME [--results FILE]");
  Deno.exit(2);
}
const here = new URL(".", import.meta.url).pathname;
const enc = new TextEncoder();
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

const conn = await Deno.connect({ transport: "unix", path: args.socket });
const send = (o: unknown) => conn.write(enc.encode(JSON.stringify(o) + "\n"));
const input = (s: string) => send({ input: s });

// ---- 1. calibrate ---------------------------------------------------------------------------------------------------

async function findArea(): Promise<{ x: number; y: number; w: number; h: number; scale: number }> {
  await send({ calibrate: true });
  await sleep(400);
  const tmp = await Deno.makeTempFile({ suffix: ".bmp" });
  try {
    const r = await new Deno.Command("screencapture", { args: ["-x", "-t", "bmp", "-D", "1", tmp] }).output();
    if (!r.success) throw new Error("screencapture failed");
    const b = await Deno.readFile(tmp);
    const dv = new DataView(b.buffer);
    const off = dv.getUint32(10, true), W = dv.getInt32(18, true), Hs = dv.getInt32(22, true);
    const bpp = dv.getUint16(28, true) / 8, H = Math.abs(Hs), stride = Math.ceil((W * bpp) / 4) * 4;
    let x0 = Infinity, y0 = Infinity, x1 = -1, y1 = -1;
    for (let yy = 0; yy < H; yy++) {
      const row = off + (Hs > 0 ? H - 1 - yy : yy) * stride;
      for (let xx = 0; xx < W; xx++) {
        const p = row + xx * bpp; // BGR(A)
        if (b[p + 2] > 200 && b[p + 1] < 80 && b[p] > 200) {
          if (xx < x0) x0 = xx;
          if (yy < y0) y0 = yy;
          if (xx > x1) x1 = xx;
          if (yy > y1) y1 = yy;
        }
      }
    }
    if (x1 < 0) {
      if (Deno.env.get("BENCH_FAIL_THUMB")) {
        await new Deno.Command("sips", { args: ["-s", "format", "png", "-Z", "400", tmp, "--out", Deno.env.get("BENCH_FAIL_THUMB")!] }).output();
      }
      throw new Error("calibration markers not on screen: is the pane visible?");
    }
    // the screenshot is in pixels of the main display; points = pixels / backing scale
    const mainW = Number((await cmd("sh", ["-c", "system_profiler SPDisplaysDataType | grep -m1 'UI Looks like' || true"])).match(/(\d+) x/)?.[1] ?? 0);
    const scale = mainW ? W / mainW : 2;
    return { x: x0 / scale, y: y0 / scale, w: (x1 - x0 + 1) / scale, h: (y1 - y0 + 1) / scale, scale };
  } finally {
    await Deno.remove(tmp).catch(() => {});
    await send({ calibrate: false });
  }
}
async function cmd(c: string, a: string[]) {
  const r = await new Deno.Command(c, { args: a, stdout: "piped", stderr: "null" }).output();
  return new TextDecoder().decode(r.stdout);
}

let area: Awaited<ReturnType<typeof findArea>> | undefined;
for (let i = 0; i < 4 && !area; i++) {
  try {
    area = await findArea();
  } catch (e) {
    if (i === 3) throw e;
    await sleep(700); // a resize redraw can wipe the markers right after the session comes to the front
  }
}
if (!area) throw new Error("no area");
const px = (v: number) => Math.round(v * area.scale); // points -> pane pixels
const cx = px(area.w / 2), cy = px(area.h * 0.45);
const sgr = (b: number) => `\x1b[<${b};${cx + 1};${cy + 1}M`;

// ---- 2. state -------------------------------------------------------------------------------------------------------

await input("0gg"); // fit width, top
await sleep(1500);
if (zoomMode === "360") {
  for (let i = 0; i < 22; i++) {
    await input(sgr(80)); // ctrl + wheel up: 1.06^22 ≈ 3.6
    await sleep(25);
  }
  await sleep(2500);
}

// ---- 3. record while injecting --------------------------------------------------------------------------------------

type Ev = { at: number; s: string };
const script: Ev[] = [];
if (scenario === "scroll") {
  for (let i = 0; i < 90; i++) script.push({ at: i * 16, s: sgr(65) }); // wheel down, 62.5 Hz, 1.44 s
} else {
  for (let i = 0; i < 12; i++) script.push({ at: i * 30, s: sgr(80) }); // ctrl+wheel up
  for (let i = 0; i < 12; i++) script.push({ at: 1100 + i * 30, s: sgr(81) }); // ctrl+wheel down
}
const scriptMs = script.at(-1)!.at;
const stripW = Math.min(160, area.w); // points
const sx = area.x + area.w / 2 - stripW / 2;
const recSecs = (scriptMs + 1500) / 1000;

// capture the terminal window itself: display capture tops out near 60 fps here, window capture does not
const owner = args.owner ?? "Rex";
const wid = (await cmd(`${here}winat`, [owner, String(area.x + area.w / 2), String(area.y + area.h / 2)])).trim();
const cap = new Deno.Command(`${here}scrcap`, {
  args: [String(sx), String(area.y), String(stripW), String(area.h), String(recSecs), "120"],
  stdout: "piped",
  stderr: "piped",
  env: wid ? { SCRCAP_WINDOW: wid } : {},
}).spawn();

interface F {
  t: number; // ms
  img: Uint8Array; // luma, 2x2-averaged
  w: number;
  h: number;
  sharp: number; // mean |vertical gradient|
}
const frames: F[] = [];
let capW = 0, capH = 0;
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
      capW = w;
      capH = h;
      const hw = w >> 1, hh = h >> 1;
      const small = new Uint8Array(hw * hh);
      let sharp = 0;
      for (let y = 0; y < hh; y++) {
        const r0 = 2 * y * w, r1 = r0 + w;
        for (let x = 0; x < hw; x++) {
          small[y * hw + x] = (img[r0 + 2 * x] + img[r0 + 2 * x + 1] + img[r1 + 2 * x] + img[r1 + 2 * x + 1]) >> 2;
        }
      }
      for (let y = 1; y < h; y++) for (let x = 0; x < w; x += 2) sharp += Math.abs(img[y * w + x] - img[(y - 1) * w + x]);
      frames.push({ t, img: small, w: hw, h: hh, sharp: sharp / ((h - 1) * Math.ceil(w / 2)) });
      buf = buf.slice(16 + w * h);
    }
  }
})();
let capErr = "";
const errReader = (async () => {
  for await (const c of cap.stderr) capErr += new TextDecoder().decode(c);
})();
while (!capErr.includes("started")) await sleep(5);
await sleep(300);
const t0 = performance.now();
const sentAt: number[] = [];
for (const e of script) {
  const wait = e.at - (performance.now() - t0);
  if (wait > 1) await sleep(wait - 1);
  while (performance.now() - t0 < e.at) { /* spin the last ms */ }
  sentAt.push(performance.now() - t0);
  await input(e.s);
}
await cap.status;
await reader;
await errReader;
conn.close();

// ---- 4. analyse -----------------------------------------------------------------------------------------------------

/** Vertical shift (native pixels) that best maps frame a onto b: b(x, y) ≈ a(x, y - d). 2D, so repeating text lines
 *  can't alias. Coarse on a sparse grid, then refined. */
function shift(a: F, b: F, maxD: number): { d: number; err: number } {
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

/** Scale about (ax, ay) (half-res pixels) that best maps frame p onto q: q(x, y) ≈ p(ax + (x - ax) / s, ay + (y - ay) / s). */
function scaleAbout(p: F, q: F, ax: number, ay: number): number {
  const w = p.w, h = p.h;
  const cost = (s: number) => {
    let e = 0, c = 0;
    for (let y = 0; y < h; y += 3) {
      const sy = Math.round(ay + (y - ay) / s);
      if (sy < 0 || sy >= h) continue;
      for (let x = 0; x < w; x += 3) {
        const sx = Math.round(ax + (x - ax) / s);
        if (sx < 0 || sx >= w) continue;
        e += Math.abs(q.img[y * w + x] - p.img[sy * w + sx]);
        c++;
      }
    }
    return c > (w * h) / 40 ? e / c : Infinity;
  };
  let best = 1, bc = Infinity;
  for (let k = -60; k <= 60; k++) {
    const s = Math.exp(k * 0.0015);
    const c = cost(s);
    if (c < bc) [best, bc] = [s, c];
  }
  return best;
}

const med = (a: number[]) => a.length ? [...a].sort((x, y) => x - y)[Math.floor(a.length / 2)] : NaN;
const pct = (a: number[], q: number) => a.length ? [...a].sort((x, y) => x - y)[Math.min(a.length - 1, Math.floor(a.length * q))] : NaN;
const r1 = (v: number) => Math.round(v * 10) / 10, r2 = (v: number) => Math.round(v * 100) / 100;

const steps: { t: number; dt: number; m: number }[] = []; // m: pixels (scroll) or log-scale (zoom)
const anchor = cy; // pointer row in the strip (strip starts at the area's top)
for (let i = 1; i < frames.length; i++) {
  const a = frames[i - 1], b = frames[i];
  const m = scenario === "scroll" ? -shift(a, b, 320).d : Math.log(scaleAbout(a, b, a.w / 2, anchor / 2));
  steps.push({ t: b.t, dt: b.t - a.t, m });
}
const moving = (s: { m: number }) => scenario === "scroll" ? Math.abs(s.m) >= 1 : Math.abs(s.m) >= 0.003;
const firstI = steps.findIndex(moving);
let lastI = -1;
for (let i = steps.length - 1; i >= 0; i--) if (moving(steps[i])) { lastI = i; break; }
// motion segments: runs of moving frames, allowing gaps under 60 ms (a zoom script pauses between in and out)
const segs: (typeof steps)[] = [];
for (let i = Math.max(0, firstI); firstI >= 0 && i <= lastI; i++) {
  const cur = segs.at(-1);
  if (moving(steps[i])) {
    if (cur && steps[i].t - cur.at(-1)!.t < 60) {
      for (let j = steps.indexOf(cur.at(-1)!) + 1; j <= i; j++) cur.push(steps[j]);
    } else segs.push([steps[i]]);
  }
}
const win = segs.flat();
const dur = segs.reduce((s, g) => s + (g.at(-1)!.t - g[0].t + g[0].dt), 0);
const dts = win.map((s) => s.dt);
const still = win.filter((s) => !moving(s)).length; // frames shown inside the motion that didn't move
// steadiness over the middle half of each segment (away from ease-in and ease-out), weighted by length
let cvSum = 0, cvN = 0;
for (const g of segs) {
  const rate = g.map((s) => s.m / s.dt);
  const mid = rate.slice(Math.floor(rate.length / 4), Math.ceil((rate.length * 3) / 4));
  if (mid.length < 3) continue;
  const mean = mid.reduce((x, y) => x + y, 0) / mid.length;
  const sd = Math.sqrt(mid.reduce((x, y) => x + (y - mean) ** 2, 0) / mid.length);
  cvSum += Math.abs(sd / (mean || 1)) * mid.length;
  cvN += mid.length;
}
const settled = frames.slice(0, Math.max(1, firstI)).map((f) => f.sharp);
const sharpRef = med(settled);
const winT = new Set(win.map((s) => s.t));
const soft = frames.filter((f) => winT.has(f.t) && f.sharp < sharpRef * 0.8).length;
const after = frames.slice(lastI + 2);
// how long after the motion until the view is as sharp as before it (tiles in, snapshot swapped)
const endT = lastI >= 0 ? steps[lastI].t : 0;
const sharpAgain = frames.find((f) => f.t > endT && f.sharp >= sharpRef * 0.95);
const summary = {
  label,
  scenario,
  zoom: zoomMode,
  area_pt: `${r1(area.w)}x${r1(area.h)}`,
  strip_px: `${capW}x${capH}`,
  display_ms: r1(med(steps.map((s) => s.dt).filter((d) => d > 0))),
  frames_recorded: frames.length,
  motion_ms: Math.round(dur),
  displayed_fps: r1(win.length / (dur / 1000 || 1)),
  frame_interval_ms: { median: r1(med(dts)), p90: r1(pct(dts, 0.9)), max: r1(Math.max(...dts, 0)) },
  intervals: {
    "<=10ms": dts.filter((d) => d <= 10).length,
    "10-20ms": dts.filter((d) => d > 10 && d <= 20).length,
    "20-30ms": dts.filter((d) => d > 20 && d <= 30).length,
    ">30ms": dts.filter((d) => d > 30).length,
  },
  still_frames_in_motion: still,
  step: scenario === "scroll"
    ? { median_px: r1(med(win.map((s) => Math.abs(s.m)))), max_px: r1(Math.max(...win.map((s) => Math.abs(s.m)), 0)) }
    : { median_pct: r2(med(win.map((s) => Math.abs(s.m))) * 100), max_pct: r2(Math.max(...win.map((s) => Math.abs(s.m)), 0) * 100) },
  segments: segs.length,
  judder_cv: r2(cvN ? cvSum / cvN : NaN), // speed variation in the steady middle: 0 = perfectly even
  soft_frames: soft, // frames in motion < 80% of the settled sharpness (underlay, blurry snapshot, blank)
  settle_after_motion: after.length,
  sharp_after_ms: sharpAgain ? Math.round(sharpAgain.t - endT) : -1,
  events_sent: sentAt.length,
  event_jitter_ms: r2(Math.max(...sentAt.map((t, i) => Math.abs(t - script[i].at)))),
  capture: capErr.trim().split("\n").at(-1),
  capture_mode: wid ? `window ${wid}` : "display",
};
console.log(JSON.stringify(summary, null, 2));
if (args.dump) await Deno.writeTextFile(args.dump + ".json", JSON.stringify(steps.map((s, i) => ({ ...s, sharp: frames[i + 1].sharp }))));
if (args.results) await Deno.writeTextFile(args.results, JSON.stringify(summary) + "\n", { append: true });
