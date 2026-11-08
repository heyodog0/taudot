import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  clampView,
  currentPage,
  firstError,
  fitWidthScale,
  GAP,
  isSource,
  Keys,
  parseColourReply,
  parseModeReply,
  parsePdfinfo,
  parseSgrMouse,
  parseSizeReply,
  placePiece,
  pngSize,
  pointToPage,
  type Size,
  splitInput,
  type Viewport,
  visiblePieces,
  zoomAt,
} from "./lib.ts";

Deno.test("firstError picks tectonic's first real error", () => {
  const s = `note: Running TeX ...
error: main.tex:15: Undefined control sequence
note: Writing \`out/main.log\`
error: halted on potentially-recoverable error as specified`;
  assertEquals(firstError(s), "main.tex:15: Undefined control sequence");
  assertEquals(
    firstError("error: !File ended while scanning use of \\frac \nerror: halted on potentially-recoverable error"),
    "File ended while scanning use of \\frac",
  );
  assertEquals(firstError("! Undefined control sequence.\nl.15 \\foo\n"), "line 15: Undefined control sequence.");
});

Deno.test("parsePdfinfo", () => {
  const r = parsePdfinfo("Pages:           2\nPage    1 size:  612 x 792 pts (letter)\nPage    2 size:  595.28 x 841.89 pts\n");
  assertEquals(r, { pages: 2, sizes: [[612, 792], [595.28, 841.89]] });
});

const letter: Size[] = [[612, 792], [612, 792], [612, 792]];

Deno.test("viewport: fit width, clamping, centring", () => {
  const s = fitWidthScale(letter, 612 + 12);
  assertEquals(s, 1);
  const v = clampView({ areaW: 624, areaH: 500, scale: 1, left: 50, top: -20 }, letter);
  assertEquals([v.left, v.top], [-6, 0]); // centred: 6 px margin each side
  const end = clampView({ ...v, top: 1e9 }, letter);
  assertEquals(end.top, 3 * 792 + 2 * GAP - 500);
});

Deno.test("viewport: pieces across a page boundary have no seam", () => {
  const v: Viewport = { areaW: 624, areaH: 500, scale: 1, left: -6, top: 700 };
  const ps = visiblePieces(v, letter);
  assertEquals(ps.map((p) => p.page), [0, 1]);
  assertEquals([ps[0].dy, ps[0].dh, ps[0].y0], [0, 92, 700]);
  assertEquals([ps[1].dy, ps[1].y0], [92 + GAP, 0]);
  assertEquals(ps[1].dy + ps[1].dh, 500);
  assertEquals([ps[0].dx, ps[0].dw], [6, 612]);
});

Deno.test("viewport: zoom keeps the point under the pointer", () => {
  const v: Viewport = { areaW: 624, areaH: 500, scale: 1, left: -6, top: 100 };
  const before = pointToPage(v, letter, 300, 200)!;
  const z = zoomAt(v, 2, 300, 200);
  const after = pointToPage(z, letter, 300, 200)!;
  assertEquals(after.page, before.page);
  assert(Math.abs(after.x - before.x) < 1e-9 && Math.abs(after.y - before.y) < 1e-9);
  assertEquals(currentPage({ ...v, top: 900 }, letter), 1);
});

Deno.test("placePiece: exact crop at the render's scale, cell-snapped scaling otherwise", () => {
  const piece = { page: 0, x0: 0, y0: 700, x1: 612, y1: 792, dx: 6, dy: 0, dw: 612, dh: 92 };
  const r = { scale: 1, ox: 0, oy: 0, w: 612, h: 792 };
  assertEquals(placePiece(piece, 1, r, 10, 20), { col: 0, row: 0, X: 6, Y: 0, x: 0, y: 700, w: 612, h: 92 });
  const p2 = { ...piece, dy: 102, dx: 6 };
  const pl = placePiece(p2, 1, r, 10, 20)!;
  assertEquals([pl.row, pl.Y, pl.col, pl.X], [5, 2, 0, 6]);
  // render at twice the view's scale: scaled into whole cells
  const r2 = { scale: 2, ox: 0, oy: 0, w: 1224, h: 1584 };
  const s = placePiece(piece, 1, r2, 10, 20)!;
  assertEquals([s.c, s.r, s.y], [61, 5, 1400]);
  assertEquals([s.w, s.h], [1220, 184]);
});

Deno.test("keys", () => {
  const k = new Keys();
  assertEquals(k.feed("gg").map((a) => a.kind + ("to" in a ? a.to : "")), ["pagefirst"]);
  assertEquals(k.feed("g").length, 0);
  assertEquals(k.feed("G").map((a) => ("to" in a ? a.to : "")), ["last"]);
  assertEquals(k.feed("JK+-0f").map((a) => ("to" in a ? a.to : "")), ["next", "prev", "in", "out", "width", "page"]);
});

Deno.test("input: mouse, replies and keys", () => {
  const r = splitInput("j\x1b[6;20;10t\x1b_Gi=1;OK\x1b\\\x1b[Bk\x1b[<80;300;45M\x1b[?1016;1$y\x1b]12;rgb:ffff/8080/0000\x07");
  assertEquals(r.keys, "jjk");
  assertEquals(r.replies, ["\x1b[6;20;10t", "\x1b_Gi=1;OK\x1b\\", "\x1b[?1016;1$y", "\x1b]12;rgb:ffff/8080/0000\x07"]);
  assertEquals(r.mouse.length, 1);
  assertEquals([r.mouse[0].wheel, r.mouse[0].ctrl, r.mouse[0].x, r.mouse[0].y], ["up", true, 300, 45]);
  assertEquals(parseSgrMouse("\x1b[<0;5;6m")?.release, true);
  assertEquals(parseSgrMouse("\x1b[<32;5;6M")?.motion, true);
  assertEquals(parseSgrMouse("\x1b[<65;5;6M")?.wheel, "down");
  assertEquals(parseSizeReply("\x1b[6;20;10t"), { cell: [10, 20] });
  assertEquals(parseModeReply("\x1b[?1016;1$y"), { mode: 1016, value: 1 });
  assertEquals(parseColourReply("\x1b]12;rgb:ffff/8080/0000\x07")?.rgb, [255, 128, 0]);
});

Deno.test("pngSize", () => {
  const b = new Uint8Array(24);
  b.set([0x89, 0x50, 0x4e, 0x47]);
  new DataView(b.buffer).setUint32(16, 1052);
  new DataView(b.buffer).setUint32(20, 1361);
  assertEquals(pngSize(b), [1052, 1361]);
});

Deno.test("isSource", () => {
  assertEquals(isSource("main.tex"), true);
  assertEquals(isSource("fig/a.png"), true);
  assertEquals(isSource(".main.tex.swp"), false);
  assertEquals(isSource(".git/x.tex"), false);
  assertEquals(isSource("main.synctex.gz"), false);
  assertEquals(isSource("4913"), false);
});

import { blitPage, easeZoom, parsePpm, placeSnapshot } from "./lib.ts";

Deno.test("placeSnapshot: fixed whole-pane box, continuous source rect", () => {
  const snap = { left: -100, top: 0, scale: 2, w: 4000, h: 6000 };
  const v: Viewport = { areaW: 840, areaH: 1290, scale: 1.37, left: 10, top: 300 };
  const p = placeSnapshot(v, snap, 14, 30, 60, 43)!;
  assertEquals([p.col, p.row, p.X, p.Y, p.c, p.r], [0, 0, 0, 0, 60, 43]);
  const k = 2 / 1.37;
  assertEquals([p.x, p.y], [Math.round(110 * 2), Math.round(300 * 2)]);
  assertEquals([p.w, p.h], [Math.round(840 * k), Math.round(1290 * k)]);
  // a tiny zoom change moves the source size by a pixel or so, the box stays put
  const q = placeSnapshot({ ...v, scale: 1.371 }, snap, 14, 30, 60, 43)!;
  assertEquals([q.c, q.r], [60, 43]);
  assert(Math.abs(q.w - p.w) <= 2);
  // zoomed far out: clipped, box shrinks inside the area
  const o = placeSnapshot({ ...v, scale: 0.4, left: -500, top: -100 }, snap, 14, 30, 60, 43)!;
  assert(o.col > 0 && o.c! <= 60 - o.col && o.r! <= 43 - o.row);
});

Deno.test("easeZoom converges and blends", () => {
  let z = 1;
  for (let t = 0; t < 8; t++) z = easeZoom(z, 2, 16);
  assert(z > 1.9 && z <= 2, `z ${z}`);
  for (let t = 0; t < 20; t++) z = easeZoom(z, 2, 16);
  assertEquals(z, 2);
});

Deno.test("parsePpm and blitPage", () => {
  const head = new TextEncoder().encode("P6\n2 2\n255\n");
  const ppm = new Uint8Array(head.length + 12);
  ppm.set(head);
  ppm.set([255, 0, 0, 0, 255, 0, 0, 0, 255, 9, 9, 9], head.length);
  const p = parsePpm(ppm)!;
  assertEquals([p.w, p.h, p.rgb[3], p.rgb[4]], [2, 2, 0, 255]);
  const s = { left: 0, top: 0, scale: 2, w: 4, h: 4 };
  const out = new Uint8Array(4 * 4 * 4);
  blitPage(out, s, { rgb: p.rgb, w: 2, h: 2, scale: 1, ox: 0, oy: 0 }, 0, 0);
  assertEquals([...out.subarray(0, 8)], [255, 0, 0, 255, 255, 0, 0, 255]); // doubled
  assertEquals([...out.subarray(15 * 4, 16 * 4)], [9, 9, 9, 255]);
});
