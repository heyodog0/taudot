#!/usr/bin/env node
// Collaborator cursors over the socket: clientTracking.updatePosition (emit, strict schema in Router.js),
// clientTracking.getConnectedUsers (ack), and what other clients receive.
import { Check, client, joined, project, sleep } from './common.ts'

const check = new Check('cursors')
const pid = project('protocol classic')
const a = await client(1, pid)
const b = await client(2, pid)
const ja = await joined(a, 'main.tex')
await joined(b, 'main.tex')

const n = b.events.length
await a.emit('clientTracking.updatePosition', { row: 2, column: 5, doc_id: ja.docId })
const upd = (await b.waitEvent(e => e.name === 'clientTracking.clientUpdated', 10_000, n)).args[0]
check.note('clientUpdated', upd)
check.that(upd.row === 2 && upd.column === 5 && upd.doc_id === ja.docId, 'others get row, column, doc_id')
check.that(upd.id === a.publicId, 'id is the sender connection publicId')
check.that(typeof upd.user_id === 'string' && typeof upd.name === 'string', 'with user_id and name')

const [err, users] = await b.emit('clientTracking.getConnectedUsers')
check.note('connectedUsers', users)
check.that(!err && users.some((u: any) => u.client_id === a.publicId && u.cursorData?.row === 2), 'getConnectedUsers lists A with its cursor')

const m = b.events.length
a.close()
const gone = (await b.waitEvent(e => e.name === 'clientTracking.clientDisconnected', 10_000, m)).args
check.note('clientDisconnected', gone)
check.that(gone[0] === a.publicId, 'clientDisconnected(publicId)')
await sleep(100)
b.close()
check.done()
