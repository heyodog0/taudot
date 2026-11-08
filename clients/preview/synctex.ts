// A small SyncTeX reader: page point -> source line (inverse search), source line -> page point (forward search).
//
// Format (SyncTeX version 1, as tectonic writes it): a preamble of `Input:TAG:PATH`, `Unit:`, `Magnification:`,
// `X Offset:`, `Y Offset:`, then `Content:` with pages `{N` ... `}N`. Inside a page, one record per line:
//   [TAG,LINE:X,Y:W,H,D   vbox open, `]` closes        (TAG,LINE:X,Y:W,H,D   hbox open, `)` closes
//   vTAG,LINE:X,Y:W,H,D   void vbox                     hTAG,LINE:X,Y:W,H,D   void hbox
//   kTAG,LINE:X,Y:W       kern     gTAG,LINE:X,Y  glue     $TAG,LINE:X,Y  math     xTAG,LINE:X,Y  current point
//   rTAG,LINE:X,Y:W,H,D   rule
// X and Y are in scaled points (unit * magnification / 1000), measured from the page's top-left corner, Y down to
// the baseline; a box spans Y-H to Y+D. `!N` lines are byte offsets and are skipped. Checked against pdftotext -bbox
// on tectonic 0.16 output: X / 65536 * 72 / 72.27 is the PDF x in big points.

export interface Node {
  kind: string; // one of [ ( v h k g $ x r
  tag: number;
  line: number;
  x: number; // all four in PDF big points
  y: number;
  w: number;
  h: number;
  d: number;
  parent: number; // index of the enclosing box in the page's node list, -1 at the top
}

export interface SyncTex {
  inputs: Map<number, string>;
  pages: Node[][]; // pages[0] is page 1
}

export function parseSyncTex(text: string): SyncTex {
  const inputs = new Map<number, string>();
  const pages: Node[][] = [];
  let unit = 1, mag = 1000;
  let page: Node[] | undefined;
  const stack: number[] = [];
  let k = 1;
  let content = false;
  for (const raw of text.split("\n")) {
    const line = raw.trimEnd();
    if (!content) {
      let m;
      if ((m = line.match(/^Input:(\d+):(.*)$/))) inputs.set(Number(m[1]), m[2]);
      else if ((m = line.match(/^Unit:(-?\d+)/))) unit = Number(m[1]);
      else if ((m = line.match(/^Magnification:(\d+)/))) mag = Number(m[1]) || 1000;
      else if (line === "Content:") {
        content = true;
        k = (unit * mag) / 1000 / 65536 * (72 / 72.27);
      }
      continue;
    }
    if (line.startsWith("Input:")) {
      const m = line.match(/^Input:(\d+):(.*)$/);
      if (m) inputs.set(Number(m[1]), m[2]);
      continue;
    }
    if (line.startsWith("Postamble:")) break;
    const c = line[0];
    if (c === "{") {
      const n = Number(line.slice(1));
      page = pages[n - 1] = [];
      stack.length = 0;
      continue;
    }
    if (c === "}") {
      page = undefined;
      continue;
    }
    if (!page) continue;
    if (c === "]" || c === ")") {
      stack.pop();
      continue;
    }
    if (!"[(vhkg$xr".includes(c)) continue;
    const m = line.slice(1).match(/^(\d+),(\d+):(-?\d+),(-?\d+)(?::(-?\d+)(?:,(-?\d+),(-?\d+))?)?/);
    if (!m) continue;
    const node: Node = {
      kind: c,
      tag: Number(m[1]),
      line: Number(m[2]),
      x: Number(m[3]) * k,
      y: Number(m[4]) * k,
      w: m[5] ? Number(m[5]) * k : 0,
      h: m[6] ? Number(m[6]) * k : 0,
      d: m[7] ? Number(m[7]) * k : 0,
      parent: stack.length ? stack[stack.length - 1] : -1,
    };
    page.push(node);
    if (c === "[" || c === "(") stack.push(page.length - 1);
  }
  for (let i = 0; i < pages.length; i++) pages[i] ??= [];
  return { inputs, pages };
}

const LEAF = new Set(["g", "k", "$", "x", "h"]);

/** Inverse search: the source of the point (x, y) in big points from the top-left of page `page` (0-based). */
export function inverse(st: SyncTex, page: number, x: number, y: number): { file: string; line: number } | undefined {
  const nodes = st.pages[page];
  if (!nodes || nodes.length === 0) return undefined;
  // the smallest hbox that contains the point (a typeset line, or something inside one)
  let best = -1, bestArea = Infinity;
  for (let i = 0; i < nodes.length; i++) {
    const n = nodes[i];
    if (n.kind !== "(" || n.w <= 0) continue;
    const tol = 1;
    if (x < n.x - tol || x > n.x + n.w + tol || y < n.y - n.h - tol || y > n.y + n.d + tol) continue;
    const area = n.w * (n.h + n.d + 0.1);
    if (area < bestArea) [best, bestArea] = [i, area];
  }
  const within = (i: number, box: number) => {
    for (let p = nodes[i].parent; p >= 0; p = nodes[p].parent) if (p === box) return true;
    return false;
  };
  let pick: Node | undefined;
  if (best >= 0) {
    // the leaf in that box closest to the left of the point; else the first leaf in it
    let left: Node | undefined, first: Node | undefined;
    for (let i = best + 1; i < nodes.length; i++) {
      if (!within(i, best)) {
        if (nodes[i].parent < best) break;
        continue;
      }
      const n = nodes[i];
      if (!LEAF.has(n.kind)) continue;
      first ??= n;
      if (n.x <= x && (!left || n.x >= left.x)) left = n;
    }
    pick = left ?? first ?? nodes[best];
  } else {
    // nearest leaf: by distance to its line first, then across
    let bestD = Infinity;
    for (const n of nodes) {
      if (!LEAF.has(n.kind)) continue;
      const d = Math.abs(n.y - y) * 4 + Math.abs(n.x - x);
      if (d < bestD) [pick, bestD] = [n, d];
    }
  }
  if (!pick) return undefined;
  const file = st.inputs.get(pick.tag);
  return file ? { file, line: pick.line } : undefined;
}

/** Forward search: where line `line` of `file` landed. y is the top of the first box, h its height. */
export function forward(
  st: SyncTex,
  file: string,
  line: number,
): { page: number; x: number; y: number; h: number } | undefined {
  const tags = [...st.inputs].filter(([, p]) => samePath(p, file)).map(([t]) => t);
  if (tags.length === 0) return undefined;
  // the exact line, else the closest line after it (blank and comment lines produce nothing), else before it
  const lines = new Set<number>();
  for (const nodes of st.pages) for (const n of nodes) if (tags.includes(n.tag)) lines.add(n.line);
  let target = -1;
  for (const l of lines) if (l >= line && (target < 0 || l < target)) target = l;
  if (target < 0) for (const l of lines) if (l < line && l > target) target = l;
  if (target < 0) return undefined;
  // Glue and math records are words and formulas. Kerns and boxes alone can be page furniture (a footer is tagged
  // with the line where the page was shipped out), so they only count when a line has no glue or math anywhere.
  const strong = (n: Node) => n.kind === "g" || n.kind === "$";
  const hasStrong = st.pages.some((ns) => ns.some((n) => tags.includes(n.tag) && n.line === target && strong(n)));
  const use = (n: Node) =>
    tags.includes(n.tag) && n.line === target && (hasStrong ? strong(n) : n.kind !== "[" && n.kind !== "v");
  for (let p = 0; p < st.pages.length; p++) {
    let top = Infinity, bottom = -Infinity, x = Infinity;
    for (const n of st.pages[p]) {
      if (!use(n)) continue;
      top = Math.min(top, n.y - Math.max(n.h, 6));
      bottom = Math.max(bottom, n.y + n.d);
      x = Math.min(x, n.x);
    }
    if (top < Infinity) return { page: p, x, y: top, h: Math.max(bottom - top, 8) };
  }
  return undefined;
}

/** Paths in SyncTeX files can be absolute, or relative with `./`. Compare by normalised suffix. */
export function samePath(a: string, b: string): boolean {
  const norm = (s: string) => s.replace(/^\.\//, "").replace(/\/\.\//g, "/").replace(/^\/private\//, "/");
  const x = norm(a), y = norm(b);
  return x === y || x.endsWith("/" + y) || y.endsWith("/" + x);
}

export async function readSyncTex(path: string): Promise<SyncTex | undefined> {
  try {
    const file = await Deno.open(path);
    const text = await new Response(file.readable.pipeThrough(new DecompressionStream("gzip"))).text();
    return parseSyncTex(text);
  } catch {
    return undefined;
  }
}
