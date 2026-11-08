#!/usr/bin/env node
// Astral characters (emoji, 𝔸) in both formats (ot-core round 1, Blocked 2; principle 7).
//  1. Typed with the keyboard into Overleaf's browser editor: what the applyOtUpdate frame carries, and what the
//     server stores.
//  2. Sent raw by a socket client: classic stores U+FFFD per surrogate, history-ot refuses with an otUpdateError.
// Run with --classic or --history-ot (default both).
import { Check, client, cookieFor, env, joined, project, sleep } from './common.ts'
import { OverleafEditor } from '../lib/overleaf.ts'
import { joinedText } from '../lib/socket.ts'

const EMOJI = '😀'
const FFFD2 = '��'
const kinds = ['classic', 'history-ot'].filter(k => !process.argv.slice(2).length || process.argv.includes('--' + k))
const check = new Check('emoji')

for (const kind of kinds) {
  const pid = project(`protocol ${kind}`, { historyOt: kind === 'history-ot' })

  // 1. Browser, keyboard.
  const ed = new OverleafEditor(env.url)
  await ed.launch({ trace: true })
  try {
    await ed.useCookie(await cookieFor(1))
    await ed.open(pid, 'main.tex')
    await ed.edit([{ pos: 0, text: `x${EMOJI}y` }], 'keys')
    let settled = 'ok'
    try {
      await ed.settle(500, 10_000)
    } catch (e) {
      settled = String(e).slice(0, 200)
    }
    // Is the editor still alive? Type one more plain letter.
    const sends = () => ed.frames.filter(f => f.dir === 'sent' && f.data.includes('applyOtUpdate')).length
    const sentBefore = sends()
    await ed.edit([{ pos: 0, text: 'z' }], 'keys')
    await sleep(4000)
    const sentAfterZ = sends() - sentBefore
    check.note(`${kind}.settle`, settled)
    check.note(`${kind}.pageErrors`, ed.pageErrors)
    check.note(`${kind}.sentAfterZ`, sentAfterZ)
    const sent = ed.frames
      .filter(f => f.dir === 'sent' && f.data.includes('applyOtUpdate'))
      .map(f => JSON.parse(f.data.replace(/^5:\d*\+?::/, '')).args[1].op)
    const browser = await ed.text()
    const a = await client(2, pid)
    const server = (await joined(a, 'main.tex')).text
    a.close()
    check.note(`${kind}.browserSent`, JSON.stringify(sent))
    check.note(`${kind}.browserSentAstral`, /[\uD800-\uDFFF]/.test(JSON.stringify(sent)))
    check.note(`${kind}.browserErrors`, ed.serverErrors())
    check.note(`${kind}.serverStartsWith`, JSON.stringify(server.slice(0, 5)))
    check.note(`${kind}.browserStartsWith`, JSON.stringify(browser.slice(0, 5)))
    check.that(!/[\uD800-\uDFFF]/.test(server), `${kind}: no surrogates reach the server`)
    if (kind === 'classic') {
      check.that(server.startsWith(`zx${FFFD2}y`), 'classic: typed emoji lands as two U+FFFD')
      check.that(browser === server, 'classic: browser equals server')
      check.that(ed.pageErrors.length === 0, 'classic: no page errors')
    } else {
      // Overleaf CE 6.3.0 bug, docs/protocol.md "Astral characters": the browser's history-ot doc throws and stops
      // sending. These checks fail once Overleaf fixes it, so the doc gets updated.
      check.that(ed.pageErrors.some(e => e.includes('ApplyError')), 'history-ot: browser throws ApplyError (known bug)')
      check.that(sentAfterZ === 0, 'history-ot: browser sends nothing after the emoji (known bug)')
    }
  } finally {
    await ed.close()
  }

  // 2. Raw socket client.
  const c = await client(1, pid)
  const j = await joined(c, 'main.tex')
  const op = kind === 'history-ot' ? [{ textOperation: [EMOJI, j.text.length] }] : [{ p: 0, i: EMOJI }]
  const ackErr = await c.applyOtUpdate(j.docId, { doc: j.docId, op, v: j.version })
  await sleep(1500)
  const errs = c.errors().map(e => e.args)
  check.note(`${kind}.rawAckError`, ackErr)
  check.note(`${kind}.rawErrors`, errs)
  const d = await client(2, pid)
  const after = (await joined(d, 'main.tex')).text
  d.close()
  c.close()
  check.note(`${kind}.rawStoredAs`, JSON.stringify(after.slice(0, 2)))
  if (kind === 'classic') {
    check.that(after.startsWith(FFFD2), 'classic: raw emoji stored as two U+FFFD')
    check.that(errs.length === 0, 'classic: no error for a raw emoji')
  } else {
    check.that(after === j.text, 'history-ot: raw emoji not applied')
    check.that(JSON.stringify(errs).includes('non BMP'), 'history-ot: otUpdateError about non BMP characters')
  }
}
check.done()
