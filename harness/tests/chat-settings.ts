#!/usr/bin/env node
// Project chat and settings changes made over REST, and the socket events others get
// (services/web/app/src/router.mjs, Features/Chat/ChatController.mjs, Features/Editor/EditorController.mjs).
import { Check, client, cookieFor, env, project } from './common.ts'

const check = new Check('chat-settings')
const pid = project('protocol entities')
const listener = await client(2, pid)
const cookie = await cookieFor(1)
const page = await (await fetch(`${env.url}/project/${pid}`, { headers: { cookie } })).text()
const csrf = page.match(/name="ol-csrfToken" content="([^"]*)"/)?.[1]!
const post = async (path: string, body: object) => {
  const res = await fetch(`${env.url}/project/${pid}${path}`, {
    method: 'POST',
    headers: { cookie, 'x-csrf-token': csrf, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })
  return res.status
}
const seen = async (name: string, from: number) => (await listener.waitEvent(e => e.name === name, 10_000, from)).args

let n = listener.events.length
check.note('chatStatus', await post('/messages', { content: 'hello from protocol' }))
const msg = (await seen('new-chat-message', n))[0]
check.note('new-chat-message', msg)
check.that(msg?.content === 'hello from protocol' && typeof msg?.user?.id === 'string', 'new-chat-message({id, content, timestamp, user})')
const list = await (await fetch(`${env.url}/project/${pid}/messages?limit=5`, { headers: { cookie } })).json()
check.that(Array.isArray(list) && list.some((m: any) => m.content === 'hello from protocol'), 'GET /project/:id/messages lists it')

n = listener.events.length
const compiler = listener.project.compiler === 'xelatex' ? 'pdflatex' : 'xelatex'
check.note('settingsStatus', await post('/settings', { compiler }))
const comp = await seen('compilerUpdated', n)
check.note('compilerUpdated', comp)
check.that(comp[0] === compiler, 'compilerUpdated(compiler)')

n = listener.events.length
await post('/settings', { spellCheckLanguage: 'fr' })
const spell = await seen('spellCheckLanguageUpdated', n)
check.note('spellCheckLanguageUpdated', spell)
check.that(spell[0] === 'fr', 'spellCheckLanguageUpdated(language)')
listener.close()
check.done()
