#!/usr/bin/env node
// Binary files: upload (POST /Project/:id/upload, multipart `qqfile`), download (GET /Project/:id/file/:fileId), the
// socket events another client gets, and what an upload over an existing name does. For the engine's folder mirror.
// Routes: services/web/app/src/Features/Uploads/UploadsRouter.mjs, router.mjs. Events: EditorController.mjs.
import { Check, client, cookieFor, env, project, sleep } from './common.ts'

const check = new Check('files')
const pid = project('protocol files', { reset: true })
const listener = await client(2, pid)
const cookie = await cookieFor(1)
const page = await (await fetch(`${env.url}/project/${pid}`, { headers: { cookie } })).text()
const csrf = page.match(/name="ol-csrfToken" content="([^"]*)"/)?.[1]
if (!csrf) throw new Error('no CSRF token on the project page')
const rootId = listener.project.rootFolder[0]._id
const seen = async (name: string, from: number) => (await listener.waitEvent(e => e.name === name, 10_000, from)).args

async function upload(name: string, data: Uint8Array, folderId = rootId, relativePath?: string) {
  const form = new FormData()
  form.append('name', name)
  form.append('type', 'application/octet-stream')
  if (relativePath) form.append('relativePath', relativePath)
  form.append('qqfile', new Blob([data]), name)
  const res = await fetch(`${env.url}/Project/${pid}/upload?folder_id=${folderId}`, {
    method: 'POST',
    headers: { cookie, 'x-csrf-token': csrf! },
    body: form,
  })
  return { status: res.status, body: await res.json().catch(() => null) }
}

// A small PNG-ish binary with a NUL, so it can't become a doc.
const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 1, 2, 3, 255])
let n = listener.events.length
const up = await upload('dot.png', png)
check.note('upload', up)
check.that(up.status === 200 && up.body?.success === true && up.body?.entity_type === 'file', 'upload answers {success, entity_id, entity_type: "file", hash}')
const newFile = await seen('reciveNewFile', n)
check.note('reciveNewFile', newFile)
check.that(newFile[0] === rootId && newFile[1]?._id === up.body.entity_id && newFile[1]?.name === 'dot.png',
  'reciveNewFile(folderId, {_id, name, ...}, source, linkedFileData, userId)')
check.that(newFile[2] === 'upload', 'source is "upload"')

const dl = await fetch(`${env.url}/Project/${pid}/file/${up.body.entity_id}`, { headers: { cookie } })
const bytes = new Uint8Array(await dl.arrayBuffer())
check.note('download', { status: dl.status, type: dl.headers.get('content-type'), len: bytes.length })
check.that(dl.status === 200 && Buffer.from(bytes).equals(Buffer.from(png)), 'GET /Project/:id/file/:fileId returns the bytes')

// The same name again replaces it: removeEntity(old) then reciveNewFile(new id).
n = listener.events.length
const png2 = new Uint8Array([...png, 7])
const up2 = await upload('dot.png', png2)
check.note('reupload', up2)
const removed = await seen('removeEntity', n)
const newFile2 = await seen('reciveNewFile', n)
check.note('replace events', { removed, newFile2 })
check.that(up2.body?.success === true && removed[0] === up.body.entity_id && newFile2[1]?._id === up2.body.entity_id,
  'reupload: removeEntity(oldId) then reciveNewFile(newId)')
check.that(up2.body.entity_id !== up.body.entity_id, 'a replaced file gets a new ID')

// A text file uploaded over an existing doc's name: upsertDoc (whole-content replace, keeps the doc ID?).
n = listener.events.length
const t1 = await upload('notes.tex', new TextEncoder().encode('first\n'))
check.note('text upload', t1)
check.that(t1.body?.entity_type === 'doc', 'a text upload becomes a doc')
const newDoc = await seen('reciveNewDoc', n)
check.note('reciveNewDoc (upload)', newDoc)
const t2 = await upload('notes.tex', new TextEncoder().encode('second\n'))
check.note('text reupload', t2)
check.that(t2.body?.entity_id === t1.body?.entity_id, 'a text upload over a doc keeps its ID (content replaced)')

// relativePath makes folders (mkdirp) and puts the file there.
n = listener.events.length
const up3 = await upload('deep.png', png, rootId, 'figs/sub/deep.png')
check.note('relativePath upload', up3)
const folders = listener.events.slice(n).filter(e => e.name === 'reciveNewFolder').map(e => e.args)
const deep = await seen('reciveNewFile', n)
check.note('relativePath events', { folders, deep })
check.that(up3.body?.success === true && folders.length === 2, 'relativePath creates the missing folders (reciveNewFolder each)')

// Folder delete: one removeEntity for the folder only?
n = listener.events.length
const res = await fetch(`${env.url}/project/${pid}/folder/${deep[0]}`, { method: 'DELETE', headers: { cookie, 'x-csrf-token': csrf } })
check.note('folder delete', res.status)
await sleep(500)
const removes = listener.events.slice(n).filter(e => e.name === 'removeEntity').map(e => e.args)
check.note('removeEntity after folder delete', removes)
check.that(removes.length === 1 && removes[0][0] === deep[0], 'deleting a folder sends one removeEntity, for the folder')

// Too big: Settings.maxUploadSize is 50 MB by default. Don't send 50 MB; just record the setting is the limit.
listener.close()
check.done()
