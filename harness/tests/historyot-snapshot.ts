#!/usr/bin/env node
// history-ot joinDoc snapshot with a comment and tracked changes (ot-core round 1, Blocked 3 and 4), on a fresh
// file so positions are known:
//  - what joinDoc returns (first value: {content, comments?, trackedChanges?}; ranges; type)
//  - whether content keeps tracked-deleted text and op positions count over it
//  - what Overleaf's browser shows for the same doc (deleted text hidden) and where a later insert lands
import { mkdtempSync, writeFileSync, mkdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Check, client, cookieFor, env, joined, project, sleep } from './common.ts'
import { OverleafEditor } from '../lib/overleaf.ts'

const check = new Check('historyot-snapshot')
const dir = mkdtempSync(join(tmpdir(), 'taudot-snap-'))
writeFileSync(join(dir, 'main.tex'), 'hello brave new world\n')
const pid = project('protocol history-ot snapshot', { historyOt: true, reset: true, from: dir })
const a = await client(1, pid)
const j = await joined(a, 'main.tex')
check.note('joinFirstValue', j.lines)
check.that(j.type === 'history-ot', `type ${j.type}`)
let v = j.version
const text = j.text // "hello brave new world\n"
const L = text.length
const ts = new Date().toISOString()
const userId = env.users[0].id
const threadId = '6ae7f0000000000000000001'

// 1. Tracked delete of "brave " (6..12): a retain with delete tracking keeps the text.
// 2. Tracked insert "big " at 12 (counted over the full content, so after the deleted "brave ").
// 3. Comment on "world" (16+4=20..25 after the insert, over full content).
const send = async (op: any[]) => {
  const n = a.confirmations(j.docId).length
  const err = await a.applyOtUpdate(j.docId, { doc: j.docId, op, v })
  if (err) throw new Error(JSON.stringify(err))
  await a.waitEvent(() => a.confirmations(j.docId).length > n || a.errors().length > 0, 10_000)
  if (a.errors().length) throw new Error(JSON.stringify(a.errors()[0].args))
  v++
}
await send([{ textOperation: [6, { r: 6, tracking: { type: 'delete', userId, ts } }, L - 12] }])
await send([{ textOperation: [12, { i: 'big ', tracking: { type: 'insert', userId, ts } }, L - 12] }])
await send([{ commentId: threadId, ranges: [{ pos: 20, length: 5 }] }])

const b = await client(2, pid)
const after = await joined(b, 'main.tex')
check.note('joinAfter', { first: after.lines, ranges: after.ranges, version: after.version })
const content = after.lines.content as string
check.that(content === 'hello brave big new world\n', `content keeps tracked-deleted text: ${JSON.stringify(content)}`)
check.that(Array.isArray(after.lines.trackedChanges) && after.lines.trackedChanges.length === 2, 'two tracked changes in the snapshot')
check.that(Array.isArray(after.lines.comments) && after.lines.comments.length === 1, 'one comment in the snapshot')

// A plain insert "X" at full-content position 25 (after "world"): where does the browser show it?
await send([{ textOperation: [25, 'X', content.length - 25] }])
const ed = new OverleafEditor(env.url)
await ed.launch()
try {
  await ed.useCookie(await cookieFor(2))
  await ed.open(pid, 'main.tex')
  const shown = await ed.text()
  check.note('browserShows', shown)
  check.that(shown === 'hello big new worldX\n', `browser hides tracked-deleted text: ${JSON.stringify(shown)}`)
  // A browser edit at visible position 6 (before "big"): what position does it send?
  await ed.edit([{ pos: 6, text: 'Y' }])
  await ed.settle()
  await sleep(500)
  const fromBrowser = a.remoteOps(j.docId).at(-1)?.args[0].op
  check.note('browserSentForVisible6', fromBrowser)
  // At a tracked-delete boundary the browser places an insert before the deleted text (tracked-deletes.ts toSnapshot).
  check.that(JSON.stringify(fromBrowser) === JSON.stringify([{ textOperation: [6, 'Y', 21] }]), 'browser maps visible 6 to full-content 6, before the tracked delete')
} finally {
  await ed.close()
}
const final = await joined(b, 'main.tex')
check.note('finalContent', final.lines.content)
check.that(final.lines.content === 'hello Ybrave big new worldX\n', 'final content')
check.that(JSON.stringify(after.ranges) === '{}', 'history-ot sends ranges in the snapshot, the ranges value is empty')
for (const c of [a, b]) c.close()
check.done()
