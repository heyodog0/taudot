#!/usr/bin/env node
// history-ot: what `v` the sender's confirmation and the others' broadcast carry when two clients send an op made
// at the same version (ot-core round 1, Blocked 1). HistoryOTUpdateManager.tryApplyUpdate transforms a stale op but
// never sets update.v to the version it was applied at.
import { Check, client, joined, project, sleep } from './common.ts'

const check = new Check('historyot-version')
const pid = project('protocol history-ot', { historyOt: true })
const a = await client(1, pid)
const b = await client(2, pid)
const ja = await joined(a, 'main.tex')
const jb = await joined(b, 'main.tex')
check.that(ja.type === 'history-ot', `type ${ja.type}`)
const v0 = ja.version
const len = ja.text.length
check.note('v0', v0)

// Both send against v0 without waiting: A appends, B prepends.
await Promise.all([
  a.applyOtUpdate(ja.docId, { doc: ja.docId, op: [{ textOperation: [len, 'A'] }], v: v0 }),
  b.applyOtUpdate(jb.docId, { doc: jb.docId, op: [{ textOperation: ['B', len] }], v: v0 }),
])
await sleep(1500)
const ackA = a.confirmations(ja.docId).map(e => e.args[0].v)
const ackB = b.confirmations(jb.docId).map(e => e.args[0].v)
const atA = a.remoteOps(ja.docId).map(e => ({ v: e.args[0].v, op: e.args[0].op }))
const atB = b.remoteOps(jb.docId).map(e => ({ v: e.args[0].v, op: e.args[0].op }))
check.note('confirmA', ackA)
check.note('confirmB', ackB)
check.note('broadcastToA', atA)
check.note('broadcastToB', atB)
check.note('errors', [...a.errors(), ...b.errors()].map(e => e.args))

// What the server stored: a fresh join and a catch-up from v0.
const c = await client(1, pid)
const full = await joined(c, 'main.tex')
const since = await c.joinDoc(ja.docId, v0)
check.note('versionAfter', full.version)
check.note('catchUpOps', since.ops.map((u: any) => ({ v: u.v, op: u.op })))
check.that(full.version === v0 + 2, `version after two ops: ${full.version}, want ${v0 + 2}`)
check.that(full.text === 'B' + ja.text + 'A', 'both edits applied once')

// The answer we expect if Overleaf numbers ops by where they were applied (sharejs behaviour):
// first-applied op confirmed at v0, the second at v0 + 1.
const vs = [...ackA, ...ackB].sort()
check.note('sharejsStyle', JSON.stringify(vs) === JSON.stringify([v0, v0 + 1]))
for (const c2 of [a, b, c]) c2.close()
check.done()
