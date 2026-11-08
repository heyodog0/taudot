// Pure parts of the preview: error parsing, the page layout and viewport, keys, mouse and terminal replies.
// No I/O, so they can be tested.

/** The first LaTeX error in tectonic's stderr (or a log), as one line. */
export function firstError(stderr: string): string | undefined {
  const lines = stderr.split("\n").map((l) => l.trim());
  for (const l of lines) {
    const m = l.match(/^error: (.*)$/);
    if (!m) continue;
    const msg = m[1];
    if (/^halted on potentially-recoverable error/.test(msg)) continue;
    if (/^the TeX engine had an error/.test(msg)) continue;
    return msg.replace(/^!\s*/, "").replace(/\s+/g, " ").trim();
  }
  // TeX log style: "! Undefined control sequence." followed by "l.15 ..."
  const i = lines.findIndex((l) => l.startsWith("! "));
  if (i >= 0) {
    const at = lines.slice(i + 1, i + 8).find((l) => /^l\.\d+/.test(l));
    const line = at?.match(/^l\.(\d+)/)?.[1];
    return (line ? `line ${line}: ` : "") + lines[i].slice(2);
  }
  return lines.find((l) => l.length > 0 && !l.startsWith("note:") && !l.startsWith("warning:"));
}

/** Page sizes in points from `pdfinfo -f 1 -l N` output. */
export function parsePdfinfo(out: string): { pages: number; sizes: [number, number][] } {
  const pages = Number(out.match(/^Pages:\s+(\d+)/m)?.[1] ?? 0);
  const sizes: [number, number][] = [];
  for (const m of out.matchAll(/^Page\s+(\d+) size:\s+([\d.]+) x ([\d.]+) pts/gm)) {
    sizes[Number(m[1]) - 1] = [Number(m[2]), Number(m[3])];
  }
  if (sizes.length === 0) {
    const m = out.match(/^Page size:\s+([\d.]+) x ([\d.]+) pts/m);
    if (m) for (let i = 0; i < pages; i++) sizes[i] = [Number(m[1]), Number(m[2])];
  }
  return { pages, sizes };
}

// ---- layout and viewport --------------------------------------------------------------------------------------------
//
// Pages are stacked top to bottom in one strip, `gap` points apart, each centred on the widest page. Document
// coordinates are points from the strip's top-left. The viewport shows the strip at `scale` pixels per point, with
// (left, top) in document points at the area's top-left corner.

export type Size = [number, number];

export interface Viewport {
  areaW: number; // pixels
  areaH: number;
  scale: number; // pixels per point
  left: number; // points
  top: number;
}

export const GAP = 10; // points between pages
const MARGIN = 6; // pixels left and right of the page at fit-width

export function docWidth(sizes: Size[]): number {
  return sizes.reduce((m, s) => Math.max(m, s[0]), 0);
}

export function pageTops(sizes: Size[]): number[] {
  const tops: number[] = [];
  let y = 0;
  for (const s of sizes) {
    tops.push(y);
    y += s[1] + GAP;
  }
  return tops;
}

export function docHeight(sizes: Size[]): number {
  return sizes.reduce((h, s) => h + s[1], 0) + GAP * Math.max(0, sizes.length - 1);
}

export function fitWidthScale(sizes: Size[], areaW: number): number {
  const w = docWidth(sizes);
  return w > 0 ? Math.max(0.05, (areaW - 2 * MARGIN) / w) : 1;
}

export function fitPageScale(sizes: Size[], page: number, areaW: number, areaH: number): number {
  const s = sizes[page] ?? sizes[0];
  if (!s) return 1;
  return Math.max(0.05, Math.min((areaW - 2 * MARGIN) / s[0], areaH / s[1]));
}

/** Keeps the view on the strip: centred across when narrower than the area, clamped otherwise. */
export function clampView(v: Viewport, sizes: Size[]): Viewport {
  const viewW = v.areaW / v.scale, viewH = v.areaH / v.scale;
  const dw = docWidth(sizes), dh = docHeight(sizes);
  const left = dw <= viewW ? -(viewW - dw) / 2 : Math.max(0, Math.min(v.left, dw - viewW));
  const top = dh <= viewH ? 0 : Math.max(0, Math.min(v.top, dh - viewH));
  return { ...v, left, top };
}

/** Changes the scale keeping the document point under pixel (px, py) where it is. */
export function zoomAt(v: Viewport, scale: number, px: number, py: number): Viewport {
  const dx = v.left + px / v.scale, dy = v.top + py / v.scale;
  return { ...v, scale, left: dx - px / scale, top: dy - py / scale };
}

export interface Piece {
  page: number;
  // the visible part of the page, in page points
  x0: number;
  y0: number;
  x1: number;
  y1: number;
  // where it goes in the area, in pixels
  dx: number;
  dy: number;
  dw: number;
  dh: number;
}

/** The visible part of each page. Pixel edges are rounded so neighbouring pieces neither overlap nor leave seams. */
export function visiblePieces(v: Viewport, sizes: Size[]): Piece[] {
  const tops = pageTops(sizes), dw = docWidth(sizes);
  const out: Piece[] = [];
  const viewH = v.areaH / v.scale, viewW = v.areaW / v.scale;
  for (let p = 0; p < sizes.length; p++) {
    const [w, h] = sizes[p];
    const px = (dw - w) / 2, py = tops[p];
    if (py > v.top + viewH || py + h < v.top) continue;
    const x0 = Math.max(0, v.left - px), x1 = Math.min(w, v.left + viewW - px);
    const y0 = Math.max(0, v.top - py), y1 = Math.min(h, v.top + viewH - py);
    if (x1 <= x0 || y1 <= y0) continue;
    const dx = Math.round((px + x0 - v.left) * v.scale), dy = Math.round((py + y0 - v.top) * v.scale);
    const ex = Math.min(v.areaW, Math.round((px + x1 - v.left) * v.scale));
    const ey = Math.min(v.areaH, Math.round((py + y1 - v.top) * v.scale));
    if (ex - dx < 1 || ey - dy < 1) continue;
    out.push({ page: p, x0, y0, x1, y1, dx, dy, dw: ex - dx, dh: ey - dy });
  }
  return out;
}

/** The page and page point (in points) under area pixel (px, py), if any. */
export function pointToPage(
  v: Viewport,
  sizes: Size[],
  px: number,
  py: number,
): { page: number; x: number; y: number } | undefined {
  const tops = pageTops(sizes), dw = docWidth(sizes);
  const X = v.left + px / v.scale, Y = v.top + py / v.scale;
  for (let p = 0; p < sizes.length; p++) {
    const [w, h] = sizes[p];
    const x = X - (dw - w) / 2, y = Y - tops[p];
    if (x >= 0 && x <= w && y >= 0 && y <= h) return { page: p, x, y };
  }
  return undefined;
}

/** The page at the vertical middle of the view (for the status line). */
export function currentPage(v: Viewport, sizes: Size[]): number {
  const tops = pageTops(sizes);
  const mid = v.top + v.areaH / v.scale / 2;
  let p = 0;
  for (let i = 0; i < tops.length; i++) if (tops[i] <= mid) p = i;
  return p;
}

/**
 * Where to put a source rectangle of a rendered image so it fills a piece.
 * The render has `scale` pixels per point and holds the page region starting at pixel (ox, oy), size w x h.
 * When the render's scale matches the view's, the image is cropped and placed to the pixel (`X`/`Y` offsets inside
 * the first cell). Otherwise (during a zoom) the crop is scaled into whole cells with `c`/`r`, snapped to the grid.
 */
export interface Placement {
  col: number;
  row: number;
  X: number;
  Y: number;
  x: number;
  y: number;
  w: number;
  h: number;
  c?: number;
  r?: number;
}

export function placePiece(
  piece: Piece,
  viewScale: number,
  render: { scale: number; ox: number; oy: number; w: number; h: number },
  cellW: number,
  cellH: number,
): Placement | undefined {
  const k = render.scale / viewScale; // image pixels per screen pixel
  // the piece in image pixels
  let sx = piece.x0 * render.scale - render.ox, sy = piece.y0 * render.scale - render.oy;
  let sw = piece.dw * k, sh = piece.dh * k;
  let dx = piece.dx, dy = piece.dy;
  // clip to the image (a cropped render may not cover all of the piece)
  if (sx < 0) {
    dx += -sx / k;
    sw += sx;
    sx = 0;
  }
  if (sy < 0) {
    dy += -sy / k;
    sh += sy;
    sy = 0;
  }
  sw = Math.min(sw, render.w - sx);
  sh = Math.min(sh, render.h - sy);
  if (sw < 1 || sh < 1) return undefined;
  if (Math.abs(k - 1) < 0.005) {
    const X = Math.round(dx), Y = Math.round(dy);
    return {
      col: Math.floor(X / cellW),
      row: Math.floor(Y / cellH),
      X: X % cellW,
      Y: Y % cellH,
      x: Math.round(sx),
      y: Math.round(sy),
      w: Math.max(1, Math.round(Math.min(sw, render.w - Math.round(sx)))),
      h: Math.max(1, Math.round(Math.min(sh, render.h - Math.round(sy)))),
    };
  }
  const col = Math.round(dx / cellW), row = Math.round(dy / cellH);
  const c = Math.max(1, Math.round((dx + sw / k) / cellW) - col);
  const r = Math.max(1, Math.round((dy + sh / k) / cellH) - row);
  return {
    col,
    row,
    X: 0,
    Y: 0,
    x: Math.round(sx),
    y: Math.round(sy),
    w: Math.max(1, Math.round(Math.min(c * cellW * k, render.w - sx))),
    h: Math.max(1, Math.round(Math.min(r * cellH * k, render.h - sy))),
    c,
    r,
  };
}

/** Width and height from a PNG's header. */
export function pngSize(b: Uint8Array): [number, number] | undefined {
  if (b.length < 24 || b[1] !== 0x50 || b[2] !== 0x4e || b[3] !== 0x47) return undefined;
  const dv = new DataView(b.buffer, b.byteOffset, b.byteLength);
  return [dv.getUint32(16), dv.getUint32(20)];
}

// ---- keys -----------------------------------------------------------------------------------------------------------

export type Action =
  | { kind: "page"; to: "next" | "prev" | "first" | "last" }
  | { kind: "scroll"; dx: number; dy: number } // in fractions of the area
  | { kind: "zoom"; to: "in" | "out" | "width" | "page" }
  | { kind: "recompile" }
  | { kind: "quit" };

/** Turns key bytes into actions. Holds the pending `g` of `gg`. */
export class Keys {
  private pendingG = false;

  feed(s: string): Action[] {
    const out: Action[] = [];
    for (const ch of s) {
      if (this.pendingG) {
        this.pendingG = false;
        if (ch === "g") {
          out.push({ kind: "page", to: "first" });
          continue;
        }
      }
      const a = KEYMAP[ch];
      if (ch === "g") this.pendingG = true;
      else if (a) out.push(a);
    }
    return out;
  }
}

const KEYMAP: Record<string, Action> = {
  G: { kind: "page", to: "last" },
  J: { kind: "page", to: "next" },
  n: { kind: "page", to: "next" },
  " ": { kind: "page", to: "next" },
  K: { kind: "page", to: "prev" },
  p: { kind: "page", to: "prev" },
  j: { kind: "scroll", dx: 0, dy: 0.2 },
  k: { kind: "scroll", dx: 0, dy: -0.2 },
  h: { kind: "scroll", dx: -0.2, dy: 0 },
  l: { kind: "scroll", dx: 0.2, dy: 0 },
  "\x04": { kind: "scroll", dx: 0, dy: 0.5 }, // ctrl-d
  "\x15": { kind: "scroll", dx: 0, dy: -0.5 }, // ctrl-u
  "+": { kind: "zoom", to: "in" },
  "=": { kind: "zoom", to: "in" },
  "-": { kind: "zoom", to: "out" },
  _: { kind: "zoom", to: "out" },
  "0": { kind: "zoom", to: "width" },
  w: { kind: "zoom", to: "width" },
  f: { kind: "zoom", to: "page" },
  r: { kind: "recompile" },
  q: { kind: "quit" },
  "\x03": { kind: "quit" },
};

// ---- terminal input -------------------------------------------------------------------------------------------------

export interface Mouse {
  button: number; // low bits of the SGR code: 0 left, 1 middle, 2 right, 3 none; 64.. wheel
  x: number; // as reported (pixels in mode 1016, cells in 1006), 1-based
  y: number;
  release: boolean;
  motion: boolean;
  wheel?: "up" | "down" | "left" | "right";
  shift: boolean;
  alt: boolean;
  ctrl: boolean;
}

export function parseSgrMouse(seq: string): Mouse | undefined {
  const m = seq.match(/^\x1b\[<(\d+);(-?\d+);(-?\d+)([Mm])$/);
  if (!m) return undefined;
  const b = Number(m[1]);
  const low = b & 3, wheelBit = b & 64;
  return {
    button: wheelBit ? 64 + low : low,
    x: Number(m[2]),
    y: Number(m[3]),
    release: m[4] === "m",
    motion: (b & 32) !== 0,
    wheel: wheelBit ? (["up", "down", "left", "right"] as const)[low] : undefined,
    shift: (b & 4) !== 0,
    alt: (b & 8) !== 0,
    ctrl: (b & 16) !== 0,
  };
}

/**
 * Splits terminal input into key text, mouse events and replies to our queries.
 * Replies: CSI ... t (sizes), CSI ? ... c (device attributes), CSI ? ... $ y (mode report), APC G ... ST (kitty),
 * OSC ... (colours). Arrows and PgUp/PgDn are mapped to keys; other sequences are dropped.
 */
export function splitInput(s: string): { keys: string; mouse: Mouse[]; replies: string[] } {
  let keys = "";
  const replies: string[] = [];
  const mouse: Mouse[] = [];
  let i = 0;
  while (i < s.length) {
    const c = s[i];
    if (c !== "\x1b") {
      keys += c;
      i++;
      continue;
    }
    const n = s[i + 1];
    if (n === "[") {
      let j = i + 2;
      while (j < s.length && !/[@-~]/.test(s[j])) j++;
      const seq = s.slice(i, j + 1);
      const fin = s[j];
      if (seq.startsWith("\x1b[<") && (fin === "M" || fin === "m")) {
        const m = parseSgrMouse(seq);
        if (m) mouse.push(m);
      } else if (fin === "t" || fin === "c" || fin === "y") replies.push(seq);
      else if (fin === "A") keys += "k";
      else if (fin === "B") keys += "j";
      else if (fin === "C") keys += "l";
      else if (fin === "D") keys += "h";
      else if (seq === "\x1b[5~") keys += "K";
      else if (seq === "\x1b[6~") keys += "J";
      i = j + 1;
    } else if (n === "_" || n === "]") {
      // APC or OSC, ended by ST (ESC \) or, for OSC, BEL
      let j = i + 2;
      while (j < s.length && !(s[j] === "\x1b" && s[j + 1] === "\\") && !(n === "]" && s[j] === "\x07")) j++;
      const end = j >= s.length ? s.length : s[j] === "\x07" ? j + 1 : j + 2;
      replies.push(s.slice(i, end));
      i = end;
    } else if (n === undefined) {
      i++; // lone ESC
    } else {
      i += 2;
    }
  }
  return { keys, mouse, replies };
}

/** Reads the pixel sizes out of CSI t replies. */
export function parseSizeReply(r: string): { area?: [number, number]; cell?: [number, number] } {
  const m = r.match(/^\x1b\[(\d+);(\d+);(\d+)t$/);
  if (!m) return {};
  const [k, h, w] = [Number(m[1]), Number(m[2]), Number(m[3])];
  if (k === 4) return { area: [w, h] };
  if (k === 6) return { cell: [w, h] };
  return {};
}

/** DECRQM reply `CSI ? mode ; value $ y`: 1 set, 2 reset, 0 unknown. */
export function parseModeReply(r: string): { mode: number; value: number } | undefined {
  const m = r.match(/^\x1b\[\?(\d+);(\d+)\$y$/);
  return m ? { mode: Number(m[1]), value: Number(m[2]) } : undefined;
}

/** OSC 10/11/12 colour reply, `rgb:RRRR/GGGG/BBBB`, as 8-bit [r, g, b]. */
export function parseColourReply(r: string): { which: number; rgb: [number, number, number] } | undefined {
  const m = r.match(/^\x1b\](\d+);rgb:([0-9a-f]+)\/([0-9a-f]+)\/([0-9a-f]+)/i);
  if (!m) return undefined;
  const c = (h: string) => Math.round(parseInt(h, 16) / (16 ** h.length - 1) * 255);
  return { which: Number(m[1]), rgb: [c(m[2]), c(m[3]), c(m[4])] };
}

/** Files whose change should trigger a compile. */
export function isSource(path: string): boolean {
  const base = path.split("/").pop() ?? "";
  if (base.startsWith(".") || base.endsWith("~") || base.startsWith("#")) return false;
  if (path.split("/").some((p) => p.startsWith(".") && p.length > 1 && p !== "..")) return false;
  return /\.(tex|bib|cls|sty|bst|bbx|cbx|def|cfg|png|jpe?g|pdf|eps|svg|tikz|csv|dat|txt)$/i.test(base);
}

/** OSC 7501 program status. */
export function osc7501(state: "idle" | "working" | "blocked" | "error", msg: string): string {
  const clean = msg.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ").slice(0, 200);
  const bytes = new TextEncoder().encode(clean);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return `\x1b]7501;state=${state}:app=taudot:msg=${btoa(bin)}\x1b\\`;
}

/** Cuts a string to n terminal columns (counts code points, good enough for messages). */
export function fit(s: string, n: number): string {
  const cps = [...s];
  if (cps.length <= n) return s;
  return cps.slice(0, Math.max(0, n - 1)).join("") + "…";
}

// ---- snapshot zoom --------------------------------------------------------------------------------------------------
//
// During a zoom the pane shows ONE snapshot image of the view plus a margin, placed in a fixed box (the whole page
// area, whole cells), and only its source rectangle changes, which is pixel-continuous. Past the snapshot's edges
// the source is clipped and the box shrinks to match (only then can the box snap to cells).

export interface Snapshot {
  left: number; // document point at pixel (0, 0)
  top: number;
  scale: number; // pixels per point
  w: number; // pixels
  h: number;
}

export function placeSnapshot(
  v: Viewport,
  s: Snapshot,
  cellW: number,
  cellH: number,
  cols: number,
  areaRows: number,
): Placement | undefined {
  const k = s.scale / v.scale; // snapshot pixels per screen pixel
  const boxW = cols * cellW, boxH = areaRows * cellH;
  let sx = (v.left - s.left) * s.scale, sy = (v.top - s.top) * s.scale;
  let sw = boxW * k, sh = boxH * k;
  let dx = 0, dy = 0, dw = boxW, dh = boxH;
  if (sx < 0) {
    dx = -sx / k;
    sw += sx;
    sx = 0;
  }
  if (sy < 0) {
    dy = -sy / k;
    sh += sy;
    sy = 0;
  }
  if (sx + sw > s.w) sw = s.w - sx;
  if (sy + sh > s.h) sh = s.h - sy;
  if (sw < 1 || sh < 1) return undefined;
  dw = Math.min(boxW - dx, sw / k);
  dh = Math.min(boxH - dy, sh / k);
  const col = Math.floor(dx / cellW), row = Math.floor(dy / cellH);
  const X = Math.round(dx - col * cellW), Y = Math.round(dy - row * cellH);
  // whole box: exact. Clipped: the nearest whole number of cells, never past the area
  const c = Math.max(1, Math.min(cols - col, Math.round((X + dw) / cellW)));
  const r = Math.max(1, Math.min(areaRows - row, Math.round((Y + dh) / cellH)));
  const exactW = dx === 0 && dw === boxW, exactH = dy === 0 && dh === boxH;
  return {
    col,
    row,
    X: exactW ? 0 : X,
    Y: exactH ? 0 : Y,
    x: Math.round(sx),
    y: Math.round(sy),
    w: Math.max(1, Math.round(exactW ? Math.min(sw, s.w - Math.round(sx)) : sw)),
    h: Math.max(1, Math.round(exactH ? Math.min(sh, s.h - Math.round(sy)) : sh)),
    c,
    r,
  };
}

/** One step of an exponential ease of `cur` toward `target` in log space (zoom factors), time constant tau ms. */
export function easeZoom(cur: number, target: number, dtMs: number, tauMs = 40): number {
  const a = 1 - Math.exp(-dtMs / tauMs);
  const z = Math.exp(Math.log(cur) + (Math.log(target) - Math.log(cur)) * a);
  return Math.abs(Math.log(target / z)) < 0.002 ? target : z;
}

/** A binary PPM (P6) from pdftoppm: width, height and the RGB bytes. */
export function parsePpm(b: Uint8Array): { w: number; h: number; rgb: Uint8Array } | undefined {
  if (b[0] !== 0x50 || b[1] !== 0x36) return undefined;
  const fields: number[] = [];
  let i = 2;
  while (fields.length < 3 && i < b.length) {
    while (i < b.length && (b[i] === 0x20 || b[i] === 0x0a || b[i] === 0x0d || b[i] === 0x09)) i++;
    if (b[i] === 0x23) { // comment
      while (i < b.length && b[i] !== 0x0a) i++;
      continue;
    }
    let n = 0;
    while (i < b.length && b[i] >= 0x30 && b[i] <= 0x39) n = n * 10 + b[i++] - 0x30;
    fields.push(n);
  }
  i++; // the single whitespace after maxval
  const [w, h] = fields;
  if (!w || !h || b.length - i < w * h * 3) return undefined;
  return { w, h, rgb: b.subarray(i, i + w * h * 3) };
}

/**
 * Copies a page bitmap (RGB, `src` covers page pixels from (ox, oy) at `srcScale`) into an RGBA snapshot.
 * The page's top-left corner is at document point (px, py). Same scale: straight row copies; otherwise nearest pixel.
 */
export function blitPage(
  snap: Uint8Array,
  s: Snapshot,
  src: { rgb: Uint8Array; w: number; h: number; scale: number; ox: number; oy: number },
  px: number,
  py: number,
) {
  // the page bitmap's area in snapshot pixels
  const k = s.scale / src.scale;
  const x0 = Math.max(0, Math.ceil((px - s.left) * s.scale + src.ox * k));
  const y0 = Math.max(0, Math.ceil((py - s.top) * s.scale + src.oy * k));
  const x1 = Math.min(s.w, Math.floor((px - s.left) * s.scale + (src.ox + src.w) * k));
  const y1 = Math.min(s.h, Math.floor((py - s.top) * s.scale + (src.oy + src.h) * k));
  if (x1 <= x0 || y1 <= y0) return;
  const baseX = (px - s.left) * s.scale + src.ox * k, baseY = (py - s.top) * s.scale + src.oy * k;
  const xs = new Int32Array(x1 - x0);
  for (let x = x0; x < x1; x++) xs[x - x0] = Math.min(src.w - 1, Math.max(0, Math.floor((x - baseX) / k))) * 3;
  for (let y = y0; y < y1; y++) {
    const sy = Math.min(src.h - 1, Math.max(0, Math.floor((y - baseY) / k)));
    const srow = sy * src.w * 3;
    let d = (y * s.w + x0) * 4;
    for (let i = 0; i < xs.length; i++) {
      const si = srow + xs[i];
      snap[d] = src.rgb[si];
      snap[d + 1] = src.rgb[si + 1];
      snap[d + 2] = src.rgb[si + 2];
      snap[d + 3] = 255;
      d += 4;
    }
  }
}
