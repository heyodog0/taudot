// Bob types through his own Taudot engine (as CE user2), one character per edit at a human pace, with his cursor
// following, so each keystroke reaches Overleaf and the other clients on its own (the browser editor batches).
//   node site/demo/bobtype.mjs ENGINE_SOCK PROJECT_ID FILE AFTER TEXT
import net from 'node:net'
import { createInterface } from 'node:readline'
const [sock, project, path, after, text] = process.argv.slice(2)
const c = net.createConnection(sock)
const pending = new Map(); let id = 0
createInterface({ input: c }).on('line', l => {
  const m = JSON.parse(l)
  if (m.id !== undefined && pending.has(m.id)) { const [ok, ko] = pending.get(m.id); pending.delete(m.id); m.error ? ko(new Error(JSON.stringify(m.error))) : ok(m.result) }
})
const call = (method, params) => new Promise((ok, ko) => { const i = ++id; pending.set(i, [ok, ko]); c.write(JSON.stringify({ jsonrpc: '2.0', id: i, method, params }) + '\n') })
const sleep = ms => new Promise(r => setTimeout(r, ms))
await call('project.open', { project_id: project, ...(process.env.FOLDER ? { folder: process.env.FOLDER } : {}) })
const d = await call('doc.open', { project_id: project, path })
let pos = d.text.indexOf(after)
if (pos < 0) throw new Error(`no "${after}"`)
pos += after.length
let seq = d.seq
await call('presence.cursor', { doc_id: d.doc_id, pos, seq })
console.log('ready')
await sleep(Number(process.env.WAIT || 0))
for (const ch of text) {
  const r = await call('doc.edit', { doc_id: d.doc_id, seq, edits: [{ pos, del: 0, ins: ch }] })
  seq = r.seq; pos += ch.length
  call('presence.cursor', { doc_id: d.doc_id, pos, seq }).catch(() => {})
  await sleep(70 + Math.random() * 70 + (ch === ' ' ? 40 : 0) + (/[,.]/.test(ch) ? 160 : 0))
}
await sleep(400)
console.log('done')
c.end()
