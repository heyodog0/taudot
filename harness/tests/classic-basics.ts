#!/usr/bin/env node
// Classic (sharejs-text-ot) answers from round 1, as regression tests:
//  - op text is plain JSON text, only joinDoc lines are Latin-1 packed
//  - hash: git blob SHA-1 of the doc after the op, length in UTF-16 units; checked only when v is current
//  - strict schemas: an unknown field in an update is refused
//  - catch-up from a version the server no longer has: the error message
//  - a resend with dupIfSource is confirmed once, at the original op's version, and not applied twice
//  - a burst of ops without waiting is all confirmed (no rate limit)
import { createHash } from 'node:crypto'
import { Check, client, joined, project, sleep } from './common.ts'
import { shareJsHash } from '../lib/socket.ts'

const check = new Check('classic-basics')
const pid = project('protocol classic')
const PATH = 'sections/intro.tex'

const confirmOne = async (c: any, docId: string, n: number) =>
  c.waitEvent(() => c.confirmations(docId).length > n || c.errors().length > 0 || c.closed, 10_000).catch(() => {})

// Hash units and plain op text. Insert "é€�" (é, € are BMP; U+FFFD too), with a hash over UTF-16 length.
{
  const c = await client(1, pid)
  const j = await joined(c, PATH)
  const ins = 'é€�'
  const after = ins + j.text
  const err = await c.applyOtUpdate(j.docId, { doc: j.docId, op: [{ p: 0, i: ins }], v: j.version, hash: await shareJsHash(after) })
  await confirmOne(c, j.docId, 0)
  check.that(!err && c.confirmations(j.docId).length === 1 && c.errors().length === 0, 'plain op text with a UTF-16-length hash is confirmed')
  const back = await joined(c, PATH)
  check.that(back.text === after, 'server text equals ours after a plain (unpacked) insert')
  check.that(back.lines[0].includes('Ã©'), 'joinDoc lines are Latin-1 packed (é arrives as Ã©)')

  // Byte-length hash: refused with "Invalid hash" and a disconnect.
  const bytes = Buffer.byteLength('x' + after, 'utf8')
  const bad = createHash('sha1').update('blob ' + bytes + '\x00').update('x' + after, 'utf8').digest('hex')
  await c.applyOtUpdate(j.docId, { doc: j.docId, op: [{ p: 0, i: 'x' }], v: back.version, hash: bad })
  await confirmOne(c, j.docId, 1)
  await sleep(300)
  const errs = JSON.stringify(c.errors().map(e => e.args))
  check.note('byteHashErrors', c.errors().map(e => e.args[0]))
  check.that(errs.includes('Invalid hash'), 'a byte-length hash is refused with Invalid hash')
  c.close()
}

// Strict schema: unknown field.
{
  const c = await client(1, pid)
  const j = await joined(c, PATH)
  const ack = await Promise.race([
    c.emit('applyOtUpdate', j.docId, { doc: j.docId, op: [{ p: 0, i: 'q' }], v: j.version, extra: 1 }),
    sleep(5000).then(() => ['(no ack)']),
  ])
  await sleep(500)
  check.note('unknownFieldAck', ack[0])
  check.note('unknownFieldClosed', c.closed)
  check.that(ack[0] != null, 'an update with an unknown field is refused in the ack')
  const d = await client(2, pid)
  check.that((await joined(d, PATH)).version === j.version, 'and not applied')
  c.close()
  d.close()
}

// Catch-up from far behind. joinDoc(fromVersion) for a version older than the ops the server keeps.
{
  // The document updater keeps the last 100 ops for an hour (RedisManager DOC_OPS_MAX_LENGTH, DOC_OPS_TTL), so
  // push 120 more (the list is trimmed to 100 before each push, so 101 survive) and ask for the ops since the version before them.
  const c = await client(1, pid)
  const j0 = await joined(c, PATH)
  for (let k = 0; k < 120; k++) c.applyOtUpdate(j0.docId, { doc: j0.docId, op: [{ p: 0, i: 'k' }], v: j0.version + k })
  await c.waitEvent(() => c.confirmations(j0.docId).length >= 120 || c.errors().length > 0, 30_000).catch(() => {})
  const j = await joined(c, PATH)
  const [err] = await c.emit('joinDoc', j.docId, j0.version, { encodeRanges: true, supportsHistoryOT: true })
  const [err2, , , ops2] = await c.emit('joinDoc', j.docId, j.version - 1, { encodeRanges: true, supportsHistoryOT: true })
  check.note('catchUpFrom120Behind', err ?? 'ok')
  check.that(JSON.stringify(err ?? '').includes('could not load requested ops'), 'catch-up past the kept ops fails with "doc updater could not load requested ops"')
  check.note('catchUpFromVminus1', err2 ?? `ok, ${ops2?.length} ops`)
  check.that(err2 == null && ops2?.length === 1, 'catch-up from v-1 returns one op')
  c.close()
}

// dupIfSource: send, then resend from a new connection naming the first one.
{
  const c1 = await client(1, pid)
  const j = await joined(c1, PATH)
  const op = [{ p: 0, i: 'D' }]
  await c1.applyOtUpdate(j.docId, { doc: j.docId, op, v: j.version })
  await confirmOne(c1, j.docId, 0)
  const firstV = c1.confirmations(j.docId)[0]?.args[0].v
  c1.close()
  const c2 = await client(1, pid)
  const j2 = await joined(c2, PATH)
  // After a reconnect, catch-up from the op's version shows it was applied: its meta.source is our old connection.
  const since = await c2.joinDoc(j.docId, j.version)
  check.that(since.ops.some((u: any) => u.meta?.source === c1.publicId), 'catch-up ops carry meta.source, so a reconnecting client can tell its op was applied')
  await c2.applyOtUpdate(j2.docId, { doc: j2.docId, op, v: j.version, dupIfSource: [c1.publicId!, c2.publicId!] })
  await confirmOne(c2, j2.docId, 0)
  const dupV = c2.confirmations(j2.docId)[0]?.args[0].v
  const after = await joined(c2, PATH)
  check.note('dup', { firstV, dupV, versionBefore: j2.version, versionAfter: after.version })
  check.that(dupV === firstV, 'a duplicate is confirmed with the original op version')
  check.that(after.version === j2.version && after.text === j2.text, 'and not applied again')
  c2.close()
}

// Burst: 50 ops, each at the next version, without waiting.
{
  const c = await client(1, pid)
  const j = await joined(c, PATH)
  const t0 = Date.now()
  for (let k = 0; k < 50; k++) c.applyOtUpdate(j.docId, { doc: j.docId, op: [{ p: j.text.length + k, i: 'b' }], v: j.version + k })
  await c.waitEvent(() => c.confirmations(j.docId).length >= 50 || c.errors().length > 0, 30_000).catch(() => {})
  check.note('burst', { confirmed: c.confirmations(j.docId).length, ms: Date.now() - t0, errors: c.errors().length })
  check.that(c.confirmations(j.docId).length === 50 && c.errors().length === 0, 'a burst of 50 ops is all confirmed')
  c.close()
}
check.done()
