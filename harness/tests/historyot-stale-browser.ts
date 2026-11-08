#!/usr/bin/env node
// history-ot: does Overleaf's own browser editor survive a concurrent op? A browser edits and is confirmed (server at
// v0 + 1), then a raw client sends an op made at v0, as a collaborator typing at the same moment would. The server
// transforms it and broadcasts it with v = v0 (see historyot-version.ts). The browser's sharejs Doc drops ops with
// v below its version, so we expect it to miss the edit and drift from the server.
import { Check, client, cookieFor, env, joined, project, sleep } from './common.ts'
import { OverleafEditor } from '../lib/overleaf.ts'
import { joinedText } from '../lib/socket.ts'

const kind = process.argv.includes('--classic') ? 'classic' : 'history-ot'
const check = new Check(`stale-op-browser-${kind}`)
const pid = project(`protocol stale ${kind}`, { historyOt: kind === 'history-ot', reset: true })
const ed = new OverleafEditor(env.url)
await ed.launch({ trace: true })
try {
  await ed.useCookie(await cookieFor(2))
  await ed.open(pid, 'main.tex')
  const a = await client(1, pid)
  const ja = await joined(a, 'main.tex')
  const v0 = ja.version
  check.note('type', ja.type)

  // Browser edit, confirmed: server now at v0 + 1.
  await ed.edit([{ pos: 0, text: 'B' }])
  await ed.settle()

  // Stale op from A, made at v0: append "A".
  const op = kind === 'history-ot' ? [{ textOperation: [ja.text.length, 'A'] }] : [{ p: ja.text.length, i: 'A' }]
  await a.applyOtUpdate(ja.docId, { doc: ja.docId, op, v: v0 })
  await a.waitEvent(e => e.name === 'otUpdateApplied' && e.args[0]?.doc === ja.docId && !e.args[0]?.op)
  await sleep(1500)

  const server = joinedText(await a.joinDoc(ja.docId))
  const browser = await ed.text()
  const got = ed.frames.filter(f => f.dir === 'recv' && f.data.includes('otUpdateApplied') && f.data.includes('"op"'))
  check.note('confirmToA', a.confirmations(ja.docId).map(e => e.args[0].v))
  check.note('broadcastToBrowser', got.map(f => JSON.parse(f.data.replace(/^5:::/, '')).args[0].v))
  check.note('serverEndsWith', JSON.stringify(server.slice(-3)))
  check.note('browserEndsWith', JSON.stringify(browser.slice(-3)))
  check.note('browserInSync', browser === server)

  // One more browser edit: does the server notice the drift (hash, or an op that no longer fits)?
  await ed.edit([{ pos: 1, text: 'C' }])
  try {
    await ed.settle()
    check.note('nextEdit', 'confirmed')
  } catch (e) {
    check.note('nextEdit', String(e).slice(0, 300))
  }
  check.note('serverErrorsAfter', ed.serverErrors())
  if (kind === 'classic') check.that(browser === server, 'classic: browser stays in sync after a concurrent op')
  // Overleaf CE 6.3.0 bug, docs/protocol.md "history-ot versions": fails once Overleaf fixes it.
  else check.that(browser !== server && !browser.endsWith('A'), 'history-ot: browser misses the concurrent op (known bug)')
  a.close()
} finally {
  await ed.close()
}
check.done()
