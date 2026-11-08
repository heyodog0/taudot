import { applyEdits, compose, type Edit, fromEdits, mapPos, toEdits, transform } from "./ot.ts";

const enc = new TextEncoder();
const dec = new TextDecoder();
const alphabet = ["a", "b", "\n", "é", "😀", "xy"];

function rng(seed: number) {
  return () => {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed / 0x7fffffff;
  };
}

// Random edits on character boundaries.
function randomEdits(text: string, r: () => number): Edit[] {
  const edits: Edit[] = [];
  let t = text;
  const n = 1 + Math.floor(r() * 3);
  for (let k = 0; k < n; k++) {
    const chars = Array.from(t);
    const i = Math.floor(r() * (chars.length + 1));
    const d = Math.floor(r() * Math.min(3, chars.length - i + 1));
    let ins = "";
    const m = Math.floor(r() * 3);
    for (let q = 0; q < m; q++) ins += alphabet[Math.floor(r() * alphabet.length)];
    const pos = enc.encode(chars.slice(0, i).join("")).length;
    const del = enc.encode(chars.slice(i, i + d).join("")).length;
    edits.push({ pos, del, ins });
    t = chars.slice(0, i).join("") + ins + chars.slice(i + d).join("");
  }
  return edits;
}

const apply = (t: string, e: Edit[]) => dec.decode(applyEdits(enc.encode(t), e));

Deno.test("edits round trip through ops", () => {
  const r = rng(1);
  for (let k = 0; k < 2000; k++) {
    const t = "hello é😀\nworld";
    const e = randomEdits(t, r);
    const op = fromEdits(e, enc.encode(t).length);
    if (apply(t, toEdits(op)) !== apply(t, e)) throw new Error(`round trip ${JSON.stringify(e)}`);
  }
});

Deno.test("transform converges (TP1)", () => {
  const r = rng(7);
  for (let k = 0; k < 5000; k++) {
    const t = "ab é😀\ncd\nef";
    const len = enc.encode(t).length;
    const ea = randomEdits(t, r), eb = randomEdits(t, r);
    const a = fromEdits(ea, len), b = fromEdits(eb, len);
    const [a2, b2] = transform(a, b);
    const left = apply(apply(t, ea), toEdits(b2));
    const right = apply(apply(t, eb), toEdits(a2));
    if (left !== right) {
      throw new Error(`diverged: ${JSON.stringify({ t, ea, eb, left, right })}`);
    }
    compose(a, b2);
  }
});

Deno.test("concurrent inserts at one place: first op goes first", () => {
  const a = fromEdits([{ pos: 1, del: 0, ins: "A" }], 2);
  const b = fromEdits([{ pos: 1, del: 0, ins: "B" }], 2);
  const [a2, b2] = transform(a, b);
  if (apply(apply("xy", toEdits(a)), toEdits(b2)) !== "xABy") throw new Error("order");
  if (apply(apply("xy", toEdits(b)), toEdits(a2)) !== "xABy") throw new Error("order2");
});

Deno.test("mapPos", () => {
  const op = fromEdits([{ pos: 2, del: 2, ins: "XYZ" }], 6);
  const cases: [number, string, number][] = [[0, "right", 0], [2, "left", 2], [2, "right", 5], [3, "right", 5], [4, "right", 5], [6, "right", 7]];
  for (const [p, s, want] of cases) {
    const got = mapPos(op, p, s as "left" | "right");
    if (got !== want) throw new Error(`mapPos(${p},${s}) = ${got}, want ${want}`);
  }
});
