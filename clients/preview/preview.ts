// taudot PDF preview for a Rex pane.
//
//   deno run -A preview.ts --folder DIR [--main FILE] [--out DIR] [--debounce MS] [--trace FILE]
//                          [--listen SOCK] [--editor-block BLOCK]
//
// Watches the project folder and recompiles with tectonic DEBOUNCE ms after the last change (a new change cancels a
// running compile). Shows the pages as one continuous strip drawn with the Kitty graphics protocol: each page is
// rendered once per zoom level with pdftoppm, and scrolling and zooming only move and crop placements, inside
// synchronized-output frames. A sharp re-render follows 150 ms after a zoom gesture stops.
//
// Mouse: wheel scrolls, Ctrl+wheel or Option(Alt)+wheel zooms at the pointer (a pinch is Rex's pane zoom and never
// arrives), drag pans, double-click jumps Neovim to that
// line (SyncTeX). Neovim connects to --listen and sends its cursor; the preview scrolls there and marks the line.
// A failed compile keeps the last good pages and shows the first LaTeX error below them. OSC 7501: working while
// compiling, blocked on an error, idle otherwise.

import { parseArgs } from "jsr:@std/cli@1/parse-args";
import { join, resolve } from "jsr:@std/path@1";
import {
  type Action,
  blitPage,
  clampView,
  currentPage,
  docWidth,
  easeZoom,
  firstError,
  fit,
  fitPageScale,
  fitWidthScale,
  isSource,
  Keys,
  type Mouse,
  osc7501,
  pageTops,
  parseColourReply,
  parseModeReply,
  parsePdfinfo,
  parsePpm,
  parseSizeReply,
  type Piece,
  placePiece,
  placeSnapshot,
  pointToPage,
  type Size,
  type Snapshot,
  splitInput,
  type Viewport,
  visiblePieces,
  zoomAt,
} from "./lib.ts";
import { forward, inverse, parseSyncTex, readSyncTex, type SyncTex } from "./synctex.ts";
import { type PagesEvent, Txp } from "./texpresso/client.ts";
import { encodeBase64 } from "jsr:@std/encoding@1/base64";

const args = parseArgs(Deno.args, {
  string: ["folder", "main", "out", "debounce", "trace", "tectonic", "listen", "editor-block", "fps", "engine", "taudot-socket"],
  boolean: ["help", "da1", "render-while-moving"],
});
if (args.help || !args.folder) {
  console.log(
    "usage: preview.ts --folder DIR [--main FILE] [--out DIR] [--debounce MS] [--trace FILE] [--listen SOCK] " +
      "[--editor-block BLOCK]",
  );
  Deno.exit(args.help ? 0 : 2);
}
const folder = resolve(args.folder);
const debounceMs = Number(args.debounce ?? 400);
const tectonic = args.tectonic ?? "tectonic";
const listenPath = args.listen ?? Deno.env.get("TAUDOT_PREVIEW_SOCKET");
const editorBlock = args["editor-block"] ?? Deno.env.get("TAUDOT_EDITOR_BLOCK");
const rexSession = Deno.env.get("REX_SESSION");
// --da1: after frames and snapshots, ask the terminal for DA1 and trace how long it took to answer (its parse time)
const da1Trace = Boolean(args.da1);
const enc = new TextEncoder();
const dec = new TextDecoder();

async function findMain(): Promise<string> {
  if (args.main) return args.main;
  try {
    await Deno.stat(join(folder, "main.tex"));
    return "main.tex";
  } catch { /* look further */ }
  const texs: string[] = [];
  for await (const e of Deno.readDir(folder)) if (e.isFile && e.name.endsWith(".tex")) texs.push(e.name);
  texs.sort();
  for (const t of texs) {
    const s = await Deno.readTextFile(join(folder, t)).catch(() => "");
    if (/^\s*\\documentclass/m.test(s)) return t;
  }
  return texs[0] ?? "main.tex";
}
const mainFile = await findMain();
const jobname = mainFile.replace(/\.tex$/, "").split("/").pop()!;

async function hash(s: string) {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-1", enc.encode(s)));
  return [...d.slice(0, 6)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
const outDir = args.out
  ? resolve(args.out)
  : join(Deno.env.get("TMPDIR") ?? "/tmp", `taudot-preview-${await hash(folder)}`);
const workDir = join(outDir, "work");
const pagesDir = join(outDir, "pages");
await Deno.mkdir(workDir, { recursive: true });
await Deno.remove(pagesDir, { recursive: true }).catch(() => {});
await Deno.mkdir(pagesDir, { recursive: true });

// ---- tracing (latency measurements) ---------------------------------------------------------------------------------

const tracePath = args.trace ?? Deno.env.get("TAUDOT_PREVIEW_TRACE");
const traceFile = tracePath ? await Deno.open(tracePath, { create: true, append: true }) : undefined;
function trace(ev: string, extra: Record<string, unknown> = {}) {
  traceFile?.writeSync(enc.encode(JSON.stringify({ t: Date.now(), ev, ...extra }) + "\n"));
}

// ---- terminal -------------------------------------------------------------------------------------------------------

function out(s: string) {
  const b = enc.encode(s);
  let n = 0;
  while (n < b.length) n += Deno.stdout.writeSync(b.subarray(n));
  return b.length;
}
const isTTY = Deno.stdin.isTerminal();
if (isTTY) Deno.stdin.setRaw(true);
// alternate screen, hide cursor, mouse: all motion (1003, for the pinch helper), drag, SGR (1006), SGR pixels (1016)
out("\x1b[?1049h\x1b[?25l\x1b[H\x1b[2J\x1b[?1003h\x1b[?1006h\x1b[?1016h");

let cols = 80, rows = 24;
let cellW = 0, cellH = 0, areaW = 0, areaH = 0;
let pixelMouse = true; // until the terminal says it doesn't do 1016
let fileTransfer = false; // Kitty t=f: the terminal reads the PNG from disk
let accent: [number, number, number] = [255, 196, 0];

function readSize() {
  try {
    const s = Deno.consoleSize();
    cols = s.columns;
    rows = s.rows;
  } catch { /* not a terminal */ }
}
readSize();

let lastStatus = "";
function status(state: "idle" | "working" | "blocked", msg: string) {
  if (state + msg === lastStatus) return;
  lastStatus = state + msg;
  out(osc7501(state, msg));
}

// ---- state ----------------------------------------------------------------------------------------------------------

type CompileState = "waiting" | "compiling" | "ok" | "error";
const st = {
  compile: "waiting" as CompileState,
  compileMs: 0,
  error: "",
  gen: 0, // generation of the good PDF
  pdf: "",
  sizes: [] as Size[],
  synctex: undefined as SyncTex | undefined,
  note: "", // a passing message under the page
  noteUntil: 0,
};
let zoom = 1; // relative to fit-width
let view: Viewport = { areaW: 1, areaH: 1, scale: 1, left: 0, top: 0 };
let lastZoomAt = 0, lastScrollAt = 0;
const ZOOM_SETTLE_MS = 150;

function note(s: string) {
  st.note = s;
  st.noteUntil = Date.now() + 4000;
  setTimeout(requestFrame, 4050);
  requestFrame();
}

function setScaleFromZoom() {
  if (!st.sizes.length || !areaW) return;
  view = { ...view, areaW, areaH, scale: fitWidthScale(st.sizes, areaW) * zoom };
  view = clampView(view, st.sizes);
}

// ---- compiling ------------------------------------------------------------------------------------------------------

let child: Deno.ChildProcess | undefined;
let compileId = 0;
let timer: ReturnType<typeof setTimeout> | undefined;
let changeAt = 0; // oldest change no started compile has seen yet
let runningSince = 0; // oldest change the running compile covers
let dirty = false; // a change landed while a compile we let run was running
let pendingChange = 0; // for the `drawn` trace: when the change behind the newest PDF happened

// Changes that keep coming (typing, an engine writing every 300 ms) would otherwise restart the debounce and kill
// every compile forever. Once the oldest unshown change is this old, compile at once and let it finish.
const maxWaitMs = Math.max(1000, debounceMs * 2.5);

function schedule(reason: string) {
  const now = Date.now();
  if (!changeAt) changeAt = now;
  trace("change", { reason });
  if (timer !== undefined) clearTimeout(timer);
  timer = undefined;
  if (child) {
    if (now - runningSince < maxWaitMs) {
      try {
        child.kill("SIGKILL");
      } catch { /* already gone */ }
      changeAt = Math.min(changeAt, runningSince);
    } else {
      dirty = true;
      return;
    }
  }
  const delay = now - changeAt >= maxWaitMs ? 0 : debounceMs;
  timer = setTimeout(() => {
    timer = undefined;
    compile();
  }, delay);
}

async function compile() {
  const id = ++compileId;
  const started = Date.now();
  const firstChange = changeAt || started;
  changeAt = 0;
  runningSince = firstChange;
  dirty = false;
  try {
    await compileOnce(id, started, firstChange);
  } finally {
    if (id === compileId && dirty) {
      dirty = false;
      schedule("changed during compile");
    }
  }
}

async function compileOnce(id: number, started: number, firstChange: number) {
  st.compile = "compiling";
  status("working", "compiling");
  requestFrame();
  trace("compile_start", { id });
  const cmd = new Deno.Command(tectonic, {
    args: ["-X", "compile", "--outdir", workDir, "--synctex", "--keep-logs", mainFile],
    cwd: folder,
    stdout: "piped",
    stderr: "piped",
    stdin: "null",
  });
  let res: Deno.CommandOutput;
  let proc: Deno.ChildProcess | undefined;
  try {
    proc = child = cmd.spawn();
    res = await proc.output();
  } catch (e) {
    if (child === proc) child = undefined;
    if (id !== compileId) return;
    finishError(`cannot run ${tectonic}: ${(e as Error).message}`, started);
    return;
  }
  if (child === proc) child = undefined;
  if (id !== compileId) return; // superseded; the newer compile reports
  if (res.signal) return; // killed by a newer change that hasn't started yet
  if (!res.success) {
    let msg = firstError(dec.decode(res.stderr) + dec.decode(res.stdout));
    if (!msg) {
      const log = await Deno.readTextFile(join(workDir, jobname + ".log")).catch(() => "");
      msg = firstError(log) ?? "compile failed";
    }
    finishError(msg, started);
    return;
  }
  // keep the good PDF under a new name so a later failure can't touch it
  const gen = st.gen + 1;
  const good = join(outDir, `good-${gen}.pdf`);
  const goodSync = join(outDir, `good-${gen}.synctex.gz`);
  try {
    await Deno.copyFile(join(workDir, jobname + ".pdf"), good);
    await Deno.copyFile(join(workDir, jobname + ".synctex.gz"), goodSync).catch(() => {});
  } catch (e) {
    finishError(`no PDF: ${(e as Error).message}`, started);
    return;
  }
  const [info, synctex] = await Promise.all([run("pdfinfo", ["-f", "1", "-l", "100000", good]), readSyncTex(goodSync)]);
  const { pages, sizes } = parsePdfinfo(info);
  if (id !== compileId) return;
  const old = st.pdf;
  const first = !old;
  Object.assign(st, { gen, pdf: good, sizes, synctex, compile: "ok", compileMs: Date.now() - started, error: "" });
  if (old) {
    // renders of the old PDF that are still in flight need it for a moment
    setTimeout(() => {
      Deno.remove(old).catch(() => {});
      Deno.remove(old.replace(/\.pdf$/, ".synctex.gz")).catch(() => {});
    }, 10_000);
  }
  pruneRenders(gen);
  if (first) view.top = 0;
  setScaleFromZoom();
  trace("compile_end", { id, ok: true, ms: st.compileMs, since_change: Date.now() - firstChange });
  status("idle", `${pages} page${pages === 1 ? "" : "s"}, compiled in ${(st.compileMs / 1000).toFixed(1)}s`);
  pendingChange = firstChange;
  requestFrame();
}

function finishError(msg: string, started: number) {
  Object.assign(st, { compile: "error", error: msg, compileMs: Date.now() - started });
  trace("compile_end", { ok: false, ms: st.compileMs, error: msg });
  status("blocked", fit(msg, 200));
  requestFrame();
}

async function run(cmd: string, a: string[]): Promise<string> {
  try {
    const r = await new Deno.Command(cmd, { args: a, stdout: "piped", stderr: "piped" }).output();
    return dec.decode(r.stdout);
  } catch {
    return "";
  }
}

// ---- rendering ------------------------------------------------------------------------------------------------------
//
// Page bitmaps come from pdftoppm as PPM and stay in memory as RGB; they go to the terminal zlib-compressed (in a
// worker) as files. Two regimes, per page:
// - small enough (whole page at the view's scale ≤ TILE_ABOVE): one "base" image per page (id IMG + page) at the
//   view's scale, placed unscaled. A "hi" render at 2x stays in memory for the zoom snapshot.
// - bigger (zoomed in): TILES of TILE×TILE px at the view's scale, like a PDF viewer. Only tiles in view plus one
//   ring are rendered (one pdftoppm call per page for the box of missing tiles, cut up in memory), each sent once and
//   cached by (page, scale, tile), each placed with its own source rectangle. Under them the base image is an
//   UNDERLAY: the whole page at ≤ UNDER_PIXELS, placed scaled (z=-1), visible wherever a tile is still missing.

const IMG = 7_510_000;
const SNAP = [7_509_990, 7_509_991];
const MARK = 7_509_999;
const TILE_BASE = 100_000_000;
const TILE = 512;
const TILE_ABOVE = 4_000_000;
const UNDER_PIXELS = 2_000_000;
const HI_PIXELS = 8_000_000;
const MAX_RENDERS = 4;

interface Render {
  gen: number;
  page: number;
  scale: number;
  ox: number;
  oy: number;
  w: number;
  h: number;
  rgb: Uint8Array;
  file?: string; // zlib RGB for t=f
  zb64?: string; // zlib + base64, when the terminal can't read files
  key: string;
}
const shown = new Map<number, Render>(); // transmitted, under IMG + page
const ready = new Map<number, Render>(); // rendered, waiting for the next frame
const hi = new Map<number, Render>(); // 2x bitmaps for the snapshot (untiled pages)
const rendering = new Map<string, string>(); // "kind:page" -> key being rendered
let placed = new Set<number>(); // pages with a base placement on screen

/** Whether `page` is drawn with tiles at the current scale. */
function tiled(page: number): boolean {
  const [pw, ph] = st.sizes[page];
  return Math.ceil(pw * view.scale) * Math.ceil(ph * view.scale) > TILE_ABOVE;
}

/** The scale of a page's base image: the view's, or the underlay's when tiled. */
function baseScale(page: number): number {
  if (!tiled(page)) return view.scale;
  const [pw, ph] = st.sizes[page];
  return Math.sqrt(UNDER_PIXELS / (pw * ph));
}

function goodBase(r: Render | undefined, page: number): boolean {
  return !!r && r.gen === st.gen && Math.abs(r.scale / baseScale(page) - 1) < 0.005;
}

function goodHi(r: Render | undefined): boolean {
  return !!r && r.gen === st.gen && Math.abs(r.scale / (view.scale * 2) - 1) < 0.005;
}

// zlib off the main thread (zlib-worker.ts)
const zworker = new Worker(new URL("./zlib-worker.ts", import.meta.url).href, { type: "module" });
const zwaiting = new Map<number, (r: { z: Uint8Array; data: Uint8Array }) => void>();
let zseq = 0;
zworker.onmessage = (e: MessageEvent<{ id: number; z: Uint8Array; data: Uint8Array }>) => {
  zwaiting.get(e.data.id)?.(e.data);
  zwaiting.delete(e.data.id);
};
/** Compresses `data` in the worker. `data` is handed over and comes back as `.data`; don't use the old one. */
function compress(data: Uint8Array): Promise<{ z: Uint8Array; data: Uint8Array }> {
  const id = ++zseq;
  return new Promise((res) => {
    zwaiting.set(id, res);
    zworker.postMessage({ id, data }, [data.buffer as ArrayBuffer]);
  });
}

let fileSeq = 0;
async function zfile(rgb: Uint8Array, name: string): Promise<{ rgb: Uint8Array; file?: string; zb64?: string }> {
  const { z, data } = await compress(rgb);
  if (!fileTransfer) return { rgb: data, zb64: encodeBase64(z) };
  const file = join(pagesDir, `${name}-${++fileSeq % 512}.z`);
  await Deno.writeFile(file, z);
  return { rgb: data, file };
}

async function pdftoppm(page: number, scale: number, x: number, y: number, w: number, h: number) {
  const p = String(page + 1);
  const a = ["-f", p, "-l", p, "-r", String(scale * 72), "-x", String(x), "-y", String(y), "-W", String(w)];
  a.push("-H", String(h), "-singlefile", st.pdf);
  const res = await new Deno.Command("pdftoppm", { args: a, stdout: "piped", stderr: "null" }).output();
  return res.success ? parsePpm(res.stdout) : undefined;
}

// The persistent renderer (render/pdfrender, CoreGraphics): one process with the PDF open, ~4x less CPU per tile
// than a pdftoppm process, and it writes the zlib file itself. Falls back to pdftoppm + the zlib worker.
const RENDERER = new URL("./render/pdfrender", import.meta.url).pathname;
// --engine texpresso: txp-headless typesets incrementally and draws the pages itself (see texpresso/).
const ENGINE = args.engine ?? "tectonic";
let txp: Txp | undefined;
let daemon: { w: WritableStreamDefaultWriter<Uint8Array>; doc: string } | undefined;
const daemonWaiting = new Map<number, (r: Record<string, unknown>) => void>();
let daemonSeq = 0;
try {
  Deno.statSync(RENDERER);
  const p = new Deno.Command(RENDERER, { stdin: "piped", stdout: "piped", stderr: "null" }).spawn();
  daemon = { w: p.stdin.getWriter(), doc: "" };
  (async () => {
    let buf = "";
    for await (const c of p.stdout.pipeThrough(new TextDecoderStream())) {
      buf += c;
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const m = JSON.parse(buf.slice(0, nl));
        buf = buf.slice(nl + 1);
        daemonWaiting.get(m.id)?.(m);
        daemonWaiting.delete(m.id);
      }
    }
  })();
} catch { /* not built: pdftoppm */ }
function ask(o: Record<string, unknown>): Promise<Record<string, unknown>> {
  const id = ++daemonSeq;
  return new Promise((res) => {
    daemonWaiting.set(id, res);
    daemon!.w.write(enc.encode(JSON.stringify({ ...o, id }) + "\n"));
  });
}
let rseq = 0;
/** Renders a pixel rectangle of a page; with `z`, also a zlib file (or base64) for the terminal. */
async function renderRect(page: number, scale: number, x: number, y: number, w: number, h: number, z: boolean, name: string): Promise<
  { w: number; h: number; rgb: Uint8Array; file?: string; zb64?: string; cpu_us?: number } | undefined
> {
  if (txp) {
    // TeXpresso draws its own pages (MuPDF display lists of the XDV), same request shape as pdfrender
    const n = ++rseq % 1024;
    const rgbPath = join(pagesDir, `r${n}.rgb`), zPath = join(pagesDir, `${name}-${n}.z`);
    const r = await txp.render(page, scale, x, y, w, h, rgbPath, z ? zPath : "");
    if (!r.ok) return undefined;
    const rgb = await Deno.readFile(rgbPath);
    Deno.remove(rgbPath).catch(() => {});
    if (z && !fileTransfer) {
      const zb64 = encodeBase64(await Deno.readFile(zPath));
      Deno.remove(zPath).catch(() => {});
      return { w, h, rgb, zb64, cpu_us: r.cpu_us as number };
    }
    return { w, h, rgb, file: z ? zPath : undefined, cpu_us: r.cpu_us as number };
  }
  if (daemon) {
    if (daemon.doc !== st.pdf) {
      daemon.doc = st.pdf;
      await ask({ op: "open", path: st.pdf });
    }
    const n = ++rseq % 1024;
    const rgbPath = join(pagesDir, `r${n}.rgb`), zPath = join(pagesDir, `${name}-${n}.z`);
    const r = await ask({ op: "render", page: page + 1, scale, x, y, w, h, rgb: rgbPath, ...(z ? { z: zPath } : {}) });
    if (!r.ok) return undefined;
    const rgb = await Deno.readFile(rgbPath);
    Deno.remove(rgbPath).catch(() => {});
    if (z && !fileTransfer) {
      const zb64 = encodeBase64(await Deno.readFile(zPath));
      Deno.remove(zPath).catch(() => {});
      return { w, h, rgb, zb64, cpu_us: r.cpu_us as number };
    }
    return { w, h, rgb, file: z ? zPath : undefined, cpu_us: r.cpu_us as number };
  }
  const ppm = await pdftoppm(page, scale, x, y, w, h);
  if (!ppm) return undefined;
  if (!z) return { w: ppm.w, h: ppm.h, rgb: ppm.rgb };
  return { w: ppm.w, h: ppm.h, ...(await zfile(ppm.rgb, name)) };
}

function startRender(kind: "base" | "hi", page: number) {
  const slot = `${kind}:${page}`;
  if (rendering.has(slot)) return; // one per page and kind; the next frame asks again if it no longer fits
  const scale = kind === "base" ? baseScale(page) : view.scale * 2;
  const [pw, ph] = st.sizes[page];
  const W = Math.ceil(pw * scale), H = Math.ceil(ph * scale);
  const gen = st.gen;
  const key = `${gen}-${page}-${kind}-${scale.toFixed(5)}`;
  if (kind === "base") {
    const have = ready.get(page) ?? shown.get(page);
    trace("render_why", { page: page + 1, have: have ? { gen: have.gen, scale: +have.scale.toFixed(4), from: ready.has(page) ? "ready" : "shown" } : null, gen, scale: +scale.toFixed(4), tiled: tiled(page) });
  }
  rendering.set(slot, key);
  const t0 = Date.now();
  renderRect(page, scale, 0, 0, W, H, kind === "base", `${gen}-${page}`).then((ppm) => {
    if (!ppm) {
      rendering.delete(slot);
      return;
    }
    const r: Render = { gen, page, scale, ox: 0, oy: 0, w: ppm.w, h: ppm.h, rgb: ppm.rgb, key, file: ppm.file, zb64: ppm.zb64 };
    if (kind === "hi") {
      rendering.delete(slot);
      if (gen === st.gen) hi.set(page, r);
      trace("rendered", { kind, page: page + 1, ms: Date.now() - t0, w: r.w, h: r.h });
      requestFrame();
      return;
    }
    rendering.delete(slot);
    // drop it if a render of a newer PDF is already there
    const cur = ready.get(page) ?? shown.get(page);
    if (cur && cur.gen > r.gen) return;
    ready.set(page, r);
    trace("rendered", { kind, page: page + 1, ms: Date.now() - t0, w: r.w, h: r.h });
    requestFrame();
  }).catch(() => rendering.delete(slot));
}

// tiles ---------------------------------------------------------------------------------------------------------------

interface Tile {
  key: string; // gen:page:scale:tx:ty
  id: number;
  gen: number;
  page: number;
  scale: number;
  tx: number;
  ty: number;
  ox: number; // page pixels at `scale`
  oy: number;
  w: number;
  h: number;
  rgb: Uint8Array;
  file?: string;
  zb64?: string;
  sent: boolean;
}
const tiles = new Map<string, Tile>();
let placedTiles = new Set<number>(); // tile image ids with a placement on screen
let tileScaleSeq = 0, tileScaleKey = "";

const scaleKey = (s = view.scale) => s.toFixed(5);
const tileKey = (page: number, tx: number, ty: number, s = view.scale) => `${st.gen}:${page}:${scaleKey(s)}:${tx}:${ty}`;

/** Tile index range covering a piece at the view's scale, grown by `ring` tiles, within the page. */
function tileRange(pc: Piece, ring: number, s = view.scale) {
  const [pw, ph] = st.sizes[pc.page];
  const nx = Math.ceil((pw * s) / TILE), ny = Math.ceil((ph * s) / TILE);
  return {
    tx0: Math.max(0, Math.floor((pc.x0 * s) / TILE) - ring),
    tx1: Math.min(nx - 1, Math.floor((pc.x1 * s - 1) / TILE) + ring),
    ty0: Math.max(0, Math.floor((pc.y0 * s) / TILE) - ring),
    ty1: Math.min(ny - 1, Math.floor((pc.y1 * s - 1) / TILE) + ring),
  };
}

/** Renders the missing tiles of a piece (in view first, then one ring) in one pdftoppm call, and cuts them up. */
function startTiles(pc: Piece, s = view.scale, ring = 1) {
  const page = pc.page;
  const slot = `tiles:${page}`;
  if (rendering.has(slot)) return;
  const gen = st.gen, sk = scaleKey(s);
  const [pw, ph] = st.sizes[page];
  const fullW = Math.ceil(pw * s), fullH = Math.ceil(ph * s);
  const missing = (r: ReturnType<typeof tileRange>) => {
    const out: [number, number][] = [];
    for (let ty = r.ty0; ty <= r.ty1; ty++) {
      for (let tx = r.tx0; tx <= r.tx1; tx++) if (!tiles.has(tileKey(page, tx, ty, s))) out.push([tx, ty]);
    }
    return out;
  };
  let need = missing(tileRange(pc, 0, s));
  if (need.length === 0 && ring > 0) need = missing(tileRange(pc, ring, s));
  if (need.length === 0) return;
  const tx0 = Math.min(...need.map((t) => t[0])), tx1 = Math.max(...need.map((t) => t[0]));
  const ty0 = Math.min(...need.map((t) => t[1])), ty1 = Math.max(...need.map((t) => t[1]));
  const x = tx0 * TILE, y = ty0 * TILE;
  const W = Math.min(fullW, (tx1 + 1) * TILE) - x, H = Math.min(fullH, (ty1 + 1) * TILE) - y;
  rendering.set(slot, `${gen}:${page}:${sk}`);
  const t0 = Date.now();
  if (daemon || txp) {
    // one request per tile: the renderer keeps the page open, writes each tile's zlib file itself
    // TeXpresso: all of a page's requests at once (it answers them between typesetting slices), and the tiles go
    // on screen together, so a changed page never shows half old, half new lines
    const early = txp
      ? new Map(need.map(([tx, ty]) => {
        const ox = tx * TILE, oy = ty * TILE;
        const w = Math.min(TILE, fullW - ox), h = Math.min(TILE, fullH - oy);
        return [`${tx}:${ty}`, w > 0 && h > 0 ? renderRect(page, s, ox, oy, w, h, true, `t${gen}-${page}-${tx}-${ty}`) : undefined];
      }))
      : undefined;
    const batch: Tile[] = [];
    (async () => {
      let n = 0, cpu = 0;
      for (const [tx, ty] of need) {
        const key = `${gen}:${page}:${sk}:${tx}:${ty}`;
        if (tiles.has(key) || gen !== st.gen) continue;
        const ox = tx * TILE, oy = ty * TILE;
        const w = Math.min(TILE, fullW - ox), h = Math.min(TILE, fullH - oy);
        if (w <= 0 || h <= 0) continue;
        const r = early ? await early.get(`${tx}:${ty}`) : await renderRect(page, s, ox, oy, w, h, true, `t${gen}-${page}-${tx}-${ty}`);
        if (!r) continue;
        if (sk !== tileScaleKey) {
          tileScaleKey = sk;
          tileScaleSeq++;
        }
        const id = TILE_BASE + (tileScaleSeq % 4) * 25_000_000 + page * 10_000 + ty * 100 + tx;
        const t: Tile = { key, id, gen, page, scale: s, tx, ty, ox, oy, w, h, rgb: r.rgb, file: r.file, zb64: r.zb64, sent: false };
        if (early) batch.push(t);
        else if ((sk === scaleKey() || sk === targetKey) && gen === st.gen) tiles.set(key, t);
        n++;
        cpu += r.cpu_us ?? 0;
      }
      for (const t of batch) if ((sk === scaleKey() || sk === targetKey) && t.gen === st.gen) tiles.set(t.key, t);
      rendering.delete(slot);
      trace("tiles", { page: page + 1, n, total_ms: Date.now() - t0, cpu_ms: Math.round(cpu / 100) / 10, renderer: txp ? "texpresso" : "pdfrender" });
      requestFrame();
    })().catch(() => rendering.delete(slot));
    return;
  }
  pdftoppm(page, s, x, y, W, H).then(async (ppm) => {
    if (!ppm || gen !== st.gen) {
      rendering.delete(slot);
      return;
    }
    if (sk !== tileScaleKey) {
      tileScaleKey = sk;
      tileScaleSeq++;
    }
    const t1 = Date.now();
    let n = 0;
    for (const [tx, ty] of need) {
      const key = `${gen}:${page}:${sk}:${tx}:${ty}`;
      if (tiles.has(key)) continue;
      const ox = tx * TILE, oy = ty * TILE;
      const w = Math.min(TILE, ppm.w + x - ox), h = Math.min(TILE, ppm.h + y - oy);
      if (w <= 0 || h <= 0) continue;
      const rgb = new Uint8Array(w * h * 3);
      for (let row = 0; row < h; row++) {
        const src = ((oy - y + row) * ppm.w + (ox - x)) * 3;
        rgb.set(ppm.rgb.subarray(src, src + w * 3), row * w * 3);
      }
      const id = TILE_BASE + (tileScaleSeq % 4) * 25_000_000 + page * 10_000 + ty * 100 + tx;
      const t: Tile = { key, id, gen, page, scale: s, tx, ty, ox, oy, w, h, rgb, sent: false };
      Object.assign(t, await zfile(rgb, `t${gen}-${page}-${tx}-${ty}`));
      if ((sk === scaleKey() || sk === targetKey) && gen === st.gen) tiles.set(key, t);
      n++;
    }
    rendering.delete(slot);
    trace("tiles", { page: page + 1, n, render_ms: t1 - t0, total_ms: Date.now() - t0, w: ppm.w, h: ppm.h });
    requestFrame();
  }).catch(() => rendering.delete(slot));
}

/** Quiet mode, while idle: the document from 1.5 screens above to 2.5 screens below the view. */
function idlePieces(): Piece[] {
  if (!st.sizes.length) return [];
  const viewH = areaH / view.scale;
  return visiblePieces({ ...view, top: view.top - viewH * 1.5, areaH: viewH * 5 * view.scale }, st.sizes);
}

/** The part of the document the scroll is heading into, as pieces: up to two screens, by velocity and target. */
function aheadPieces(): Piece[] {
  if (!st.sizes.length) return [];
  const viewH = areaH / view.scale;
  const toTarget = scrollTarget ? scrollTarget.top - view.top : 0;
  const dir = Math.sign(toTarget || scrollVel);
  if (!dir) return [];
  const ahead = Math.min(2 * viewH, Math.abs(toTarget) + Math.abs(scrollVel) * 400 + viewH * 0.5);
  const top = dir > 0 ? view.top + viewH : view.top - ahead;
  return visiblePieces({ ...view, top, areaH: ahead * view.scale }, st.sizes);
}

let targetKey = ""; // scale key of the zoom target whose tiles are being fetched
/** During a wheel zoom whose target has held for 60 ms: render the target view's tiles at the target scale. */
function prefetchZoomTarget() {
  if (!zoomAnim || gesture || Date.now() - zoomTargetAt < 60 || busy()) return;
  const s = fitWidthScale(st.sizes, areaW) * zoomTarget;
  targetKey = scaleKey(s);
  const tv = clampView(zoomAt({ ...view, areaW, areaH }, s, anchor.x, anchor.y), st.sizes);
  for (const pc of visiblePieces(tv, st.sizes)) {
    const [pw, ph] = st.sizes[pc.page];
    if (Math.ceil(pw * s) * Math.ceil(ph * s) <= TILE_ABOVE || busy()) continue;
    startTiles(pc, s, 0);
  }
}

function busy() {
  return rendering.size >= MAX_RENDERS;
}

function scheduleRenders(pieces: Piece[]) {
  if (!st.pdf) return;
  if (zoomActive && !settled()) {
    // no renders at in-between scales (quiet mode: none at all while zooming; otherwise the wheel zoom's target)
    if (!QUIET) prefetchZoomTarget();
    setTimeout(requestFrame, Math.max(5, ZOOM_SETTLE_MS - (Date.now() - lastZoomAt) + 5));
    return;
  }
  if (QUIET && movingNow()) {
    // Rex drops to 60 Hz under any CPU load, so while the view moves only what's cached is placed. The one
    // exception: a visible page with no image at all gets its (small) base image, or it would be a hole.
    for (const pc of pieces) {
      if (busy()) break;
      if (!ready.get(pc.page) && !shown.get(pc.page)) startRender("base", pc.page);
    }
    setTimeout(requestFrame, 130); // look again once it stops
    return;
  }
  // what's in view: base images (or underlays), then tiles in view. With TeXpresso, a changed page that is tiled
  // keeps its old underlay and tiles on screen, so its new tiles come first.
  for (const pc of pieces) {
    if (busy()) return;
    if (txp && tiled(pc.page) && shown.has(pc.page)) continue;
    if (!goodBase(ready.get(pc.page) ?? shown.get(pc.page), pc.page)) startRender("base", pc.page);
  }
  for (const pc of pieces) {
    if (busy()) return;
    if (tiled(pc.page)) startTiles(pc, view.scale, 0);
  }
  // around the view (quiet: 1.5 screens up to 2.5 down, base images and tiles; else ahead of the scroll), one ring
  const around = QUIET ? idlePieces() : aheadPieces();
  for (const pc of around) {
    if (busy()) return;
    if (!goodBase(ready.get(pc.page) ?? shown.get(pc.page), pc.page)) startRender("base", pc.page);
  }
  for (const pc of around) {
    if (busy()) return;
    if (tiled(pc.page)) startTiles(pc, view.scale, 0);
  }
  for (const pc of pieces) {
    if (busy()) return;
    if (tiled(pc.page)) startTiles(pc, view.scale, 1);
  }
  if (rendering.size > 0 || pieces.length === 0 || zoomActive) return;
  // idle: neighbours' base images, then 2x bitmaps of untiled pages in view
  for (const p of [pieces[pieces.length - 1].page + 1, pieces[0].page - 1]) {
    if (p < 0 || p >= st.sizes.length || busy()) continue;
    if (!goodBase(ready.get(p) ?? shown.get(p), p)) startRender("base", p);
  }
  if (rendering.size > 0) return;
  for (const pc of pieces) {
    if (busy()) return;
    if (tiled(pc.page)) continue;
    const [pw, ph] = st.sizes[pc.page];
    if (pw * ph * 4 * view.scale * view.scale > HI_PIXELS) continue;
    if (!goodHi(hi.get(pc.page))) startRender("hi", pc.page);
  }
}

async function pruneRenders(gen: number) {
  for await (const e of Deno.readDir(pagesDir)) {
    const g = Number(e.name.replace(/^t/, "").split("-")[0]);
    if (g < gen - 1) Deno.remove(join(pagesDir, e.name)).catch(() => {});
  }
  for (const [p, r] of hi) if (r.gen < gen) hi.delete(p);
}

/** Tile placements for a frame, and tiles to send or free. */
function drawTiles(pieces: Piece[]): string {
  let s = "";
  const keepStale = new Set<string>();
  const now = new Set<number>();
  const keep = new Set<string>();
  let tmiss = 0;
  let sent = 0;
  for (const pc of QUIET ? idlePieces() : aheadPieces()) {
    if (!tiled(pc.page)) continue;
    const r = tileRange(pc, 0);
    for (let ty = r.ty0; ty <= r.ty1; ty++) {
      for (let tx = r.tx0; tx <= r.tx1; tx++) keep.add(tileKey(pc.page, tx, ty));
    }
  }
  for (const pc of pieces) {
    if (!tiled(pc.page)) continue;
    const vis = tileRange(pc, 0), ring = tileRange(pc, 2);
    for (let ty = ring.ty0; ty <= ring.ty1; ty++) {
      for (let tx = ring.tx0; tx <= ring.tx1; tx++) {
        const sk = `${pc.page}:${scaleKey()}:${tx}:${ty}`;
        let t = tiles.get(tileKey(pc.page, tx, ty));
        const inView = tx >= vis.tx0 && tx <= vis.tx1 && ty >= vis.ty0 && ty <= vis.ty1;
        if (t) staleTiles.delete(sk); // the new tile reuses the old one's image id: transmitting it swaps in place
        else if (staleTiles.has(sk)) {
          t = staleTiles.get(sk)!;
          keepStale.add(sk);
        }
        if (!t) {
          if (inView) tmiss++;
          continue;
        }
        if (t.gen === st.gen) keep.add(t.key);
        if (!t.sent) {
          s += t.file
            ? `\x1b_Ga=t,f=24,s=${t.w},v=${t.h},o=z,t=f,i=${t.id},q=2;${btoa(t.file)}\x1b\\`
            : chunked(`a=t,f=24,s=${t.w},v=${t.h},o=z,t=d,i=${t.id},q=2`, t.zb64 ?? "");
          t.sent = true;
          sent++;
          if (inView && pendingChange && t.gen === st.gen && (!txpChanged || txpChanged.has(pc.page))) {
            trace("drawn", { page: pc.page + 1, tiles: true, since_change: Date.now() - pendingChange });
            pendingChange = 0;
          }
        }
        if (tx < vis.tx0 || tx > vis.tx1 || ty < vis.ty0 || ty > vis.ty1) continue;
        const pl = placePiece(pc, view.scale, t, cellW, cellH);
        if (!pl) continue;
        s += `\x1b[${pl.row + 1};${pl.col + 1}H\x1b_Ga=p,i=${t.id},p=1,x=${pl.x},y=${pl.y},w=${pl.w},h=${pl.h},` +
          `X=${pl.X},Y=${pl.Y},z=0,C=1,q=2\x1b\\`;
        now.add(t.id);
      }
    }
  }
  // idle: send what's been prefetched around the view, so a scroll needs no transfers (Rex decodes them)
  if (QUIET && !movingNow()) {
    let budget = 6;
    for (const t of tiles.values()) {
      if (budget <= 0) {
        setTimeout(requestFrame, 20);
        break;
      }
      if (t.sent || !keep.has(t.key)) continue;
      s += t.file
        ? `\x1b_Ga=t,f=24,s=${t.w},v=${t.h},o=z,t=f,i=${t.id},q=2;${btoa(t.file)}\x1b\\`
        : chunked(`a=t,f=24,s=${t.w},v=${t.h},o=z,t=d,i=${t.id},q=2`, t.zb64 ?? "");
      t.sent = true;
      sent++;
      budget--;
    }
  }
  // stale tiles out of view or of another scale: free them unless a current tile uses the same image id
  for (const [k, t] of staleTiles) {
    if (keepStale.has(k)) continue;
    staleTiles.delete(k);
    if (![...tiles.values()].some((c) => c.id === t.id && c.sent)) s += `\x1b_Ga=d,d=I,i=${t.id},q=2\x1b\\`;
  }
  for (const id of placedTiles) if (!now.has(id)) s += `\x1b_Ga=d,d=i,i=${id},p=1,q=2\x1b\\`;
  placedTiles = now;
  // free tiles far from the view, of another scale or PDF
  for (const [key, t] of tiles) {
    if (keep.has(key)) continue;
    if (t.sent) s += `\x1b_Ga=d,d=I,i=${t.id},q=2\x1b\\`;
    tiles.delete(key);
  }
  tilesSentThisFrame = sent;
  tilesMissingThisFrame = tmiss;
  return s;
}
let tilesSentThisFrame = 0, tilesMissingThisFrame = 0;

// ---- snapshot -------------------------------------------------------------------------------------------------------
//
// One RGBA image composited from the page bitmaps already in memory, built when a zoom starts (nothing is sent while
// idle). Its shape follows the first zoom step: zooming in needs detail but no more area, so it is the view at 2x (from
// the 2x bitmaps when they exist); zooming out needs area but less detail, so it is the view plus a wide margin at
// 0.7x. During a zoom it is the only thing placed, in a fixed whole-pane box, and the zoom only moves its source
// rectangle (lib.placeSnapshot). It goes to the terminal as a zlib file, compressed in the worker. If a zoom-out
// outgrows it, a wider one is built from the same bitmaps and swapped in.

interface Snap extends Snapshot {
  gen: number;
  slot: number; // index into SNAP
  dir: "in" | "out";
}
let snap: Snap | undefined; // the one the terminal has
let snapBuilding = false;
let snapPlaced = false;
/** A snapshot slot left under the pages after a swap, deleted SNAP_LINGER_MS later. */
let fadingSnap: number | undefined;
let fadingSnapAt = 0;
const SNAP_LINGER_MS = 150;
let snapSeq = 0;
let lastSnapBuild = 0;

/** The document rectangle the view shows. */
function viewRect() {
  return { x0: view.left, y0: view.top, x1: view.left + areaW / view.scale, y1: view.top + areaH / view.scale };
}

function snapCovers(s: Snap | undefined): boolean {
  if (!s || s.gen !== st.gen) return false;
  const r = viewRect();
  return r.x0 >= s.left - 0.5 && r.y0 >= s.top - 0.5 && r.x1 <= s.left + s.w / s.scale + 0.5 &&
    r.y1 <= s.top + s.h / s.scale + 0.5;
}

const SNAP_IN_PIXELS = 3_000_000, SNAP_OUT_PIXELS = 3_000_000;
// snapshots bigger than this go raw (TAUDOT_SNAP_RAW_ABOVE, bytes; Infinity = always zlib)
const SNAP_RAW_ABOVE = Number(Deno.env.get("TAUDOT_SNAP_RAW_ABOVE") ?? 16_000_000);

/** Composites a snapshot of the view for a zoom in direction `dir` and sends it. */
async function buildSnapshot(dir: "in" | "out") {
  if (!st.sizes.length || !areaW || snapBuilding) return;
  snapBuilding = true;
  lastSnapBuild = Date.now();
  try {
    const t0 = performance.now();
    const r = viewRect();
    const vw = r.x1 - r.x0, vh = r.y1 - r.y0;
    const tops = pageTops(st.sizes), dw = docWidth(st.sizes);
    const dh = tops.at(-1)! + st.sizes.at(-1)![1];
    const m = dir === "in" ? 0.05 : 0.75;
    // the view itself always (so the box never has to shrink), plus a margin that stays on the document
    const R = {
      x0: Math.min(r.x0, Math.max(0, r.x0 - vw * m)),
      y0: Math.min(r.y0, Math.max(0, r.y0 - vh * m)),
      x1: Math.max(r.x1, Math.min(dw, r.x1 + vw * m)),
      y1: Math.max(r.y1, Math.min(dh, r.y1 + vh * m)),
    };
    const pagesIn = st.sizes.map((_, p) => p).filter((p) => tops[p] < R.y1 && tops[p] + st.sizes[p][1] > R.y0);
    const useHi = dir === "in" && pagesIn.every((p) => !tiled(p) && goodHi(hi.get(p)));
    const sources = new Map<number, Render>();
    for (const p of pagesIn) {
      const src = useHi ? hi.get(p) : shown.get(p) ?? ready.get(p);
      if (src) sources.set(p, src);
    }
    if (sources.size === 0) return;
    const area = (R.x1 - R.x0) * (R.y1 - R.y0);
    const want = dir === "in" ? view.scale * (useHi ? 2 : 1) : view.scale * 0.7;
    const scale = Math.min(want, Math.sqrt((dir === "in" ? SNAP_IN_PIXELS : SNAP_OUT_PIXELS) / area));
    const s: Snap = {
      left: R.x0,
      top: R.y0,
      scale,
      w: Math.max(1, Math.ceil((R.x1 - R.x0) * scale)),
      h: Math.max(1, Math.ceil((R.y1 - R.y0) * scale)),
      gen: st.gen,
      slot: snap ? 1 - snap.slot : fadingSnap !== undefined ? 1 - fadingSnap : 0, // never the one about to be deleted
      dir,
    };
    const rgba = new Uint8Array(s.w * s.h * 4); // transparent where no page is
    for (const [p, src] of sources) blitPage(rgba, s, src, (dw - st.sizes[p][0]) / 2, tops[p]);
    // tiles of this scale over the underlays: the sharp parts
    for (const t of tiles.values()) {
      if (t.gen === st.gen && t.scale === view.scale && pagesIn.includes(t.page)) {
        blitPage(rgba, s, t, (dw - st.sizes[t.page][0]) / 2, tops[t.page]);
      }
    }
    const t1 = performance.now();
    let cmd: string;
    if (s.slot === fadingSnap) fadingSnap = undefined; // this slot gets new pixels: don't delete them later
    let zbytes = 0;
    const raw = fileTransfer && rgba.length > SNAP_RAW_ABOVE;
    if (raw) {
      // big: zlib would cost more time than the terminal saves (bench numbers in the log)
      const file = join(pagesDir, `snap-${++snapSeq % 4}.rgba`);
      await Deno.writeFile(file, rgba);
      cmd = `\x1b_Ga=t,f=32,s=${s.w},v=${s.h},t=f,i=${SNAP[s.slot]},q=2;${btoa(file)}\x1b\\`;
    } else if (fileTransfer) {
      const { z } = await compress(rgba);
      zbytes = z.length;
      const file = join(pagesDir, `snap-${++snapSeq % 4}.rgba.z`);
      await Deno.writeFile(file, z);
      cmd = `\x1b_Ga=t,f=32,s=${s.w},v=${s.h},o=z,t=f,i=${SNAP[s.slot]},q=2;${btoa(file)}\x1b\\`;
    } else {
      const { z } = await compress(rgba);
      cmd = chunked(`a=t,f=32,s=${s.w},v=${s.h},o=z,t=d,i=${SNAP[s.slot]},q=2`, encodeBase64(z));
    }
    if (s.gen !== st.gen) return;
    out(cmd);
    const old = snap;
    snap = s;
    pendingSnapDelete = old && old.slot !== s.slot ? old.slot : undefined; // deleted in the frame that places s
    trace("snapshot", {
      dir,
      w: s.w,
      h: s.h,
      hi: useHi,
      blit_ms: +(t1 - t0).toFixed(1),
      raw,
      ready_ms: +(performance.now() - t0).toFixed(1),
      zbytes,
    });
    if (da1Trace) da1("snapshot");
    requestFrame();
  } finally {
    snapBuilding = false;
  }
}
let pendingSnapDelete: number | undefined;

// ---- zooming --------------------------------------------------------------------------------------------------------

let zoomActive = false; // the snapshot is what's on screen
let zoomTarget = 1;
let anchor = { x: 0, y: 0 };
let zoomAnim = false; // easing toward zoomTarget
let gesture = false; // a pinch is in progress (between its began and ended)
let lastAnimAt = 0;
let lastFit = 2; // the zoom smart-zoom goes back to

function settled() {
  return !gesture && !zoomAnim && Date.now() - lastZoomAt >= ZOOM_SETTLE_MS;
}

// ---- scrolling ------------------------------------------------------------------------------------------------------
//
// Wheel events, keys and forward search move a target; the view eases toward it at ~60 fps (exponential, time
// constant SCROLL_TAU_MS, ~90 ms to settle). Pages are placed to the pixel every frame, so motion is continuous.
// Drag-pan follows the pointer directly.

const SCROLL_TAU_MS = 30;
// animation tick: --fps (default 60); easing is in time, so the rate only changes how often a frame goes out
const TICK_MS = 1000 / Math.max(10, Number(args.fps ?? 60));
// Quiet motion (default): no renders while the view moves, since Rex drops to 60 Hz under any CPU load; instead
// prefetch, and send to the terminal, further around the view while idle. --render-while-moving turns it off.
const QUIET = !args["render-while-moving"];
const movingNow = () => !!scrollTarget || !!drag || zoomAnim || gesture || Date.now() - lastScrollAt < 120;
let scrollTarget: { left: number; top: number } | undefined;
let lastWheelAt = 0;
let scrollVel = 0; // pt/ms
let zoomTargetAt = 0; // when zoomTarget last changed

function scrollTo(left: number, top: number) {
  if (!st.sizes.length) return;
  const c = clampView({ ...view, areaW, areaH, left, top }, st.sizes);
  scrollTarget = { left: c.left, top: c.top };
  startAnim();
}

function scrollBy(dxPx: number, dyPx: number) {
  const base = scrollTarget ?? { left: view.left, top: view.top };
  scrollTo(base.left + dxPx / view.scale, base.top + dyPx / view.scale);
}

let animTimer: ReturnType<typeof setTimeout> | undefined;
let animNext = 0; // deadline of the next tick: fixed steps of TICK_MS, so frames don't drift to 9-11 ms
function startAnim() {
  if (animTimer !== undefined) return;
  lastAnimAt = performance.now();
  animNext = lastAnimAt;
  animTimer = setTimeout(tick, 0);
}

/** One animation frame: ease zoom and scroll toward their targets, then draw. */
function tick() {
  animTimer = undefined;
  const now = performance.now();
  const dt = Math.min(50, Math.max(1, now - lastAnimAt));
  lastAnimAt = now;
  let moving = false;
  if (zoomAnim) {
    applyZoom(easeZoom(zoom, zoomTarget, dt));
    lastZoomAt = Date.now();
    if (zoom === zoomTarget) {
      zoomAnim = false;
      setTimeout(requestFrame, ZOOM_SETTLE_MS + 5);
    } else moving = true;
  }
  const top0 = view.top;
  if (scrollTarget) {
    const a = 1 - Math.exp(-dt / SCROLL_TAU_MS);
    view.left += (scrollTarget.left - view.left) * a;
    view.top += (scrollTarget.top - view.top) * a;
    if (
      Math.abs(scrollTarget.left - view.left) * view.scale < 0.3 &&
      Math.abs(scrollTarget.top - view.top) * view.scale < 0.3
    ) {
      view.left = scrollTarget.left;
      view.top = scrollTarget.top;
      scrollTarget = undefined;
    } else moving = true;
    lastScrollAt = Date.now();
  }
  scrollVel = scrollVel * 0.6 + ((view.top - top0) / dt) * 0.4; // pt per ms, smoothed
  if (!scrollTarget && Math.abs(scrollVel) < 1e-4) scrollVel = 0;
  inputAt ||= Date.now();
  frame();
  if (moving) {
    animNext += TICK_MS;
    const now2 = performance.now();
    if (animNext < now2 - TICK_MS) animNext = now2 + TICK_MS; // fell behind: don't try to catch up
    animTimer = setTimeout(tick, Math.max(0, animNext - now2));
  }
}

let settledAt = 0; // when the current zoom settled, while waiting for its tiles
const TILE_WAIT_MS = 400;
let zoomId = 0; // counts zooms, so a snapshot is known to belong to this one
let snapZoom = -1; // the zoom the terminal's snapshot was built for
let snapAsked = -1; // the zoom a snapshot build was started for

/** A zoom starts or goes on. `dir` (the first step's direction) decides the snapshot's shape; without it, wait. */
function beginZoom(dir?: "in" | "out") {
  lastZoomAt = Date.now();
  if (!zoomActive) {
    zoomActive = true;
    zoomId++;
    trace("zoom_start", { id: zoomId });
  }
  if (dir && snapAsked !== zoomId) {
    snapAsked = zoomId;
    const id = zoomId;
    buildSnapshot(dir).then(() => {
      if (snap && snap.gen === st.gen && snapAsked === id) snapZoom = id;
    });
  }
}

function applyZoom(z: number) {
  zoom = Math.max(0.25, Math.min(8, z));
  view = zoomAt(view, fitWidthScale(st.sizes, areaW) * zoom, anchor.x, anchor.y);
  scrollTarget = undefined; // a zoom moves the view itself; a pending scroll would fight it
}

function zoomTo(z: number, x: number, y: number) {
  if (!st.sizes.length) return;
  zoomTarget = Math.max(0.25, Math.min(8, z));
  if (Math.abs(zoomTarget - 1) < 0.01) zoomTarget = 1;
  zoomTargetAt = Date.now();
  anchor = { x, y: Math.min(y, areaH) };
  beginZoom(zoomTarget >= zoom ? "in" : "out");
  zoomAnim = true;
  startAnim();
}

function pinch(phase: string, m: number) {
  if (!st.sizes.length) return;
  if (phase === "began") {
    gesture = true;
    anchor = { ...pointer };
    zoomTarget = zoom;
    beginZoom();
  } else if (phase === "changed") {
    gesture = true;
    beginZoom(m >= 0 ? "in" : "out");
    anchor = { ...pointer };
    applyZoom(zoom * (1 + m));
    zoomTarget = zoom;
    lastZoomAt = Date.now();
    inputAt ||= Date.now();
    requestFrame();
  } else {
    gesture = false;
    lastZoomAt = 0; // render sharp now
    requestFrame();
  }
}

function smartZoom() {
  if (zoom !== 1 || zoomTarget !== 1) {
    lastFit = zoomTarget;
    zoomTo(1, pointer.x, pointer.y);
  } else zoomTo(lastFit > 1.05 ? lastFit : 2, pointer.x, pointer.y);
}

// ---- drawing --------------------------------------------------------------------------------------------------------

function chunked(head: string, b64: string): string {
  const parts: string[] = [];
  for (let i = 0; i < b64.length; i += 4096) {
    const more = i + 4096 < b64.length ? 1 : 0;
    const chunk = b64.slice(i, i + 4096);
    parts.push(i === 0 ? `\x1b_G${head},m=${more};${chunk}\x1b\\` : `\x1b_Gm=${more},q=2;${chunk}\x1b\\`);
  }
  return parts.join("");
}

function transmit(id: number, r: Render): string {
  if (r.file) return `\x1b_Ga=t,f=24,s=${r.w},v=${r.h},o=z,t=f,i=${id},q=2;${btoa(r.file)}\x1b\\`;
  return chunked(`a=t,f=24,s=${r.w},v=${r.h},o=z,t=d,i=${id},q=2`, r.zb64 ?? "");
}

let frameTimer: ReturnType<typeof setTimeout> | undefined;
let lastFrameAt = 0;
let inputAt = 0; // when the input behind the next frame arrived
let clearNext = true;
/** Rows of text to erase in the next frame (the status lines' old rows after a resize). */
let wipeRows: number[] = [];
let lastMode = "none";
let lastTraceTop = 0;

function requestFrame() {
  if (frameTimer !== undefined) return;
  frameTimer = setTimeout(() => {
    frameTimer = undefined;
    frame();
  }, Math.max(0, lastFrameAt + Math.min(8, TICK_MS) - Date.now()));
}

interface Mark {
  page: number;
  y: number;
  h: number;
  at: number;
}
let mark: Mark | undefined;
const MARK_MS = 1400;
let markPlaced = false, markAlpha = -1;

function frame() {
  if (frameTimer !== undefined) {
    clearTimeout(frameTimer);
    frameTimer = undefined;
  }
  const t0 = performance.now();
  lastFrameAt = Date.now();
  if (![view.areaW, view.areaH, view.scale, view.left, view.top].every(Number.isFinite)) {
    // A bad size (a resize mid-query, a zero-sized pane) must not leave the pane blank for good.
    logError("frame", `view not finite: ${JSON.stringify(view)}`);
    view = { areaW: areaW || 1, areaH: areaH || 1, scale: 1, left: 0, top: 0 };
    setScaleFromZoom();
  }
  let buf = "\x1b[?2026h";
  // A clear wipes images too, so it waits for a frame that draws something (see "hold" below).
  const beforeClear = clearNext ? { placed, markPlaced, snapPlaced, placedTiles } : undefined;
  if (clearNext) {
    buf += "\x1b[H\x1b[2J";
    placed = new Set();
    markPlaced = false;
    snapPlaced = false;
    clearNext = false;
    placedTiles = new Set();
  }
  // before any image is placed, so that if erasing text takes images on those rows with it, they come back at once
  const wiping = wipeRows;
  const wipe = wiping.filter((r) => r >= 1 && r <= rows).map((r) => `\x1b[${r};1H\x1b[2K`).join("");
  buf += wipe;
  wipeRows = [];
  let pieces: Piece[] = [];
  let transmits = 0, missing = 0;
  let mode = "none";
  if (calibrating) {
    // bench calibration: nothing on screen but the markers (placements go, images stay; the next frame re-places)
    // by id: Rex doesn't act on d=a here
    for (const p of placed) buf += `\x1b_Ga=d,d=i,i=${IMG + p},p=1,q=2\x1b\\`;
    for (const id of placedTiles) buf += `\x1b_Ga=d,d=i,i=${id},p=1,q=2\x1b\\`;
    for (const id of SNAP) buf += `\x1b_Ga=d,d=i,i=${id},p=1,q=2\x1b\\`;
    buf += `\x1b_Ga=d,d=i,i=${MARK},p=1,q=2\x1b\\\x1b[H\x1b[2J` + calibrationMarkers() + "\x1b[?2026l";
    clearNext = true; // redraw text and images after
    placed = new Set();
    placedTiles = new Set();
    snapPlaced = false;
    markPlaced = false;
    out(buf);
    return;
  }
  if (st.pdf && areaW && st.sizes.length) {
    view = clampView({ ...view, areaW, areaH }, st.sizes);
    pieces = visiblePieces(view, st.sizes);
    txpGoal(pieces);
    const vis = new Set(pieces.map((p) => p.page));
    // what is kept: two pages either side of the view, and whatever the prefetch ring covers (it renders those; if
    // they were dropped here it would render them again forever)
    const ring = new Set(idlePieces().map((pc) => pc.page));
    const near = (p: number) => ring.has(p) || pieces.some((pc) => Math.abs(pc.page - p) <= 2);
    for (const [page, r] of ready) {
      ready.delete(page);
      if (!near(page) || page >= st.sizes.length) continue;
      buf += transmit(IMG + page, r);
      transmits++;
      shown.set(page, r);
      if (vis.has(page) && pendingChange && r.gen === st.gen) {
        trace("drawn", { page: page + 1, since_change: Date.now() - pendingChange });
        pendingChange = 0;
      }
    }
    // the snapshot stays until the gesture has settled and every visible page has a sharp image for this view
    // (tiled pages: their underlay, and the tiles in view unless that takes longer than TILE_WAIT_MS)
    if (zoomActive && settled()) {
      settledAt ||= Date.now();
      const tilesIn = (pc: Piece) => {
        if (!tiled(pc.page)) return true;
        const r = tileRange(pc, 0);
        for (let ty = r.ty0; ty <= r.ty1; ty++) {
          for (let tx = r.tx0; tx <= r.tx1; tx++) if (!tiles.has(tileKey(pc.page, tx, ty))) return false;
        }
        return true;
      };
      const late = Date.now() - settledAt > TILE_WAIT_MS;
      if (pieces.every((pc) => goodBase(shown.get(pc.page), pc.page) && (late || tilesIn(pc)))) {
        zoomActive = false;
        settledAt = 0;
      } else if (!late) setTimeout(requestFrame, 40);
    } else settledAt = 0;
    const useSnap = zoomActive && snap !== undefined && snap.gen === st.gen && snapZoom === zoomId;
    if (useSnap && !snapCovers(snap) && !snapBuilding && Date.now() - lastSnapBuild > 150 && snap!.dir === "out") {
      const id = zoomId;
      buildSnapshot("out").then(() => {
        if (snapAsked === id && zoomId === id) snapZoom = id;
      });
    }
    if (zoomActive && !useSnap) {
      // this zoom's snapshot isn't in the terminal yet (a frame or two): leave the screen as it is
      mode = "hold";
      if (wipe) {
        buf = buf.replace(wipe, "");
        wipeRows = wiping;
      }
      if (beforeClear) {
        // keep what's on screen: no clear this frame, the next one that draws clears and draws at once
        buf = buf.replace("\x1b[H\x1b[2J", "");
        ({ placed, markPlaced, snapPlaced, placedTiles } = beforeClear);
        clearNext = true;
      }
    } else if (useSnap) {
      mode = "snapshot";
      const pl = placeSnapshot(view, snap!, cellW, cellH, cols, Math.max(1, rows - 2));
      if (pl) {
        buf += `\x1b[${pl.row + 1};${pl.col + 1}H\x1b_Ga=p,i=${SNAP[snap!.slot]},p=1,x=${pl.x},y=${pl.y},w=${pl.w},` +
          `h=${pl.h},X=${pl.X},Y=${pl.Y},c=${pl.c},r=${pl.r},z=-2,C=1,q=2\x1b\\`;
        snapPlaced = true;
        if (fadingSnap === snap!.slot) fadingSnap = undefined; // re-placed: not stale any more
        if (pendingSnapDelete !== undefined) {
          buf += `\x1b_Ga=d,d=I,i=${SNAP[pendingSnapDelete]},q=2\x1b\\`;
          pendingSnapDelete = undefined;
        }
      }
      for (const p of placed) buf += `\x1b_Ga=d,d=i,i=${IMG + p},p=1,q=2\x1b\\`;
      placed = new Set();
      for (const id of placedTiles) buf += `\x1b_Ga=d,d=i,i=${id},p=1,q=2\x1b\\`;
      placedTiles = new Set();
    } else {
      mode = "pages";
      const now = new Set<number>();
      for (const pc of pieces) {
        const r = shown.get(pc.page);
        if (!r) {
          missing++;
          continue;
        }
        const pl = placePiece(pc, view.scale, r, cellW, cellH);
        if (!pl) continue;
        buf += `\x1b[${pl.row + 1};${pl.col + 1}H\x1b_Ga=p,i=${IMG + pc.page},p=1,x=${pl.x},y=${pl.y},w=${pl.w},` +
          `h=${pl.h},X=${pl.X},Y=${pl.Y}${pl.c ? `,c=${pl.c},r=${pl.r}` : ""},z=${tiled(pc.page) ? -1 : 0},C=1,q=2\x1b\\`;
        now.add(pc.page);
      }
      for (const p of placed) if (!now.has(p)) buf += `\x1b_Ga=d,d=i,i=${IMG + p},p=1,q=2\x1b\\`;
      placed = now;
      // tiles over the underlays of zoomed-in pages
      buf += drawTiles(pieces);
      transmits += tilesSentThisFrame;
      // the snapshot stays under the pages (z=-2) for a moment, in case the terminal shows a frame before the
      // pages are decoded, then goes (tens of MB in the terminal otherwise)
      if (snapPlaced && snap) {
        fadingSnap = snap.slot;
        fadingSnapAt = Date.now();
        setTimeout(requestFrame, SNAP_LINGER_MS + 10);
        if (pendingSnapDelete !== undefined) buf += `\x1b_Ga=d,d=I,i=${SNAP[pendingSnapDelete]},q=2\x1b\\`;
        snap = undefined;
        pendingSnapDelete = undefined;
      }
      snapPlaced = false;
    }
    if (fadingSnap !== undefined && mode === "pages" && Date.now() - fadingSnapAt >= SNAP_LINGER_MS) {
      buf += `\x1b_Ga=d,d=I,i=${SNAP[fadingSnap]},q=2\x1b\\`;
      fadingSnap = undefined;
    }
    // free pages far from the view
    for (const p of shown.keys()) {
      if (!near(p) || p >= st.sizes.length) {
        buf += `\x1b_Ga=d,d=I,i=${IMG + p},q=2\x1b\\`;
        shown.delete(p);
      }
    }
    for (const p of hi.keys()) if (!near(p)) hi.delete(p);
    buf += drawMark();
  } else if (!st.pdf) {
    buf += `\x1b[1;1H\x1b[2K\x1b[2m${fit(`taudot preview · ${mainFile} · ${folder}`, cols)}\x1b[22m`;
  }
  buf += statusLines(pieces);
  buf += "\x1b[?2026l";
  const bytes = out(buf);
  if (da1Trace && (inputAt || transmits)) da1(`frame:${mode}${transmits ? "+tx" : ""}`, bytes);
  if (mode !== lastMode) {
    trace("mode", { from: lastMode, to: mode, transmits, missing, bytes });
    lastMode = mode;
  }
  const ms = performance.now() - t0;
  const prevTop = lastTraceTop;
  lastTraceTop = view.top;
  if (inputAt) {
    const dpx = +((view.top - prevTop) * view.scale).toFixed(1);
    trace("frame", { mode, ms: +ms.toFixed(2), bytes, transmits, missing, tmiss: mode === "pages" ? tilesMissingThisFrame : 0, dpx, since_input: Date.now() - inputAt });
    inputAt = 0;
  }
  scheduleRenders(pieces);
}

/** The forward-search mark: a translucent band in the accent colour over the line, fading out. */
function drawMark(): string {
  let s = "";
  const age = mark ? Date.now() - mark.at : Infinity;
  if (!mark || age > MARK_MS || mark.page >= st.sizes.length) {
    if (markPlaced) s += `\x1b_Ga=d,d=i,i=${MARK},p=1,q=2\x1b\\`;
    markPlaced = false;
    mark = undefined;
    return s;
  }
  const alpha = Math.round(110 * (age < MARK_MS / 2 ? 1 : 1 - (age - MARK_MS / 2) / (MARK_MS / 2)));
  const step = Math.round(alpha / 16) * 16;
  if (step !== markAlpha || !markPlaced) {
    const px = new Uint8Array([accent[0], accent[1], accent[2], step]);
    s += `\x1b_Ga=t,f=32,s=1,v=1,i=${MARK},q=2;${btoa(String.fromCharCode(...px))}\x1b\\`;
    markAlpha = step;
  }
  const tops = pageTops(st.sizes), dw = docWidth(st.sizes);
  const [pw] = st.sizes[mark.page];
  const x0 = ((dw - pw) / 2 - view.left) * view.scale, y0 = (tops[mark.page] + mark.y - view.top) * view.scale;
  const x1 = x0 + pw * view.scale, y1 = y0 + mark.h * view.scale;
  const col = Math.max(0, Math.floor(x0 / cellW)), row = Math.max(0, Math.floor(y0 / cellH));
  const c = Math.min(cols, Math.ceil(x1 / cellW)) - col;
  const r = Math.min(Math.max(1, rows - 2), Math.ceil(y1 / cellH)) - row;
  if (c < 1 || r < 1) {
    if (markPlaced) s += `\x1b_Ga=d,d=i,i=${MARK},p=1,q=2\x1b\\`;
    markPlaced = false;
  } else {
    s += `\x1b[${row + 1};${col + 1}H\x1b_Ga=p,i=${MARK},p=1,c=${c},r=${r},z=2,C=1,q=2\x1b\\`;
    markPlaced = true;
  }
  setTimeout(requestFrame, 60);
  return s;
}

function statusLines(pieces: Piece[]): string {
  if (rows < 3) return "";
  let s = `\x1b[${rows - 1};1H\x1b[2K`;
  if (st.compile === "error" && st.error) s += `\x1b[31m${fit(st.error, cols)}\x1b[39m`;
  else if (st.note && Date.now() < st.noteUntil) s += `\x1b[2m${fit(st.note, cols)}\x1b[22m`;
  s += `\x1b[${rows};1H\x1b[2K`;
  const n = st.sizes.length;
  const page = n && pieces.length ? `${currentPage(view, st.sizes) + 1}/${n}` : "-/-";
  const z = Math.abs(zoom - 1) < 0.005 ? "width" : `${Math.round(zoom * 100)}%`;
  const state = {
    waiting: "\x1b[2mwaiting\x1b[22m",
    compiling: "\x1b[33mcompiling\x1b[39m",
    ok: "\x1b[32mok\x1b[39m",
    error: "\x1b[31merror\x1b[39m",
  }[st.compile];
  const time = st.compileMs ? `${(st.compileMs / 1000).toFixed(1)}s` : "";
  const nv = [...conns.values()].includes("nvim") ? "nvim " : "";
  const left = ` ${page}  ${z}  `;
  const right = `${nv}${mainFile}  ${time} `;
  const gap = Math.max(1, cols - left.length - st.compile.length - right.length);
  return s + `\x1b[1m${left}\x1b[22m${state}\x1b[2m${" ".repeat(gap)}${right}\x1b[22m`;
}

// ---- moving around --------------------------------------------------------------------------------------------------

function act(a: Action) {
  const tops = pageTops(st.sizes);
  const cur = st.sizes.length ? currentPage(view, st.sizes) : 0;
  switch (a.kind) {
    case "page": {
      const last = Math.max(0, st.sizes.length - 1);
      const from = scrollTarget?.top ?? view.top;
      const at = st.sizes.length ? currentPage({ ...view, top: from }, st.sizes) : 0;
      let top = 0;
      if (a.to === "last") top = tops[last] ?? 0;
      else if (a.to === "next") top = tops[Math.min(last, at + 1)] ?? 0;
      else if (a.to === "prev") top = from > (tops[at] ?? 0) + 1 ? tops[at] : tops[Math.max(0, at - 1)] ?? 0;
      scrollTo(scrollTarget?.left ?? view.left, top);
      return;
    }
    case "scroll":
      scrollBy(a.dx * areaW, a.dy * areaH);
      return;
    case "zoom":
      if (a.to === "in") zoomTo(zoomTarget * 1.25, areaW / 2, areaH / 2);
      else if (a.to === "out") zoomTo(zoomTarget / 1.25, areaW / 2, areaH / 2);
      else if (a.to === "width") zoomTo(1, areaW / 2, areaH / 2);
      else if (st.sizes.length) {
        // fit page: jump, then settle like any zoom
        beginZoom("out");
        anchor = { x: areaW / 2, y: 0 };
        applyZoom(fitPageScale(st.sizes, cur, areaW, areaH) / fitWidthScale(st.sizes, areaW));
        zoomTarget = zoom;
        view.top = tops[cur];
      }
      break;
    case "recompile":
      if (txp) txp.open(mainFile, Deno.readTextFileSync(join(folder, mainFile)));
      else schedule("key r");
      return;
    case "quit":
      quit(0);
  }
  requestFrame();
}

// mouse ---------------------------------------------------------------------------------------------------------------

let lastPress = { t: 0, x: 0, y: 0 };
let drag: { x: number; y: number; left: number; top: number; moved: boolean } | undefined;
const mouseSeen = new Set<string>();
let pointer = { x: 0, y: 0 }; // last known pointer position in the pane, pixels
let lastHoverSent = 0;

function onMouse(m: Mouse) {
  const px = pixelMouse ? m.x - 1 : (m.x - 1) * cellW + cellW / 2;
  const py = pixelMouse ? m.y - 1 : (m.y - 1) * cellH + cellH / 2;
  pointer = { x: px, y: py };
  // log each kind of event once, to learn what the terminal sends
  const kind = `${m.wheel ?? "b" + m.button}${m.ctrl ? "+ctrl" : ""}${m.alt ? "+alt" : ""}${m.shift ? "+shift" : ""}` +
    `${m.motion ? " motion" : ""}${m.release ? " release" : ""}`;
  if (!mouseSeen.has(kind)) {
    mouseSeen.add(kind);
    trace("mouse_kind", { kind, x: m.x, y: m.y, pixel: pixelMouse });
  }
  const now = Date.now();
  if (m.motion) sendHover(now);
  if (m.wheel) {
    if (!st.sizes.length) return;
    if (m.ctrl || m.alt) {
      // a notch of a mouse wheel arrives as several events; trackpads send one per line of travel
      const f = m.wheel === "up" ? 1.06 : m.wheel === "down" ? 1 / 1.06 : 1;
      if (f !== 1) zoomTo(zoomTarget * f, px, py);
      return;
    }
    // Ghostty sends one event per line of trackpad travel (momentum included) and a burst of a few per mouse notch.
    // Isolated events are notches: bigger steps. A fast stream gets slightly smaller steps; easing blends them.
    const gap = now - lastWheelAt;
    lastWheelAt = now;
    const line = Math.max(cellH, 12);
    const step = gap > 80 ? line * 2 : gap < 3 ? line : gap < 12 ? line * 0.8 : line;
    if (m.wheel === "left" || m.wheel === "right" || m.shift) {
      scrollBy((m.wheel === "left" || m.wheel === "up" ? -1 : 1) * step, 0);
    } else {
      scrollBy(0, (m.wheel === "up" ? -1 : 1) * step);
    }
    lastScrollAt = now;
    inputAt ||= now;
    return;
  }
  if (m.button === 0 && !m.motion && !m.release) {
    if (py >= areaH) return;
    const dbl = now - lastPress.t < 400 && Math.hypot(px - lastPress.x, py - lastPress.y) < 10;
    lastPress = { t: dbl ? 0 : now, x: px, y: py };
    drag = { x: px, y: py, left: view.left, top: view.top, moved: false };
    if (dbl) {
      drag = undefined;
      inverseSearch(px, py);
    }
    return;
  }
  if (m.motion && m.button === 0 && drag) {
    if (Math.hypot(px - drag.x, py - drag.y) > 3) drag.moved = true;
    if (!drag.moved) return;
    scrollTarget = undefined; // the pointer leads
    view.left = drag.left - (px - drag.x) / view.scale;
    view.top = drag.top - (py - drag.y) / view.scale;
    lastScrollAt = now;
    inputAt ||= now;
    requestFrame();
    return;
  }
  if (m.release) drag = undefined;
}

/** Tells the pinch helpers where the pointer is in this pane, so they can find the pane on screen. */
function sendHover(now: number) {
  if (now - lastHoverSent < 30) return;
  const helpers = [...conns].filter(([, k]) => k === "pinch");
  if (!helpers.length) return;
  lastHoverSent = now;
  const msg = enc.encode(
    JSON.stringify({ hover: { x: pointer.x, y: pointer.y, pw: cols * cellW, ph: rows * cellH } }) + "\n",
  );
  for (const [c] of helpers) c.write(msg).catch(() => conns.delete(c));
}

// ---- SyncTeX, Neovim and the pinch helper ---------------------------------------------------------------------------
//
// Clients connect to --listen and send one JSON object per line.
// Neovim (clients/nvim, lua/taudot/preview.lua):
//   {"cursor": {"path": "/abs/main.tex", "line": 12}}      when its cursor rests on a new line
//   and gets {"jump": {"path": "/abs/main.tex", "line": 12}} on a double-click in the PDF.
// The pinch helper (clients/rex/pinch) says {"hello": "pinch"}, gets {"hover": {x, y, pw, ph}} as the pointer moves
// over the pane, and sends {"pinch": {"phase": "began|changed|ended|cancelled", "m": magnification}} and
// {"smartzoom": {}}.

const conns = new Map<Deno.Conn, "nvim" | "pinch">();

function inverseSearch(px: number, py: number) {
  const t0 = Date.now();
  const p = pointToPage(view, st.sizes, px, py);
  if (!p) return;
  if (!st.synctex) return note("no SyncTeX data for this PDF");
  const hit = inverse(st.synctex, p.page, p.x, p.y);
  if (!hit) return note("nothing to jump to here");
  const path = hit.file.startsWith("/") ? hit.file : resolve(folder, hit.file);
  const rel = path.startsWith(folder + "/") ? path.slice(folder.length + 1) : path;
  // flash the line that was hit
  const f = forward(st.synctex, path, hit.line);
  if (f) mark = { page: f.page, y: f.y, h: f.h, at: Date.now() };
  requestFrame();
  const nvims = [...conns].filter(([, k]) => k === "nvim");
  if (nvims.length === 0) return note(`${rel}:${hit.line} (no Neovim connected)`);
  const msg = enc.encode(JSON.stringify({ jump: { path, line: hit.line } }) + "\n");
  for (const [c] of nvims) c.write(msg).catch(() => conns.delete(c));
  if (editorBlock) {
    const a = rexSession ? ["focus", "-s", rexSession, editorBlock] : ["focus", editorBlock];
    new Deno.Command("rex", { args: a, stdout: "null", stderr: "null" }).output().catch(() => {});
  }
  trace("inverse", { page: p.page + 1, line: hit.line, path: rel, ms: Date.now() - t0 });
}

function forwardSearch(path: string, line: number) {
  if (!st.synctex || !st.sizes.length) return;
  const f = forward(st.synctex, path, line);
  if (!f) return;
  const tops = pageTops(st.sizes);
  const y = tops[f.page] + f.y, viewH = areaH / view.scale;
  // follow only when the line is out of view, and not while the user is scrolling or zooming the PDF
  const busyHand = Date.now() - lastScrollAt < 1000 || drag || zoomActive;
  if (!busyHand && (y < view.top + viewH * 0.08 || y + f.h > view.top + viewH * 0.92)) {
    scrollTo(view.left, y - viewH / 3);
  }
  mark = { page: f.page, y: f.y, h: f.h, at: Date.now() };
  trace("forward", { page: f.page + 1, line });
  requestFrame();
}

function onMessage(conn: Deno.Conn, m: Record<string, any>) {
  if (m.hello === "pinch") {
    conns.set(conn, "pinch");
    requestFrame();
  } else if (m.cursor?.path && m.cursor?.line) forwardSearch(m.cursor.path, m.cursor.line);
  else if (m.pinch) {
    trace("pinch", { phase: m.pinch.phase, m: m.pinch.m });
    pinch(String(m.pinch.phase), Number(m.pinch.m) || 0);
  } else if (m.smartzoom) smartZoom();
  else if (typeof m.input === "string") handleInput(m.input);
  else if (typeof m.calibrate === "boolean") calibrate(m.calibrate);
}

async function serveClients(path: string) {
  await Deno.remove(path).catch(() => {});
  let listener: Deno.Listener;
  try {
    listener = Deno.listen({ transport: "unix", path });
  } catch (e) {
    note(`cannot listen on ${path}: ${(e as Error).message}`);
    return;
  }
  for await (const conn of listener) {
    conns.set(conn, "nvim");
    requestFrame();
    (async () => {
      let buf = "";
      try {
        for await (const chunk of conn.readable) {
          buf += dec.decode(chunk, { stream: true });
          let nl;
          while ((nl = buf.indexOf("\n")) >= 0) {
            const line = buf.slice(0, nl);
            buf = buf.slice(nl + 1);
            try {
              onMessage(conn, JSON.parse(line));
            } catch { /* not JSON */ }
          }
        }
      } catch { /* closed */ }
      conns.delete(conn);
      requestFrame();
    })();
  }
}

// ---- input and terminal replies -------------------------------------------------------------------------------------

const da1Queue: { tag: string; t: number; bytes: number }[] = [];
function da1(tag: string, bytes = 0) {
  da1Queue.push({ tag, t: performance.now(), bytes });
  out("\x1b[c");
}

let gotSize: (() => void) | undefined;
let gotProbe: (() => void) | undefined;
function onReply(r: string) {
  if (/^\x1b\[\?[\d;]*c$/.test(r)) {
    const q = da1Queue.shift();
    if (q) trace("da1", { tag: q.tag, ms: +(performance.now() - q.t).toFixed(2), bytes: q.bytes });
    return;
  }
  const s = parseSizeReply(r);
  if (s.cell) [cellW, cellH] = s.cell;
  if (s.area && !cellW) {
    cellW = Math.floor(s.area[0] / cols);
    cellH = Math.floor(s.area[1] / rows);
  }
  if (s.cell || s.area) gotSize?.();
  const mode = parseModeReply(r);
  if (mode?.mode === 1016) pixelMouse = mode.value === 1 || mode.value === 3;
  const colour = parseColourReply(r);
  if (colour?.which === 12) accent = colour.rgb;
  if (r.startsWith("\x1b_Gi=31;")) {
    fileTransfer = r.includes(";OK");
    gotProbe?.();
  }
}

async function querySize() {
  readSize();
  // Keep the old cell size until the terminal answers: a frame drawn meanwhile must never see 0.
  const got = new Promise<void>((r) => (gotSize = r));
  out("\x1b[16t\x1b[14t");
  await Promise.race([got, new Promise((r) => setTimeout(r, 500))]);
  gotSize = undefined;
  if (!cellW || !cellH) [cellW, cellH] = [8, 16]; // no reply: a guess
  areaW = cols * cellW;
  areaH = Math.max(1, rows - 2) * cellH;
  trace("size", { cols, rows, cellW, cellH, areaW, areaH });
}

/** Asks whether the terminal can read PNGs from files (t=f), which saves base64 over the pty. */
async function probeFileTransfer() {
  const probe = join(outDir, "probe.png");
  const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
  await Deno.writeFile(probe, Uint8Array.from(atob(png), (c) => c.charCodeAt(0)));
  const got = new Promise<void>((r) => (gotProbe = r));
  out(`\x1b_Gi=31,a=q,t=f,f=100;${btoa(probe)}\x1b\\\x1b[?1016$p\x1b]12;?\x1b\\`);
  await Promise.race([got, new Promise((r) => setTimeout(r, 500))]);
  gotProbe = undefined;
  trace("caps", { fileTransfer, pixelMouse, accent });
}

const keys = new Keys();
async function readInput() {
  if (!isTTY) return;
  const buf = new Uint8Array(65536);
  while (true) {
    const n = await Deno.stdin.read(buf);
    if (n === null) return;
    handleInput(dec.decode(buf.subarray(0, n)));
  }
}

/** Terminal input, from stdin or injected over the socket by the bench (`{"input": "..."}`). */
function handleInput(s: string) {
  const { keys: k, mouse, replies } = splitInput(s);
  replies.forEach(onReply);
  mouse.forEach(onMouse);
  const acts = keys.feed(k);
  if (acts.length) inputAt ||= Date.now();
  for (const a of acts) act(a);
}

/** Bench calibration: magenta squares on the first and the last cell of the page area, so a screenshot finds it. */
const CAL = 7_509_980;
let calibrating = false;
let calDrawn = 0;
function calibrate(on: boolean) {
  calibrating = on;
  calDrawn = 0;
  if (!on) {
    out(`\x1b_Ga=d,d=I,i=${CAL},q=2\x1b\\`);
    requestFrame();
    return;
  }
  trace("calibrate", { cols, rows: Math.max(1, rows - 2), cellW, cellH });
  requestFrame();
}
/** While calibrating, every frame (re)draws the markers, so a clear or redraw can't wipe them. */
function calibrationMarkers(): string {
  if (!calibrating) return "";
  if (calDrawn++ === 0) trace("cal_drawn", { rows, cols });
  const px = btoa(String.fromCharCode(255, 0, 255, 255));
  const areaRows = Math.max(1, rows - 2);
  return `\x1b_Ga=t,f=32,s=1,v=1,i=${CAL},q=2;${px}\x1b\\` +
    `\x1b[1;1H\x1b_Ga=p,i=${CAL},p=1,c=1,r=1,z=9,C=1,q=2\x1b\\` +
    `\x1b[${areaRows};${cols}H\x1b_Ga=p,i=${CAL},p=2,c=1,r=1,z=9,C=1,q=2\x1b\\`;
}

function quit(code: number) {
  out("\x1b[?1016l\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b_Ga=d,d=A,q=2\x1b\\\x1b[?25h\x1b[?1049l");
  if (isTTY) Deno.stdin.setRaw(false);
  txp?.kill();
  if (child) {
    try {
      child.kill("SIGKILL");
    } catch { /* gone */ }
  }
  if (listenPath) {
    try {
      Deno.removeSync(listenPath);
    } catch { /* gone */ }
  }
  Deno.exit(code);
}

// ---- --engine texpresso ---------------------------------------------------------------------------------------------
//
// txp-headless keeps the document typeset and rolls back to just before each edit. Edits come from the taudot engine
// (doc.changed, byte offsets) when it serves this folder, else from file saves (the whole file; TeXpresso diffs it).
// A "pages" event lists the pages whose drawing changed: only those are rendered again; every other page keeps its
// images and tiles (they are re-tagged to the new generation instead of being dropped).

let txpStarted = 0;
let txpChanged: Set<number> | undefined; // pages the last TeXpresso report changed
const staleTiles = new Map<string, Tile>(); // "page:scale:tx:ty" -> a changed page's old tile, still on screen
const liveDocs = new Set<string>(); // paths fed by the engine: their file saves are ignored

function carryOver(gen: number, changed: Set<number>, n: number) {
  const keep = (p: number, g: number) => g === gen - 1 && p < n && !changed.has(p);
  for (const m of [shown, ready, hi]) {
    for (const [p, r] of m) if (keep(p, r.gen)) r.gen = gen;
  }
  for (const [key, t] of [...tiles]) {
    if (t.gen === gen - 1 && t.sent && !keep(t.page, t.gen)) {
      // a changed page: its old tile stays on screen until the new one (same image id) replaces it
      tiles.delete(key);
      staleTiles.set(`${t.page}:${key.split(":").slice(2).join(":")}`, t);
      continue;
    }
    if (!keep(t.page, t.gen)) continue;
    tiles.delete(key);
    t.gen = gen;
    t.key = `${gen}:${key.slice(key.indexOf(":") + 1)}`;
    tiles.set(t.key, t);
  }
  if (snap && snap.gen === gen - 1 && changed.size === 0) snap.gen = gen;
}

async function onTxpPages(e: PagesEvent) {
  const gen = st.gen + 1;
  const first = !st.pdf;
  carryOver(gen, new Set(e.changed), e.n);
  const editMs = e.edit_us >= 0 ? e.edit_us / 1000 : Date.now() - txpStarted;
  Object.assign(st, { gen, pdf: "texpresso", sizes: e.sizes, compile: e.done ? "ok" : "compiling", error: "", compileMs: editMs });
  trace("compile_end", { ok: true, engine: "texpresso", gen, done: e.done, changed: e.changed.length, ms: editMs, step_ms: e.step_us / 1000, report_ms: e.report_us / 1000 });
  if (e.changed.length) {
    pendingChange = Date.now() - editMs;
    txpChanged = new Set(e.changed);
  }
  if (first) view.top = 0;
  setScaleFromZoom();
  status(e.done ? "idle" : "working", `${e.n} page${e.n === 1 ? "" : "s"}, ${e.done ? "typeset" : "page in view"} in ${Math.round(editMs)} ms`);
  requestFrame();
  if (e.done) {
    const path = join(outDir, "texpresso.synctex");
    const r = await txp!.synctex(path);
    if (r.ok && st.gen === gen) st.synctex = parseSyncTex(await Deno.readTextFile(path).catch(() => ""));
  }
}

/** Tell TeXpresso the last page in view, so it reports as soon as that much is typeset again. */
function txpGoal(pieces: Piece[]) {
  if (!txp || !pieces.length) return;
  txp.goal(pieces[pieces.length - 1].page);
}

/** Feed the engine's live edits of every .tex doc of this folder's project; resolves when the connection ends. */
async function feedFromEngine(socket: string) {
  const conn = await Deno.connect({ transport: "unix", path: socket });
  let id = 0, buf = "";
  const waiting = new Map<number, (m: { result?: any; error?: any }) => void>();
  const call = (method: string, params: unknown = {}) =>
    new Promise<any>((res, rej) => {
      const i = ++id;
      waiting.set(i, (m) => (m.error ? rej(new Error(m.error.message)) : res(m.result)));
      conn.write(enc.encode(JSON.stringify({ jsonrpc: "2.0", id: i, method, params }) + "\n"));
    });
  const paths = new Map<string, string>(); // doc_id -> path
  const reopen = async () => {
    for (const [docId, path] of paths) {
      const d = await call("doc.open", { project_id: projectId, path });
      await txp!.open(path, d.text);
      await call("doc.subscribe", { doc_id: docId, since_seq: d.seq });
    }
  };
  txpReopen = reopen;
  let projectId = "";
  const reader = (async () => {
    for await (const chunk of conn.readable) {
      buf += dec.decode(chunk, { stream: true });
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const m = JSON.parse(buf.slice(0, nl));
        buf = buf.slice(nl + 1);
        if (m.id !== undefined) {
          waiting.get(m.id)?.(m);
          waiting.delete(m.id);
        } else if (m.method === "doc.changed") {
          const path = paths.get(m.params.doc_id);
          if (!path) continue;
          trace("change", { reason: "engine", path, edits: m.params.edits.length });
          for (const ed of m.params.edits) txp!.change(path, ed.pos, ed.del, ed.ins);
        } else if (m.method === "engine.lagged") reopen();
      }
    }
  })();
  const p = await call("project.open", { folder });
  projectId = p.project_id;
  for (const d of p.docs as { doc_id: string; path: string }[]) {
    if (!d.path.endsWith(".tex")) continue;
    paths.set(d.doc_id, d.path);
    liveDocs.add(d.path);
  }
  await reopen();
  note(`texpresso: live edits from the engine (${paths.size} docs)`);
  await reader;
}

/** Errors that would otherwise vanish, with a timestamp, in OUT/errors.log (kept small: the last 200 KB). */
function logError(where: string, err: unknown) {
  const line = `${new Date().toISOString()} ${where}: ${err instanceof Error ? err.stack ?? err.message : String(err)}\n`;
  trace("error", { where, message: String(err) });
  try {
    const p = join(outDir, "errors.log");
    const s = Deno.statSync(p);
    if (s.size > 200_000) Deno.removeSync(p);
  } catch { /* none yet */ }
  try {
    Deno.writeTextFileSync(join(outDir, "errors.log"), line, { append: true });
  } catch { /* out dir gone */ }
}

let txpReopen: (() => Promise<void>) | undefined; // re-sends the engine's docs to a new TeXpresso
let txpRestarts = 0;

/** Start TeXpresso. If it exits, or shows no page within 10 s (it can hang at start), start it again. */
function spawnTxp() {
  txpStarted = Date.now();
  let gotPages = false;
  const me = new Txp(
    join(folder, mainFile),
    (e) => {
      gotPages = true;
      if (txp === me) onTxpPages(e).catch((err) => logError("onTxpPages", err));
    },
    join(outDir, "texpresso.stderr"),
  );
  txp = me;
  const restart = (why: string) => {
    if (txp !== me) return;
    me.kill();
    txpRestarts++;
    logError("texpresso", why);
    note(`texpresso: ${why}, restarting`);
    setTimeout(() => {
      if (txp !== me) return;
      spawnTxp();
      txpReopen?.().catch((err) => logError("txpReopen", err));
    }, Math.min(500 * 2 ** Math.min(txpRestarts - 1, 4), 8000));
  };
  me.exited.then((s) => restart(`exited (${s.signal ?? s.code})`));
  setTimeout(() => {
    if (!gotPages) restart("no page after 10 s");
  }, 10_000);
}

async function startTexpresso() {
  // render files no image or tile refers to any more, older than a minute
  setInterval(async () => {
    const used = new Set<string>();
    for (const m of [shown, ready, hi]) for (const r of m.values()) if (r.file) used.add(r.file);
    for (const t of tiles.values()) if (t.file) used.add(t.file);
    for await (const e of Deno.readDir(pagesDir)) {
      const f = join(pagesDir, e.name);
      if (used.has(f)) continue;
      const s = await Deno.stat(f).catch(() => undefined);
      if (s?.mtime && Date.now() - s.mtime.getTime() > 60_000) Deno.remove(f).catch(() => {});
    }
  }, 30_000);
  spawnTxp();
  st.compile = "compiling";
  status("working", "texpresso: first run");
  const sock = args["taudot-socket"] ?? Deno.env.get("TAUDOT_SOCKET");
  if (sock) {
    (async () => {
      for (;;) {
        try {
          await feedFromEngine(sock);
        } catch (err) {
          logError("feedFromEngine", err); // no engine (yet), or it went away
        }
        liveDocs.clear();
        await new Promise((r) => setTimeout(r, 2000));
      }
    })();
  }
}

/** A file saved on disk: TeXpresso gets its whole text unless the engine already feeds it live. */
async function txpFileChanged(rel: string) {
  if (!txp || liveDocs.has(rel) || !rel.endsWith(".tex")) return;
  const text = await Deno.readTextFile(join(folder, rel)).catch(() => undefined);
  if (text === undefined) return;
  trace("change", { reason: "file", path: rel });
  txp.open(rel, text);
}

// ---- main -----------------------------------------------------------------------------------------------------------

readInput();
await querySize();
await probeFileTransfer();
Deno.addSignalListener("SIGINT", () => quit(0));
Deno.addSignalListener("SIGTERM", () => quit(0));
Deno.addSignalListener("SIGHUP", () => quit(0));
// Dragging a pane edge sends a burst of SIGWINCH: one size query at a time, and one more if more came meanwhile.
let sizing = false, resizeAgain = false;
Deno.addSignalListener("SIGWINCH", async () => {
  if (sizing) {
    resizeAgain = true;
    return;
  }
  sizing = true;
  const oldRows = rows;
  do {
    resizeAgain = false;
    await querySize();
  } while (resizeAgain);
  sizing = false;
  setScaleFromZoom();
  beginZoom("out"); // the snapshot (in document space) covers the change until sharp pages arrive
  // No full clear (it would take the images with it, a visible flash): images are placed again every frame, and the
  // only text is the two status lines, so only their old rows are erased.
  wipeRows.push(oldRows - 1, oldRows);
  requestFrame();
});
if (listenPath) serveClients(listenPath);
note("zoom: Ctrl+scroll (or Option+scroll, + -), double-click jumps to the source");

requestFrame();
if (ENGINE === "texpresso") await startTexpresso();
else schedule("start");

const outInside = outDir.startsWith(folder + "/");
// events carry real paths (macOS: /private/var/... for /var/...), so paths are made relative to the real folder
const realFolder = Deno.realPathSync(folder);
const relPath = (p: string) => p.startsWith(realFolder + "/") ? p.slice(realFolder.length + 1) : p.slice(folder.length + 1);
for await (const ev of Deno.watchFs(folder, { recursive: true })) {
  if (ev.kind === "access") continue;
  const paths = ev.paths.filter((p) => !(outInside && p.startsWith(outDir)) && isSource(relPath(p)));
  if (!paths.length) continue;
  if (txp) for (const p of paths) txpFileChanged(relPath(p));
  else schedule(relPath(paths[0]));
}
