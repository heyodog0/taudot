// Byte-based text operations for the mock engine.
//
// An op is a list of components over UTF-8 bytes: a positive number retains, a negative number deletes, a string
// inserts. This is the ot.js TextOperation shape, written fresh. The API's edit lists ({pos, del, ins}, applied in
// order) convert to and from ops so concurrent edits can be transformed. The Neovim client has the same code in Lua
// (clients/nvim/lua/taudot/ot.lua); keep the two in step.

export interface Edit {
  pos: number;
  del: number;
  ins: string;
}

export type Comp = number | string;
export interface Op {
  comps: Comp[];
  base: number; // length the op applies to
  target: number; // length after applying
}

const enc = new TextEncoder();
const dec = new TextDecoder();
export const blen = (s: string): number => enc.encode(s).length;

function push(op: Op, c: Comp) {
  const n = op.comps.length;
  const last = op.comps[n - 1];
  if (typeof c === "string") {
    if (c === "") return;
    op.target += blen(c);
    if (typeof last === "string") op.comps[n - 1] = last + c;
    // keep inserts before deletes so equal ops have one form
    else if (typeof last === "number" && last < 0) {
      const prev = op.comps[n - 2];
      if (typeof prev === "string") op.comps[n - 2] = prev + c;
      else op.comps.splice(n - 1, 0, c);
    } else op.comps.push(c);
  } else if (c > 0) {
    op.base += c;
    op.target += c;
    if (typeof last === "number" && last > 0) op.comps[n - 1] = last + c;
    else op.comps.push(c);
  } else if (c < 0) {
    op.base -= c;
    if (typeof last === "number" && last < 0) op.comps[n - 1] = last + c;
    else op.comps.push(c);
  }
}

const empty = (): Op => ({ comps: [], base: 0, target: 0 });

export function fromEdit(e: Edit, len: number): Op {
  if (e.pos < 0 || e.del < 0 || e.pos + e.del > len) {
    throw new Error(`edit ${JSON.stringify(e)} out of range for length ${len}`);
  }
  const op = empty();
  push(op, e.pos);
  push(op, -e.del);
  push(op, e.ins);
  push(op, len - e.pos - e.del);
  return op;
}

export function fromEdits(edits: Edit[], len: number): Op {
  let op: Op = { comps: len > 0 ? [len] : [], base: len, target: len };
  for (const e of edits) op = compose(op, fromEdit(e, op.target));
  return op;
}

export function toEdits(op: Op): Edit[] {
  const out: Edit[] = [];
  let pos = 0;
  for (const c of op.comps) {
    if (typeof c === "string") {
      const last = out[out.length - 1];
      if (last && last.pos + blen(last.ins) === pos && last.del === 0) last.ins += c;
      else out.push({ pos, del: 0, ins: c });
      pos += blen(c);
    } else if (c > 0) pos += c;
    else {
      const last = out[out.length - 1];
      if (last && last.pos + blen(last.ins) === pos) last.del += -c;
      else out.push({ pos, del: -c, ins: "" });
    }
  }
  return out;
}

// Split a string at a byte offset. Ops only cut at character boundaries when built from valid edits.
function splitBytes(s: string, n: number): [string, string] {
  const b = enc.encode(s);
  return [dec.decode(b.subarray(0, n)), dec.decode(b.subarray(n))];
}

export function compose(a: Op, b: Op): Op {
  if (a.target !== b.base) throw new Error(`compose: ${a.target} != ${b.base}`);
  const out = empty();
  const ac = [...a.comps], bc = [...b.comps];
  let i = 0, j = 0;
  let x: Comp | undefined = ac[i++], y: Comp | undefined = bc[j++];
  while (x !== undefined || y !== undefined) {
    if (typeof x === "number" && x < 0) {
      push(out, x);
      x = ac[i++];
      continue;
    }
    if (typeof y === "string") {
      push(out, y);
      y = bc[j++];
      continue;
    }
    if (x === undefined || y === undefined) throw new Error("compose: length mismatch");
    if (typeof x === "number" && typeof y === "number") {
      // x retain, y retain or delete
      const n = Math.min(x, Math.abs(y));
      push(out, y > 0 ? n : -n);
      x = x - n || ac[i++];
      y = y > 0 ? (y - n || bc[j++]) : (y + n || bc[j++]);
    } else if (typeof x === "string" && typeof y === "number") {
      const xl = blen(x);
      const n = Math.min(xl, Math.abs(y));
      const [head, tail] = splitBytes(x, n);
      if (y > 0) push(out, head);
      x = tail || ac[i++];
      y = y > 0 ? (y - n || bc[j++]) : (y + n || bc[j++]);
    }
  }
  return out;
}

// transform(a, b) -> [a', b'] with compose(a, b') == compose(b, a'). On equal insert positions a goes first.
export function transform(a: Op, b: Op): [Op, Op] {
  if (a.base !== b.base) throw new Error(`transform: ${a.base} != ${b.base}`);
  const ap = empty(), bp = empty();
  const ac = [...a.comps], bc = [...b.comps];
  let i = 0, j = 0;
  let x: Comp | undefined = ac[i++], y: Comp | undefined = bc[j++];
  while (x !== undefined || y !== undefined) {
    if (typeof x === "string") {
      push(ap, x);
      push(bp, blen(x));
      x = ac[i++];
      continue;
    }
    if (typeof y === "string") {
      push(ap, blen(y));
      push(bp, y);
      y = bc[j++];
      continue;
    }
    if (x === undefined || y === undefined) throw new Error("transform: length mismatch");
    const n = Math.min(Math.abs(x), Math.abs(y));
    if (x > 0 && y > 0) {
      push(ap, n);
      push(bp, n);
    } else if (x < 0 && y > 0) push(ap, -n);
    else if (x > 0 && y < 0) push(bp, -n);
    // both delete: nothing
    x = x > 0 ? (x - n || ac[i++]) : (x + n || ac[i++]);
    y = y > 0 ? (y - n || bc[j++]) : (y + n || bc[j++]);
  }
  return [ap, bp];
}

export function applyEdits(text: Uint8Array, edits: Edit[]): Uint8Array {
  let t = text;
  for (const e of edits) {
    if (e.pos < 0 || e.del < 0 || e.pos + e.del > t.length) {
      throw new Error(`edit ${JSON.stringify(e)} out of range for length ${t.length}`);
    }
    const ins = enc.encode(e.ins);
    const out = new Uint8Array(t.length - e.del + ins.length);
    out.set(t.subarray(0, e.pos), 0);
    out.set(ins, e.pos);
    out.set(t.subarray(e.pos + e.del), e.pos + ins.length);
    t = out;
  }
  return t;
}

// Move a byte position through an op. stick: "left" stays before text inserted at the position.
export function mapPos(op: Op, p: number, stick: "left" | "right" = "right"): number {
  let src = 0, dst = 0;
  for (const c of op.comps) {
    if (typeof c === "string") {
      if (src < p || (src === p && stick === "right")) dst += blen(c);
      continue;
    }
    if (src >= p) break;
    if (c > 0) {
      const n = Math.min(c, p - src);
      src += n;
      dst += n;
      if (n < c) break;
    } else {
      const n = Math.min(-c, p - src);
      src += n;
      if (n < -c) break;
    }
  }
  return dst + Math.max(0, p - src);
}
