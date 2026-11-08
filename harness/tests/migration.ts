#!/usr/bin/env node
// A project moved to history-ot while a client has a doc open (round 1 open question 3). The format is fixed when
// the document updater loads the doc, so classic ops keep working until it unloads the doc; then the next classic op
// gets otUpdateError "ot type mismatch" and a disconnect, and a rejoin returns history-ot.
import { execFileSync } from 'node:child_process'
import { Check, client, joined, project, sleep } from './common.ts'

const check = new Check('migration')
const pid = project('protocol migration', { reset: true })
const PATH = 'main.tex'
const docker = (...a: string[]) => execFileSync('docker', a, { encoding: 'utf8' })
const c = await client(1, pid)
const j = await joined(c, PATH)
check.that(j.type === 'sharejs-text-ot', `starts classic: ${j.type}`)
const send = async (v: number) => {
  const n = c.confirmations(j.docId).length
  await c.applyOtUpdate(j.docId, { doc: j.docId, op: [{ p: 0, i: 'm' }], v })
  await c.waitEvent(() => c.confirmations(j.docId).length > n || c.errors().length > 0 || c.closed, 10_000).catch(() => {})
  return c.confirmations(j.docId).length > n
}

docker('exec', 'texsync-mongo', 'mongosh', 'sharelatex', '--quiet', '--eval',
  `db.projects.updateOne({_id: ObjectId('${pid}')}, {$max: {'overleaf.history.otMigrationStage': 1}})`)
check.that(await send(j.version), 'classic op confirmed after the stage change, while the doc is loaded')

// Unload: flush the project out of the document updater, as it does when idle.
docker('exec', 'texsync-sharelatex', 'curl', '-sf', '-X', 'DELETE', `http://127.0.0.1:3003/project/${pid}`)
const ok = await send(j.version + 1)
await sleep(300)
check.note('afterUnload', { confirmed: ok, errors: c.errors().map(e => e.args[0]), closed: c.closed })
check.that(!ok && JSON.stringify(c.errors().map(e => e.args[0])).includes('ot type mismatch'), 'classic op after unload: ot type mismatch')
c.close()

const d = await client(1, pid)
const j2 = await joined(d, PATH)
check.note('rejoinType', j2.type)
check.that(j2.type === 'history-ot', 'rejoin returns history-ot')
check.that(j2.text.startsWith('m') && !j2.text.startsWith('mm'), 'the confirmed op was kept, the refused one was not')
d.close()
check.done()
