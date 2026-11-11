// taudot mock engine.
//
//   deno run -A main.ts --folder DIR [--socket PATH] [--bot] [--bot-interval MS] [--bot-char MS] [--bot-rounds N] [--latency MS]
//
// Listens on the socket (default ~/.taudot/engine.sock), writes engine.json beside it, logs every applied edit to
// stdout.

import { parseArgs } from "jsr:@std/cli@1/parse-args";
import { dirname, join } from "jsr:@std/path@1";
import { type Conn, Engine, RpcError } from "./engine.ts";
import { runBot } from "./bot.ts";
import { seedReview } from "./synthetic.ts";

const args = parseArgs(Deno.args, {
  string: ["folder", "socket", "bot-interval", "bot-char", "latency", "bot-doc", "bot-rounds", "synthetic-review"],
  boolean: ["bot", "help"],
});

if (args.help || !args.folder) {
  console.log(
    "usage: main.ts --folder DIR [--socket PATH] [--bot] [--bot-interval MS] [--bot-char MS] [--bot-doc PATH] [--bot-rounds N] [--synthetic-review CHANGES,COMMENTS] [--latency MS]",
  );
  Deno.exit(args.help ? 0 : 2);
}

const socket = args.socket ?? join(Deno.env.get("HOME") ?? ".", ".taudot", "engine.sock");
const stamp = () => {
  const d = new Date();
  return `${d.toTimeString().slice(0, 8)}.${String(d.getMilliseconds()).padStart(3, "0")}`;
};
const log = (line: string) => console.log(`${stamp()} ${line}`);

const engine = new Engine({ folder: args.folder, latencyMs: Number(args.latency ?? 0), log });
await engine.load();
engine.watchDisk();  // files edited on disk reach the editors (source "disk"), as with the real engine
if (args["synthetic-review"]) {
  const [c, k] = String(args["synthetic-review"]).split(",").map(Number);
  seedReview(engine, c || 0, k || 0);
}

await Deno.mkdir(dirname(socket), { recursive: true });
try {
  await Deno.remove(socket);
} catch { /* not there */ }
const listener = Deno.listen({ transport: "unix", path: socket });
const stateFile = join(dirname(socket), "engine.json");
await Deno.writeTextFile(
  stateFile,
  JSON.stringify({ pid: Deno.pid, socket, api_level: 0, version: "mock-0.1", folder: engine.folder }) + "\n",
);
log(`listening on ${socket}`);

function cleanup() {
  try {
    Deno.removeSync(socket);
    Deno.removeSync(stateFile);
  } catch { /* gone */ }
  Deno.exit(0);
}
Deno.addSignalListener("SIGINT", cleanup);
Deno.addSignalListener("SIGTERM", cleanup);

if (args.bot) {
  runBot(engine, {
    intervalMs: Number(args["bot-interval"] ?? 3000),
    charMs: Number(args["bot-char"] ?? 90),
    path: args["bot-doc"],
    rounds: args["bot-rounds"] ? Number(args["bot-rounds"]) : undefined,
  }).catch((e) => log(`bot stopped: ${e}`));
}

let nextId = 0;
for await (const sock of listener) serve(sock);

async function serve(sock: Deno.Conn) {
  const enc = new TextEncoder();
  let writing = Promise.resolve();
  const conn: Conn = {
    id: ++nextId,
    activity: false,
    project: false,
    queue: Promise.resolve(),
    send(msg) {
      const bytes = enc.encode(JSON.stringify(msg) + "\n");
      writing = writing.then(async () => {
        let off = 0;
        while (off < bytes.length) off += await sock.write(bytes.subarray(off));
      }).catch(() => {});
    },
  };
  engine.conns.add(conn);
  log(`client ${conn.id} connected`);

  const dec = new TextDecoder();
  let buf = "";
  try {
    for await (const chunk of sock.readable) {
      buf += dec.decode(chunk, { stream: true });
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (line) conn.queue = conn.queue.then(() => dispatch(conn, line));
      }
    }
  } catch (e) {
    log(`client ${conn.id} read error: ${e}`);
  }
  engine.conns.delete(conn);
  for (const d of engine.docs.values()) d.subscribers.delete(conn);
  log(`client ${conn.id} disconnected`);
}

async function dispatch(conn: Conn, line: string) {
  let msg: { id?: number | string; method?: string; params?: Record<string, unknown> };
  try {
    msg = JSON.parse(line);
  } catch {
    conn.send({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } });
    return;
  }
  try {
    const result = await engine.handle(conn, String(msg.method), msg.params ?? {});
    if (msg.id !== undefined) conn.send({ jsonrpc: "2.0", id: msg.id, result });
  } catch (e) {
    const code = e instanceof RpcError ? e.code : -32603;
    log(`error in ${msg.method}: ${e instanceof Error ? e.message : e}`);
    if (msg.id !== undefined) conn.send({ jsonrpc: "2.0", id: msg.id, error: { code, message: String(e) } });
  }
}
