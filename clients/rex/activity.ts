// taudot activity feed for a Rex pane.
//
//   deno run -A activity.ts --folder DIR [--socket PATH]
//
// Prints the engine's `activity` notifications, one line each, in the terminal's 16 ANSI colours only so it follows
// the Rex theme. Reports the sync state with the Program Status Protocol (OSC 7501): working while edits are
// unconfirmed, blocked when offline or read-only, idle when in sync.

import { parseArgs } from "jsr:@std/cli@1/parse-args";
import { join } from "jsr:@std/path@1";

const args = parseArgs(Deno.args, { string: ["folder", "socket"], boolean: ["help"] });
if (args.help || !args.folder) {
  console.log("usage: activity.ts --folder DIR [--socket PATH]");
  Deno.exit(args.help ? 0 : 2);
}
const socket = args.socket ?? Deno.env.get("TAUDOT_SOCKET") ??
  join(Deno.env.get("HOME") ?? ".", ".taudot", "engine.sock");
const enc = new TextEncoder();
const out = (s: string) => Deno.stdout.writeSync(enc.encode(s));

// ---- OSC 7501 -------------------------------------------------------------------------------------------------------

let lastStatus = "";
function status(state: "idle" | "working" | "blocked" | "error", msg: string) {
  const key = state + msg;
  if (key === lastStatus) return;
  lastStatus = key;
  // msg must be one line with no control characters, base64 of UTF-8
  const clean = msg.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ").slice(0, 200);
  const b64 = btoa(String.fromCharCode(...enc.encode(clean)));
  out(`\x1b]7501;state=${state}:app=taudot:msg=${b64}\x1b\\`);
}

// ---- drawing --------------------------------------------------------------------------------------------------------

const C = {
  dim: (s: string) => `\x1b[2m${s}\x1b[22m`,
  bold: (s: string) => `\x1b[1m${s}\x1b[22m`,
  fg: (n: number, s: string) => `\x1b[${30 + n}m${s}\x1b[39m`,
};
// ANSI colours 1..6, in the same order the Neovim client hands out author groups' fallbacks.
const userColour = new Map<string, number>();
function colourOf(user_id: string) {
  if (!userColour.has(user_id)) userColour.set(user_id, (userColour.size % 6) + 1);
  return userColour.get(user_id)!;
}

interface Activity {
  seq: number;
  ts: number;
  kind: string;
  text: string;
  user?: { user_id: string; name: string; initials: string };
}

function line(a: Activity) {
  const t = new Date(a.ts).toTimeString().slice(0, 8);
  const who = a.user ? C.fg(colourOf(a.user.user_id), C.bold(a.user.initials.padEnd(3))) : "   ";
  const mark = a.kind === "comment" ? C.fg(4, "▍") : a.kind === "connection" ? C.dim("·") : " ";
  return `${C.dim(t)} ${who}${mark} ${a.text}\n`;
}

let summary = { connection: "connecting", users: [] as { name: string; initials: string; user_id: string }[], unconfirmed: 0 };

// ---- engine ---------------------------------------------------------------------------------------------------------

async function session() {
  const conn = await Deno.connect({ transport: "unix", path: socket });
  let id = 0, buf = "";
  const waiting = new Map<number, (m: { result?: any; error?: any }) => void>();
  const call = (method: string, params: unknown = {}) =>
    new Promise<any>((res, rej) => {
      const i = ++id;
      waiting.set(i, (m) => (m.error ? rej(new Error(m.error.message)) : res(m.result)));
      conn.write(enc.encode(JSON.stringify({ jsonrpc: "2.0", id: i, method, params }) + "\n"));
    });

  const dec = new TextDecoder();
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
        } else onNotify(m.method, m.params);
      }
    }
  })();

  const p = await call("project.open", { folder: args.folder });
  me = p.me?.user_id ?? me;
  const st = await call("project.status", { project_id: p.project_id });
  out(C.dim(`taudot activity · ${p.folder}\n`));
  await call("activity.subscribe", { project_id: p.project_id, since_seq: 0 });
  applyStatus(st);
  const poll = setInterval(async () => {
    try {
      applyStatus(await call("project.status", { project_id: p.project_id }));
    } catch { /* closed */ }
  }, 1000);
  try {
    await reader;
  } finally {
    clearInterval(poll);
  }
}

let me = "u-me";
function applyStatus(st: { connection: string; users: any[]; docs: { unconfirmed: number }[] }) {
  summary = {
    connection: st.connection,
    users: (st.users ?? []).filter((u) => u.user_id !== me),
    unconfirmed: (st.docs ?? []).reduce((n, d) => n + (d.unconfirmed ?? 0), 0),
  };
  const who = summary.users.map((u) => u.initials).join(" ");
  if (st.connection === "offline" || st.connection === "readonly") {
    status("blocked", st.connection === "readonly" ? "read-only: protocol mismatch, edits kept" : "offline");
  } else if (st.connection === "connecting" || summary.unconfirmed > 0) {
    status("working", summary.unconfirmed ? `${summary.unconfirmed} edits unconfirmed` : "connecting");
  } else {
    status("idle", who ? `in sync, with ${who}` : "in sync");
  }
}

function onNotify(method: string, p: any) {
  if (method === "activity") out(line(p));
  if (method === "project.connection") applyStatus({ ...summary, connection: p.connection, docs: [] } as any);
}

while (true) {
  try {
    await session();
    out(C.dim("engine closed the connection\n"));
  } catch (e) {
    if (lastStatus.startsWith("blocked") === false) out(C.dim(`waiting for the engine at ${socket} (${(e as Error).message})\n`));
  }
  status("blocked", "engine not running");
  await new Promise((r) => setTimeout(r, 2000));
}
