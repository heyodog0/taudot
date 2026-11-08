#!/usr/bin/env node
// Bob, the other user in tests/ce_review.lua: Overleaf's own editor in Chromium (the harness) for his cursor and
// typing, and a raw socket connection for what CE's editor can't do (it has no review panel): a comment range and
// tracked changes. One JSON command per line on stdin, one JSON reply per line on stdout. On a history-ot doc the raw
// ops are history-ot ones and positions count over the full content (tracked-deleted text included).
//
//   {"cmd":"open","project":"<id>","file":"main.tex"}
//   {"cmd":"cursor","pos":N}                      move the browser's cursor (UTF-16 index)
//   {"cmd":"type","pos":N,"text":"..."}           type in the browser and wait for the server
//   {"cmd":"comment","pos":N,"len":L,"thread":"<24 hex>"}
//   {"cmd":"track_insert","pos":N,"text":"...","tc":"<18 hex>"}
//   {"cmd":"track_delete","pos":N,"len":L,"tc":"<18 hex>"}
//   {"cmd":"server"}                              the server's text and ranges (fresh joinDoc)
//   {"cmd":"reopen","project":"<id>","file":"main.tex"}   reload the editor page; its text
//   {"cmd":"close"}
import { createInterface } from 'node:readline'
import { browser, client, env, joined } from '../../../harness/tests/common.ts'
import type { RealtimeClient } from '../../../harness/lib/socket.ts'

let ed: Awaited<ReturnType<typeof browser>> | undefined
let raw: RealtimeClient | undefined
let docId = ''

async function version(): Promise<{ v: number; text: string; hot: boolean }> {
  const j = await raw!.joinDoc(docId)
  const hot = j.type === 'history-ot'
  return { v: j.version, text: hot ? j.lines.content : j.lines.join('\n'), hot }
}

const tracking = (type: string) => ({ type, userId: env.users[1].id, ts: new Date().toISOString() })
const textOp = (pos: number, mid: any, rest: number) => [{ textOperation: [...(pos ? [pos] : []), mid, ...(rest ? [rest] : [])] }]

// Send a raw update and wait until the server has applied it.
async function send(op: object[], meta?: object) {
  const { v } = await version()
  const n = raw!.events.length
  const err = await raw!.applyOtUpdate(docId, { doc: docId, op, v, ...(meta ? { meta } : {}) })
  if (err) throw new Error(JSON.stringify(err))
  await raw!.waitEvent(e => e.name === 'otUpdateApplied' && e.args[0]?.doc === docId && !e.args[0]?.op, 10_000, n)
}

async function handle(c: any): Promise<object> {
  switch (c.cmd) {
    case 'open': {
      ed = await browser(2)
      await ed.open(c.project, c.file)
      raw = await client(2, c.project)
      docId = (await joined(raw, c.file)).docId
      return { docId }
    }
    case 'cursor':
      await ed!.page.evaluate((pos: number) => {
        const content = document.querySelector('.cm-content') as any
        const view = content?.cmView?.view ?? content?.cmView?.rootView?.view ?? content?.cmTile?.view
        view.focus()
        view.dispatch({ selection: { anchor: pos } })
      }, c.pos)
      return {}
    case 'type':
      await ed!.edit([{ pos: c.pos, text: c.text }])
      await ed!.settle()
      return {}
    case 'comment': {
      const { text, hot } = await version()
      if (hot) await send([{ commentId: c.thread, ranges: [{ pos: c.pos, length: c.len }] }])
      else await send([{ p: c.pos, c: text.slice(c.pos, c.pos + c.len), t: c.thread }])
      return {}
    }
    case 'track_insert': {
      const { text, hot } = await version()
      if (hot) await send(textOp(c.pos, { i: c.text, tracking: tracking('insert') }, text.length - c.pos))
      else await send([{ p: c.pos, i: c.text }], { tc: c.tc })
      return {}
    }
    case 'track_delete': {
      const { text, hot } = await version()
      if (hot) await send(textOp(c.pos, { r: c.len, tracking: tracking('delete') }, text.length - c.pos - c.len))
      else await send([{ p: c.pos, d: text.slice(c.pos, c.pos + c.len) }], { tc: c.tc })
      return { deleted: text.slice(c.pos, c.pos + c.len) }
    }
    case 'server': {
      const j = await raw!.joinDoc(docId)
      const hot = j.type === 'history-ot'
      return { text: hot ? j.lines.content : j.lines.join('\n'), ranges: hot ? j.lines : j.ranges, type: j.type, browser: await ed!.text() }
    }
    case 'reopen': {
      // A fresh editor page, for what the open one doesn't show live.
      const project = c.project
      await ed?.close()
      ed = await browser(2)
      await ed.open(project, c.file)
      return { browser: await ed.text() }
    }
    case 'close':
      raw?.close()
      await ed?.close()
      setTimeout(() => process.exit(0), 100)
      return {}
  }
  throw new Error(`unknown cmd ${c.cmd}`)
}

const rl = createInterface({ input: process.stdin })
for await (const line of rl) {
  if (!line.trim()) continue
  try {
    // The raw socket's acks have no timeout (a dropped connection never answers): cap each command, so the caller
    // gets an error reply instead of waiting on a reply that never comes.
    const c = JSON.parse(line)
    const limit = c.cmd === 'open' || c.cmd === 'reopen' ? 80_000 : 40_000
    let timer: NodeJS.Timeout | undefined
    const r = await Promise.race([
      handle(c),
      new Promise<never>((_, no) => { timer = setTimeout(() => no(new Error(`${c.cmd}: no answer in ${limit / 1000}s`)), limit) }),
    ]).finally(() => clearTimeout(timer))
    process.stdout.write(JSON.stringify({ ok: true, ...r }) + '\n')
  } catch (e) {
    process.stdout.write(JSON.stringify({ ok: false, error: String(e) }) + '\n')
  }
}
