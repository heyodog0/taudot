#!/usr/bin/env node
// File-tree changes made over REST, and the socket events other clients get (Workshop's list, not checked on CE before).
// Routes: services/web/app/src/Features/Editor/EditorRouter.mjs. Events: EditorController.mjs.
import { Check, client, cookieFor, env, project, sleep } from './common.ts'

const check = new Check('entity-events')
const pid = project('protocol entities', { reset: true })
const listener = await client(2, pid)
const cookie = await cookieFor(1)
const page = await (await fetch(`${env.url}/project/${pid}`, { headers: { cookie } })).text()
const csrf = page.match(/name="ol-csrfToken" content="([^"]*)"/)?.[1]
if (!csrf) throw new Error('no CSRF token on the project page')
const rootId = listener.project.rootFolder[0]._id
const api = async (method: string, path: string, body?: object) => {
  const res = await fetch(`${env.url}/project/${pid}${path}`, {
    method,
    headers: { cookie, 'x-csrf-token': csrf, 'content-type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  })
  const text = await res.text()
  if (!res.ok) throw new Error(`${method} ${path}: ${res.status} ${text}`)
  return text ? JSON.parse(text) : null
}
const seen = async (name: string, from: number) => (await listener.waitEvent(e => e.name === name, 10_000, from)).args

let n = listener.events.length
const doc = await api('POST', '/doc', { name: 'new.tex', parent_folder_id: rootId })
const newDoc = await seen('reciveNewDoc', n)
check.note('reciveNewDoc', newDoc)
check.that(newDoc[0] === rootId && newDoc[1]?._id === doc._id && newDoc[1]?.name === 'new.tex', 'reciveNewDoc(folderId, {_id, name}, ...)')

n = listener.events.length
const folder = await api('POST', '/folder', { name: 'sub', parent_folder_id: rootId })
const newFolder = await seen('reciveNewFolder', n)
check.note('reciveNewFolder', newFolder)
check.that(newFolder[0] === rootId && newFolder[1]?._id === folder._id, 'reciveNewFolder(parentId, {_id, name, ...})')

n = listener.events.length
await api('POST', `/doc/${doc._id}/rename`, { name: 'renamed.tex' })
const rename = await seen('reciveEntityRename', n)
check.note('reciveEntityRename', rename)
check.that(rename[0] === doc._id && rename[1] === 'renamed.tex', 'reciveEntityRename(id, newName)')

n = listener.events.length
await api('POST', `/doc/${doc._id}/move`, { folder_id: folder._id })
const move = await seen('reciveEntityMove', n)
check.note('reciveEntityMove', move)
check.that(move[0] === doc._id && move[1] === folder._id, 'reciveEntityMove(id, folderId)')

n = listener.events.length
await api('DELETE', `/doc/${doc._id}`)
const removed = await seen('removeEntity', n)
check.note('removeEntity', removed)
check.that(removed[0] === doc._id, 'removeEntity(id, ...)')
await sleep(200)
listener.close()
check.done()
