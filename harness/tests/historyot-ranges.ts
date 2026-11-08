#!/usr/bin/env node
// How CE's history-ot server moves comments and tracked changes (observations for crates/ot2 history::FileData and
// docs/protocol.md). Each case is a fresh doc in one throwaway project: the ops are sent one after another, then
// joinDoc's snapshot is printed. `--json` prints {case: {ops, snapshot | error}}.
import { Check, client, env, project } from './common.ts'

const T = '0123456789abcdefghij'
const L = T.length
const u1 = env.users[0].id
const u2 = env.users[1].id
let n = 0
const ts = () => new Date(Date.UTC(2026, 0, 1, 0, 0, n++)).toISOString()
const ins = (userId = u1) => ({ type: 'insert', userId, ts: ts() })
const del = (userId = u1) => ({ type: 'delete', userId, ts: ts() })
const none = { type: 'none' }
const tx = (...ops: any[]) => [{ textOperation: ops }]
let caseNo = 0
const cid = (k: number) => `6ae7f0000000000000${String(caseNo).padStart(4, '0')}${String(k).padStart(2, '0')}`

// Each case: list of updates (each a list of edit operations), applied in order to a doc holding T.
export const cases: Record<string, () => any[][]> = {
  commentInsertAtStart: () => [[{ commentId: cid(1), ranges: [{ pos: 5, length: 5 }] }], tx(5, 'X', L - 5)],
  commentInsertInside: () => [[{ commentId: cid(1), ranges: [{ pos: 5, length: 5 }] }], tx(7, 'X', L - 7)],
  commentInsertAtEnd: () => [[{ commentId: cid(1), ranges: [{ pos: 5, length: 5 }] }], tx(10, 'X', L - 10)],
  commentRemoveOverStart: () => [[{ commentId: cid(1), ranges: [{ pos: 5, length: 5 }] }], tx(3, -4, L - 7)],
  commentRemoveOverEnd: () => [[{ commentId: cid(1), ranges: [{ pos: 5, length: 5 }] }], tx(7, -5, L - 12)],
  commentRemoveAll: () => [[{ commentId: cid(1), ranges: [{ pos: 5, length: 5 }] }], tx(5, -5, L - 10)],
  commentRemoveAround: () => [[{ commentId: cid(1), ranges: [{ pos: 5, length: 5 }] }], tx(4, -7, L - 11)],
  commentTwoRanges: () => [[{ commentId: cid(1), ranges: [{ pos: 2, length: 3 }, { pos: 10, length: 2 }] }], tx(7, 'X', L - 7)],
  commentResolveThenDelete: () => [[{ commentId: cid(1), ranges: [{ pos: 5, length: 5 }] }], [{ commentId: cid(1), resolved: true }]],
  commentDelete: () => [[{ commentId: cid(1), ranges: [{ pos: 5, length: 5 }] }], [{ deleteComment: cid(1) }]],
  commentAddTwice: () => [[{ commentId: cid(1), ranges: [{ pos: 5, length: 5 }] }], [{ commentId: cid(1), ranges: [{ pos: 1, length: 2 }] }]],
  commentInsertWithIds: () => [[{ commentId: cid(1), ranges: [{ pos: 5, length: 5 }] }], tx(12, { i: 'XY', commentIds: [cid(1)] }, L - 12)],
  commentUnderTrackedDelete: () => [[{ commentId: cid(1), ranges: [{ pos: 5, length: 5 }] }], tx(5, { r: 5, tracking: del() }, L - 10)],
  trackedInsert: () => [tx(5, { i: 'ABC', tracking: ins() }, L - 5)],
  trackedInsertPlainAtStart: () => [tx(5, { i: 'ABC', tracking: ins() }, L - 5), tx(5, 'X', L - 2)],
  trackedInsertPlainInside: () => [tx(5, { i: 'ABC', tracking: ins() }, L - 5), tx(6, 'X', L - 3)],
  trackedInsertPlainAtEnd: () => [tx(5, { i: 'ABC', tracking: ins() }, L - 5), tx(8, 'X', L - 5)],
  trackedInsertAdjacentSameUser: () => [tx(5, { i: 'ABC', tracking: ins() }, L - 5), tx(8, { i: 'DE', tracking: ins() }, L - 5)],
  trackedInsertBeforeSameUser: () => [tx(5, { i: 'ABC', tracking: ins() }, L - 5), tx(5, { i: 'DE', tracking: ins() }, L - 2)],
  trackedInsertInsideOtherUser: () => [tx(5, { i: 'ABC', tracking: ins() }, L - 5), tx(6, { i: 'DE', tracking: ins(u2) }, L - 3)],
  trackedInsertRemovePart: () => [tx(5, { i: 'ABC', tracking: ins() }, L - 5), tx(6, -1, L - 4)],
  trackedInsertThenTrackedDelete: () => [tx(5, { i: 'ABC', tracking: ins() }, L - 5), tx(5, { r: 3, tracking: del() }, L - 5)],
  trackedInsertAccept: () => [tx(5, { i: 'ABC', tracking: ins() }, L - 5), tx(5, { r: 3, tracking: none }, L - 5)],
  trackedDelete: () => [tx(5, { r: 3, tracking: del() }, L - 8)],
  trackedDeletePlainAtStart: () => [tx(5, { r: 3, tracking: del() }, L - 8), tx(5, 'X', L - 5)],
  trackedDeletePlainInside: () => [tx(5, { r: 3, tracking: del() }, L - 8), tx(6, 'X', L - 6)],
  trackedDeletePlainAtEnd: () => [tx(5, { r: 3, tracking: del() }, L - 8), tx(8, 'X', L - 8)],
  trackedDeleteAdjacentSameUser: () => [tx(5, { r: 3, tracking: del() }, L - 8), tx(8, { r: 2, tracking: del() }, L - 10)],
  trackedDeleteRejectPart: () => [tx(5, { r: 5, tracking: del() }, L - 10), tx(6, { r: 2, tracking: none }, L - 8)],
  trackedDeleteAcceptPart: () => [tx(5, { r: 5, tracking: del() }, L - 10), tx(6, -2, L - 8)],
  trackedDeleteOverlapOtherUser: () => [tx(5, { r: 3, tracking: del() }, L - 8), tx(6, { r: 4, tracking: del(u2) }, L - 10)],
  trackedDeleteOverTrackedInsertOtherUser: () => [tx(5, { i: 'ABC', tracking: ins() }, L - 5), tx(5, { r: 3, tracking: del(u2) }, L - 5)],
  trackedInsertDeletedBySameUser: () => [tx(5, { i: 'ABC', tracking: ins() }, L - 5), tx(6, { r: 1, tracking: del() }, L - 4)],
  trackedInsertAfterTrackedDelete: () => [tx(5, { r: 3, tracking: del() }, L - 8), tx(8, { i: 'XY', tracking: ins() }, L - 8)],
  trackedInsertBeforeTrackedDelete: () => [tx(5, { r: 3, tracking: del() }, L - 8), tx(5, { i: 'XY', tracking: ins() }, L - 5)],
  trackedInsertAdjacentOtherUser: () => [tx(5, { i: 'ABC', tracking: ins() }, L - 5), tx(8, { i: 'DE', tracking: ins(u2) }, L - 5)],
  removeAcrossTrackedDelete: () => [tx(5, { r: 3, tracking: del() }, L - 8), tx(3, -7, L - 10)],
  trackedDeleteWithComment: () => [tx(2, { r: 3, tracking: del() }, L - 5), [{ commentId: cid(1), ranges: [{ pos: 1, length: 6 }] }], tx(3, 'X', L - 3)],
  insertTrackedNoneIgnored: () => [tx(5, { i: 'Q', tracking: none }, L - 5)],
  trackedInsertSplitThenRejoined: () => [tx(5, { i: 'ABC', tracking: ins() }, L - 5), tx(6, 'X', L - 3), tx(6, -1, L - 3)],
  commentSplitThenRejoined: () => [[{ commentId: cid(1), ranges: [{ pos: 5, length: 5 }] }], tx(7, 'X', L - 7), tx(7, -1, L - 7)],
  trackedDeleteSameUserTwoSides: () => [tx(5, { r: 2, tracking: del() }, L - 7), tx(8, { r: 2, tracking: del() }, L - 10), tx(7, { r: 1, tracking: del() }, L - 8)],
  trackedInsertWithCommentIdsInside: () => [[{ commentId: cid(1), ranges: [{ pos: 5, length: 5 }] }], tx(7, { i: 'XY', tracking: ins(), commentIds: [cid(1)] }, L - 7)],
  trackedInsertUntrackedRetainNoTracking: () => [tx(5, { i: 'ABC', tracking: ins() }, L - 5), tx(L + 3)],
}

const json = process.argv.includes('--json')
const only = process.argv.find(a => a.startsWith('--only='))?.slice(7)
const pid = project('protocol history-ot ranges', { historyOt: true, reset: true })
let a = await client(1, pid)
const docId = a.project.rootFolder[0].docs.find((d: any) => d.name === 'main.tex')._id
const out: Record<string, any> = {}
for (const [name, build] of Object.entries(cases)) {
  if (only && name !== only) continue
  caseNo++
  const updates = build()
  const j0 = await a.joinDoc(docId)
  let v = j0.version as number
  const send = async (op: any[]) => {
    const before = a.confirmations(docId).length
    const err = await a.applyOtUpdate(docId, { doc: docId, op, v })
    if (err) throw new Error(JSON.stringify(err))
    await a.waitEvent(() => a.confirmations(docId).length > before || a.errors().length > 0, 10_000)
    if (a.errors().length) throw new Error(JSON.stringify(a.errors().at(-1)!.args))
    v++
  }
  try {
    // Start from T with no ranges of this case's IDs (earlier cases' comments may linger, emptied).
    const len = (j0.lines.content as string).length
    await send(tx(...(len ? [-len] : []), T))
    for (const u of updates) await send(u)
    const j = await a.joinDoc(docId)
    const snap = j.lines
    const mine = (snap.comments ?? []).filter((c: any) => c.id.startsWith(cid(0).slice(0, 22)))
    out[name] = { updates, content: snap.content, comments: mine, trackedChanges: snap.trackedChanges ?? [] }
  } catch (e) {
    out[name] = { updates, error: String(e) }
    a.close()
    a = await client(1, pid)
  }
  if (!json) {
    const { updates: _, ...rest } = out[name]
    console.log(name, JSON.stringify(rest))
  }
}
if (json) console.log(JSON.stringify(out, null, 1))
a.close()
process.exit(0)
