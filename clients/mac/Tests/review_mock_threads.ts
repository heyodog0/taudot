// deno run -A review_mock_threads.ts SOCKET: the mock engine's thread.list (with each thread's start, end, text).
const conn = await Deno.connect({ transport: "unix", path: Deno.args[0] });
await conn.write(new TextEncoder().encode(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "thread.list", params: {} }) + "\n"));
const buf = new Uint8Array(1 << 20);
let s = "";
while (!s.includes("\n")) {
  const n = await conn.read(buf);
  if (n === null) break;
  s += new TextDecoder().decode(buf.subarray(0, n));
}
for (const line of s.split("\n")) {
  if (!line) continue;
  const m = JSON.parse(line);
  if (m.id === 1) { console.log(JSON.stringify(m.result ?? m.error)); break; }
}
conn.close();
