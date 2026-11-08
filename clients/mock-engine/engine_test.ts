// End-to-end: start the mock on a temp socket, talk to it like a client, check a stale edit is transformed.
import { assertEquals } from "jsr:@std/assert@1";

async function rpcClient(path: string) {
  const conn = await Deno.connect({ transport: "unix", path });
  const enc = new TextEncoder(), dec = new TextDecoder();
  const notes: { method: string; params: Record<string, unknown> }[] = [];
  const waiting = new Map<number, (v: unknown) => void>();
  let id = 0, buf = "";
  (async () => {
    for await (const chunk of conn.readable) {
      buf += dec.decode(chunk, { stream: true });
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const m = JSON.parse(buf.slice(0, nl));
        buf = buf.slice(nl + 1);
        if (m.id !== undefined) waiting.get(m.id)?.(m.error ? Promise.reject(m.error) : m.result);
        else notes.push(m);
      }
    }
  })().catch(() => {});
  return {
    notes,
    call(method: string, params: unknown = {}): Promise<any> {
      const i = ++id;
      return new Promise((res) => {
        waiting.set(i, res);
        conn.write(enc.encode(JSON.stringify({ jsonrpc: "2.0", id: i, method, params }) + "\n"));
      });
    },
    close: () => conn.close(),
  };
}

Deno.test("two clients, stale edit is transformed", async () => {
  const dir = await Deno.makeTempDir({ prefix: "tsm" });
  await Deno.writeTextFile(`${dir}/main.tex`, "hello world\n");
  const sock = `${dir}/e.sock`;
  const proc = new Deno.Command(Deno.execPath(), {
    args: ["run", "-A", new URL("./main.ts", import.meta.url).pathname, "--folder", dir, "--socket", sock],
    stdout: "piped",
    stderr: "inherit",
  }).spawn();
  for (let i = 0; i < 100; i++) {
    try {
      await Deno.stat(sock);
      break;
    } catch {
      await new Promise((r) => setTimeout(r, 50));
    }
  }
  const a = await rpcClient(sock), b = await rpcClient(sock);
  try {
    assertEquals((await a.call("engine.info")).api_level, 0);
    const p = await a.call("project.open", { folder: dir });
    await b.call("project.open", { folder: dir });
    assertEquals(p.docs[0].path, "main.tex");
    const da = await a.call("doc.open", { project_id: p.project_id, path: "main.tex" });
    await a.call("doc.subscribe", { doc_id: da.doc_id, since_seq: da.seq });
    await b.call("doc.subscribe", { doc_id: da.doc_id, since_seq: da.seq });
    // both edit from seq 0
    const r1 = await a.call("doc.edit", { doc_id: da.doc_id, seq: 0, edits: [{ pos: 0, del: 5, ins: "goodbye" }] });
    const r2 = await b.call("doc.edit", { doc_id: da.doc_id, seq: 0, edits: [{ pos: 11, del: 0, ins: "!" }] });
    assertEquals([r1.seq, r2.seq], [1, 2]);
    const again = await a.call("doc.open", { project_id: p.project_id, path: "main.tex" });
    assertEquals(again.text, "goodbye world!\n");
    // a saw b's edit, transformed, and b saw a's
    const ca = a.notes.find((n) => n.method === "doc.changed")!;
    assertEquals(ca.params.edits, [{ pos: 13, del: 0, ins: "!" }]);
    const cb = b.notes.find((n) => n.method === "doc.changed")!;
    assertEquals(cb.params.edits, [{ pos: 0, del: 5, ins: "goodbye" }]);
    await new Promise((r) => setTimeout(r, 500));
    assertEquals(await Deno.readTextFile(`${dir}/main.tex`), "goodbye world!\n");
  } finally {
    a.close();
    b.close();
    proc.kill("SIGTERM");
    await proc.status;
    await proc.stdout.cancel();
  }
});

Deno.test("comments, threads and tracked changes", async () => {
  const dir = await Deno.makeTempDir({ prefix: "tsm" });
  await Deno.writeTextFile(`${dir}/main.tex`, "hello brave new world\n");
  const sock = `${dir}/e.sock`;
  const proc = new Deno.Command(Deno.execPath(), {
    args: ["run", "-A", new URL("./main.ts", import.meta.url).pathname, "--folder", dir, "--socket", sock],
    stdout: "piped",
    stderr: "inherit",
  }).spawn();
  for (let i = 0; i < 100; i++) {
    try {
      await Deno.stat(sock);
      break;
    } catch {
      await new Promise((r) => setTimeout(r, 50));
    }
  }
  const a = await rpcClient(sock);
  try {
    const p = await a.call("project.open", { folder: dir });
    await a.call("activity.subscribe", { project_id: p.project_id });
    const d = await a.call("doc.open", { project_id: p.project_id, path: "main.tex" });
    await a.call("doc.subscribe", { doc_id: d.doc_id, since_seq: d.seq });
    const c = await a.call("comment.add", { doc_id: d.doc_id, start: 6, end: 11, text: "why brave?" });
    await a.call("thread.reply", { project_id: p.project_id, thread_id: c.thread_id, text: "because" });
    await a.call("thread.resolve", { project_id: p.project_id, thread_id: c.thread_id });
    const list = await a.call("thread.list", { project_id: p.project_id });
    assertEquals(list.threads[0].text, "brave");
    assertEquals(list.threads[0].messages.map((m: any) => m.text), ["why brave?", "because"]);
    assertEquals(list.threads[0].resolved, true);
    assertEquals(await a.call("review.track", { project_id: p.project_id, on: true }), { on: true });
    let seq = (await a.call("doc.edit", { doc_id: d.doc_id, seq: c.seq, edits: [{ pos: 12, del: 4, ins: "" }] })).seq;
    seq = (await a.call("doc.edit", { doc_id: d.doc_id, seq, edits: [{ pos: 12, del: 0, ins: "old " }] })).seq;
    const r = await a.call("doc.ranges", { doc_id: d.doc_id });
    const kinds = r.ranges.map((x: any) => [x.kind, x.start, x.end, x.text]);
    assertEquals(kinds, [["comment", 6, 11, "brave"], ["tracked_delete", 16, 16, "new "], ["tracked_insert", 12, 16, "old "]]);
    await a.call("change.reject", { doc_id: d.doc_id, ids: r.ranges.filter((x: any) => x.kind !== "comment").map((x: any) => x.id) });
    assertEquals((await a.call("doc.open", { project_id: p.project_id, path: "main.tex" })).text, "hello brave new world\n");
    assertEquals((await a.call("doc.ranges", { doc_id: d.doc_id })).ranges.length, 1);
    await a.call("thread.delete", { project_id: p.project_id, thread_id: c.thread_id });
    assertEquals((await a.call("doc.ranges", { doc_id: d.doc_id })).ranges.length, 0);
    assertEquals(a.notes.some((n) => n.method === "thread.changed" && n.params.thread === null), true);
  } finally {
    a.close();
    proc.kill("SIGTERM");
    await proc.status;
    await proc.stdout.cancel();
  }
});
