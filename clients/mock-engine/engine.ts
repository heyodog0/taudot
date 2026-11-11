// A mock of the taudot engine: docs/api.md level 0 over a Unix socket, serving files from one folder.
// It has no Overleaf backend. Edits from clients are transformed against what they hadn't seen, applied in order,
// broadcast, and written back to the folder.

import { join, relative, resolve } from "jsr:@std/path@1";
import { walk } from "jsr:@std/fs@1/walk";
import { applyEdits, blen, type Edit, fromEdits, mapPos, type Op, toEdits, transform } from "./ot.ts";

const enc = new TextEncoder();
const dec = new TextDecoder();

export interface User {
  user_id: string;
  name: string;
  initials: string;
}

export const ME: User = { user_id: "u-me", name: "You", initials: "ME" };

export interface Range {
  id: string;
  kind: "comment" | "tracked_insert" | "tracked_delete";
  start: number;
  end: number;
  text: string;
  author: User;
  ts: number;
  thread_id?: string;
  resolved?: boolean;
}

export interface Message {
  id: string;
  text: string;
  ts: number;
  user: User;
}

export interface Thread {
  thread_id: string;
  resolved: boolean;
  resolved_at: number | null;
  resolved_by: User | null;
  messages: Message[];
}

interface HistoryEntry {
  seq: number;
  op: Op;
  edits: Edit[];
  author: User;
  origin: "local" | "remote";
  source?: "disk";
}

export interface Doc {
  doc_id: string;
  path: string;
  text: Uint8Array;
  seq: number;
  history: HistoryEntry[]; // history[k-1] takes the text from seq k-1 to seq k
  subscribers: Set<Conn>;
  ranges: Range[];
  writeTimer?: ReturnType<typeof setTimeout>;
  written?: Uint8Array; // what this engine last wrote to the file
}

interface Presence extends User {
  client_id: string;
  doc_id: string | null;
  pos: number | null;
  seq: number | null;
}

export interface Conn {
  id: number;
  send(msg: unknown): void;
  activity: boolean;
  project: boolean;
  queue: Promise<void>;
}

const PROJECT_ID = "mock";
/** This process (engine.info `instance`): changes when the engine restarts. */
const INSTANCE = `${Deno.pid}-${Date.now()}`;
const TEXT_EXT = /\.(tex|bib|cls|sty|bst|txt|md|latexmkrc)$/;

export class RpcError extends Error {
  constructor(public code: number, message: string) {
    super(message);
  }
}

export interface EngineOptions {
  folder: string;
  latencyMs: number;
  log: (line: string) => void;
}

export class Engine {
  docs = new Map<string, Doc>();
  byPath = new Map<string, Doc>();
  conns = new Set<Conn>();
  presence = new Map<string, Presence>();
  threads = new Map<string, Thread>();
  trackChanges = false;
  private msgId = 0;
  activitySeq = 0;
  activityLog: Record<string, unknown>[] = [];
  folder: string;
  private rangeId = 0;

  constructor(private opts: EngineOptions) {
    this.folder = resolve(opts.folder);
  }

  async load() {
    let n = 0;
    for await (const e of walk(this.folder, { includeDirs: false, skip: [/\/\.git\//, /\/\.taudot\//] })) {
      if (!TEXT_EXT.test(e.name)) continue;
      const path = relative(this.folder, e.path);
      const doc: Doc = {
        doc_id: `doc${++n}`,
        path,
        text: await Deno.readFile(e.path),
        seq: 0,
        history: [],
        subscribers: new Set(),
        ranges: [],
      };
      this.docs.set(doc.doc_id, doc);
      this.byPath.set(path, doc);
    }
    this.opts.log(`serving ${this.docs.size} docs from ${this.folder}`);
  }

  docList() {
    return [...this.docs.values()].map((d) => ({ doc_id: d.doc_id, path: d.path }));
  }

  findDoc(doc_id: unknown): Doc {
    const d = this.docs.get(String(doc_id));
    if (!d) throw new RpcError(-32602, `unknown doc_id ${doc_id}`);
    return d;
  }

  notify(conn: Conn, method: string, params: unknown) {
    conn.send({ jsonrpc: "2.0", method, params });
  }

  // ---- methods ---------------------------------------------------------------------------------------------

  async handle(conn: Conn, method: string, p: Record<string, unknown>): Promise<unknown> {
    switch (method) {
      case "engine.info":
        return { api_level: 0, version: "mock-0.1", instance: INSTANCE };
      case "project.open":
        conn.project = true;
        if (p.folder && resolve(String(p.folder)) !== this.folder) {
          this.opts.log(`project.open asked for ${p.folder}, serving ${this.folder}`);
        }
        this.activity("connection", "Client connected", { user: ME });
        return { project_id: PROJECT_ID, folder: this.folder, docs: this.docList(), me: ME };
      case "project.status":
        return {
          connection: "online",
          track_changes: this.trackChanges,
          users: this.users(),
          docs: [...this.docs.values()].map((d) => ({ doc_id: d.doc_id, path: d.path, state: "idle", unconfirmed: 0 })),
        };
      case "doc.open": {
        let path = String(p.path ?? "");
        if (path.startsWith("/")) path = relative(this.folder, path);
        const d = this.byPath.get(path);
        if (!d) throw new RpcError(-32602, `no doc at ${path}`);
        return { doc_id: d.doc_id, text: dec.decode(d.text), seq: d.seq };
      }
      case "doc.subscribe": {
        const d = this.findDoc(p.doc_id);
        const since = Number(p.since_seq ?? d.seq);
        d.subscribers.add(conn);
        for (const h of d.history.slice(since)) {
          this.notify(conn, "doc.changed", {
            doc_id: d.doc_id,
            seq: h.seq,
            edits: h.edits,
            author: h.author,
            origin: h.origin,
            ...(h.source ? { source: h.source } : {}),
          });
        }
        return { seq: d.seq };
      }
      case "doc.edit": {
        const d = this.findDoc(p.doc_id);
        const edits = p.edits as Edit[];
        const seq = Number(p.seq);
        if (!Array.isArray(edits) || !(seq >= 0 && seq <= d.seq)) throw new RpcError(-32602, "bad doc.edit params");
        if (this.opts.latencyMs > 0) {
          this.notify(conn, "doc.state", {
            doc_id: d.doc_id,
            state: "inflight",
            unconfirmed: edits.length,
            oldest_unconfirmed_ms: 0,
            seq: d.seq,
          });
          await new Promise((r) => setTimeout(r, this.opts.latencyMs));
        }
        const newSeq = this.applyEdit(d, edits, seq, ME, "local", conn);
        this.notify(conn, "doc.state", { doc_id: d.doc_id, state: "idle", unconfirmed: 0, oldest_unconfirmed_ms: 0, seq: newSeq });
        return { seq: newSeq };
      }
      case "doc.ranges": {
        const d = this.findDoc(p.doc_id);
        return { doc_id: d.doc_id, seq: d.seq, ranges: this.rangesOf(d) };
      }
      case "thread.get":
        return this.thread(p.thread_id);
      case "thread.list": {
        const threads = [];
        for (const d of this.docs.values()) {
          for (const r of d.ranges.filter((r) => r.kind === "comment")) {
            const t = this.threads.get(r.thread_id!)!;
            threads.push({ ...t, doc_id: d.doc_id, path: d.path, start: r.start, end: r.end, text: r.text, seq: d.seq });
          }
        }
        return { supported: true, threads };
      }
      case "comment.add": {
        const d = this.findDoc(p.doc_id);
        const thread_id = this.addComment(d, Number(p.start), Number(p.end), ME, String(p.text ?? ""));
        return { thread_id, seq: d.seq };
      }
      case "thread.reply":
        this.addMessage(this.thread(p.thread_id), ME, String(p.text ?? ""));
        return {};
      case "thread.resolve":
      case "thread.reopen": {
        const t = this.thread(p.thread_id);
        t.resolved = method === "thread.resolve";
        t.resolved_at = t.resolved ? Date.now() : null;
        t.resolved_by = t.resolved ? ME : null;
        this.threadChanged(t.thread_id);
        for (const d of this.docs.values()) if (d.ranges.some((r) => r.thread_id === t.thread_id)) this.rangesChanged(d);
        return {};
      }
      case "thread.delete": {
        const t = this.thread(p.thread_id);
        this.threads.delete(t.thread_id);
        for (const d of this.docs.values()) {
          const n = d.ranges.length;
          d.ranges = d.ranges.filter((r) => r.thread_id !== t.thread_id);
          if (d.ranges.length !== n) this.rangesChanged(d);
        }
        this.threadChanged(t.thread_id);
        return {};
      }
      case "message.edit":
      case "message.delete": {
        const t = this.thread(p.thread_id);
        const m = t.messages.find((m) => m.id === p.message_id);
        if (!m) throw new RpcError(-32000, `no message ${p.message_id}`);
        if (method === "message.edit") m.text = String(p.text ?? "");
        else t.messages = t.messages.filter((x) => x !== m);
        this.threadChanged(t.thread_id);
        return {};
      }
      case "change.accept":
      case "change.reject": {
        const d = this.findDoc(p.doc_id);
        const ids = (p.ids as string[]) ?? [];
        const changes = d.ranges.filter((r) => ids.includes(r.id) && r.kind !== "comment");
        if (changes.length !== ids.length) throw new RpcError(-32000, "no such tracked change");
        d.ranges = d.ranges.filter((r) => !changes.includes(r));
        if (method === "change.reject") {
          // Highest first, so each inverse leaves the others where they are.
          const edits = changes.sort((a, b) => b.start - a.start).map((r) =>
            r.kind === "tracked_insert" ? { pos: r.start, del: r.end - r.start, ins: "" } : { pos: r.start, del: 0, ins: r.text }
          );
          const was = this.trackChanges;
          this.trackChanges = false;
          this.applyEdit(d, edits, d.seq, ME, "local", null);
          this.trackChanges = was;
        }
        this.rangesChanged(d);
        return {};
      }
      case "review.track":
        if (typeof p.on === "boolean") this.trackChanges = p.on;
        return { on: this.trackChanges };
      case "presence.cursor": {
        const d = this.findDoc(p.doc_id);
        this.setPresence(ME, d.doc_id, Number(p.pos), conn);
        return {};
      }
      case "activity.subscribe": {
        conn.activity = true;
        const since = Number(p.since_seq ?? this.activitySeq);
        for (const a of this.activityLog.filter((a) => (a.seq as number) > since)) {
          this.notify(conn, "activity", a);
        }
        return { seq: this.activitySeq };
      }
      default:
        throw new RpcError(-32601, `unknown method ${method}`);
    }
  }

  // ---- state changes ----------------------------------------------------------------------------------------

  // Apply edits written against `seq`. Returns the new seq. `sender` doesn't get its own edit back.
  applyEdit(d: Doc, edits: Edit[], seq: number, author: User, origin: "local" | "remote", sender: Conn | null, source?: "disk") {
    const lenAt = seq === d.seq ? d.text.length : d.history[seq].op.base;
    let op = fromEdits(edits, lenAt);
    for (const h of d.history.slice(seq)) op = transform(h.op, op)[1];
    const out = toEdits(op);
    // What each delete removes, measured as the edits apply in order.
    const deleted: string[] = [];
    let t = d.text;
    for (const e of out) {
      deleted.push(dec.decode(t.slice(e.pos, e.pos + e.del)));
      t = applyEdits(t, [e]);
    }
    d.text = applyEdits(d.text, out);
    d.seq++;
    d.history.push({ seq: d.seq, op, edits: out, author, origin, ...(source ? { source } : {}) });
    if (out.length === 0) return d.seq;

    for (const r of d.ranges) {
      r.start = mapPos(op, r.start, "right");
      r.end = r.kind === "tracked_delete" ? r.start : Math.max(r.start, mapPos(op, r.end, "left"));
      if (r.kind !== "tracked_delete") r.text = dec.decode(d.text.slice(r.start, r.end));
    }
    if (this.trackChanges && author.user_id === ME.user_id) this.track(d, out, deleted, author);
    for (const pr of this.presence.values()) {
      if (pr.doc_id === d.doc_id && pr.pos !== null) pr.pos = mapPos(op, pr.pos, "right");
    }

    const msg = { doc_id: d.doc_id, seq: d.seq, edits: out, author, origin, ...(source ? { source } : {}) };
    for (const c of d.subscribers) if (c !== sender) this.notify(c, "doc.changed", msg);
    if (d.ranges.length) this.rangesChanged(d);

    this.opts.log(
      `${author.initials} ${d.path} seq ${d.seq}${seq < d.seq - 1 ? ` (from ${seq})` : ""}: ` +
        out.map((e) => `@${e.pos}${e.del ? ` -${e.del}` : ""}${e.ins ? ` +${JSON.stringify(e.ins)}` : ""}`).join(", "),
    );
    this.scheduleWrite(d);
    return d.seq;
  }

  // Tracked ranges for edits just applied by someone with tracking on. Edits apply in order; a tracked delete marks
  // where its text was, and an insert typed at that spot goes before it.
  track(d: Doc, out: Edit[], deleted: string[], author: User) {
    out.forEach((e, k) => {
      const ts = Date.now();
      if (e.del > 0) {
        d.ranges.push({ id: `ch${++this.rangeId}`, kind: "tracked_delete", start: e.pos, end: e.pos, text: deleted[k], author, ts });
      }
      if (e.ins) {
        const end = e.pos + blen(e.ins);
        for (const r of d.ranges) if (r.kind === "tracked_delete" && r.start === e.pos) r.start = r.end = end;
        d.ranges.push({ id: `ch${++this.rangeId}`, kind: "tracked_insert", start: e.pos, end, text: e.ins, author, ts });
      }
    });
  }

  thread(id: unknown): Thread {
    const t = this.threads.get(String(id));
    if (!t) throw new RpcError(-32000, `no thread ${id}`);
    return t;
  }

  addMessage(t: Thread, user: User, text: string) {
    t.messages.push({ id: `m${++this.msgId}`, text, ts: Date.now(), user });
    this.threadChanged(t.thread_id);
  }

  threadChanged(thread_id: string) {
    const thread = this.threads.get(thread_id) ?? null;
    for (const c of this.conns) if (c.activity) this.notify(c, "thread.changed", { project_id: PROJECT_ID, thread_id, thread });
  }

  addComment(d: Doc, start: number, end: number, author: User, text: string): string {
    const thread_id = `t${++this.rangeId}`;
    this.threads.set(thread_id, { thread_id, resolved: false, resolved_at: null, resolved_by: null, messages: [] });
    this.addMessage(this.threads.get(thread_id)!, author, text);
    const body = dec.decode(d.text.slice(start, end));
    d.ranges.push({ id: thread_id, kind: "comment", start, end, text: body, author, ts: Date.now(), thread_id });
    this.rangesChanged(d);
    this.opts.log(`${author.initials} commented on ${d.path} [${start}, ${end}): ${text}`);
    this.activity("comment", `${author.name} commented: ${text}`, { doc_id: d.doc_id, user: author });
    return thread_id;
  }

  rangesOf(d: Doc): Range[] {
    return d.ranges.map((r) => r.kind === "comment" ? { ...r, resolved: this.threads.get(r.thread_id!)?.resolved ?? false } : r);
  }

  rangesChanged(d: Doc) {
    const params = { doc_id: d.doc_id, seq: d.seq, ranges: this.rangesOf(d) };
    for (const c of d.subscribers) this.notify(c, "ranges.changed", params);
  }

  setPresence(u: User, doc_id: string | null, pos: number | null, sender: Conn | null) {
    this.presence.set(u.user_id, { ...u, client_id: `c-${u.user_id}`, doc_id, pos, seq: null });
    const params = { project_id: PROJECT_ID, users: this.users() };
    for (const c of this.conns) if (c.project && c !== sender) this.notify(c, "presence.changed", params);
  }

  // Positions move with edits; `seq` says which text they are measured on.
  users() {
    return [...this.presence.values()].map((p) => ({ ...p, seq: p.doc_id ? this.docs.get(p.doc_id)?.seq ?? null : null }));
  }

  activity(kind: string, text: string, extra: { doc_id?: string; user?: User } = {}) {
    const a = { project_id: PROJECT_ID, seq: ++this.activitySeq, ts: Date.now(), kind, text, ...extra };
    this.activityLog.push(a);
    if (this.activityLog.length > 500) this.activityLog.shift();
    for (const c of this.conns) if (c.activity) this.notify(c, "activity", a);
  }

  // The real engine sends a file edited on disk (an editor, an agent) as a local edit with `source: "disk"`: the same
  // here, as one edit from the common prefix and suffix (byte offsets).
  async watchDisk() {
    const pending = new Map<string, ReturnType<typeof setTimeout>>();
    const real = Deno.realPathSync(this.folder);  // (the watcher reports /private/var/…, not /var/…)
    for await (const ev of Deno.watchFs(this.folder)) {
      for (const p of ev.paths) {
        const d = this.byPath.get(relative(real, p));
        if (!d || ev.kind === "access") continue;
        clearTimeout(pending.get(d.path));
        pending.set(d.path, setTimeout(() => this.diskChanged(d), 50));
      }
    }
  }

  async diskChanged(d: Doc) {
    let now: Uint8Array;
    try {
      now = await Deno.readFile(join(this.folder, d.path));
    } catch {
      return;
    }
    // our own write (possibly behind d.text by edits since): not an edit made on disk
    if (d.written && d.written.length === now.length && d.written.every((b, i) => b === now[i])) return;
    const old = d.text;
    let a = 0;
    while (a < old.length && a < now.length && old[a] === now[a]) a++;
    let b = 0;
    while (b < old.length - a && b < now.length - a && old[old.length - 1 - b] === now[now.length - 1 - b]) b++;
    if (a === old.length && a === now.length) return;
    // (not inside a UTF-8 sequence)
    while (a > 0 && (old[a] & 0xc0) === 0x80) a--;
    while (b > 0 && (old[old.length - b] & 0xc0) === 0x80) b--;
    const ins = dec.decode(now.slice(a, now.length - b));
    this.applyEdit(d, [{ pos: a, del: old.length - b - a, ins }], d.seq, ME, "local", null, "disk");
  }

  scheduleWrite(d: Doc) {
    if (d.writeTimer !== undefined) return;
    d.writeTimer = setTimeout(async () => {
      d.writeTimer = undefined;
      d.written = d.text;  // (the watcher ignores the file while it is what we wrote)
      await Deno.writeFile(join(this.folder, d.path), d.text);
    }, 300);
  }

  textOf(d: Doc) {
    return dec.decode(d.text);
  }

  byteLen(s: string) {
    return blen(s);
  }

  encode(s: string) {
    return enc.encode(s);
  }
}
