#!/usr/bin/env node
// A long-lived reference client for fuzz tests. Reads one JSON command per line on stdin, writes one JSON reply
// per line on stdout: {"ok": true, ...} or {"ok": false, "error": "..."}.
//
//   {"cmd": "open", "project": "classic", "file": "main.tex", "user": "2"}   -> {ok, docId, version, type}
//   {"cmd": "edit", "edits": [{"pos": 0, "text": "x"}, {"pos": 3, "del": 1}], "keys": false}
//   {"cmd": "settle"}       wait until every edit is confirmed by the server -> {ok, version}
//   {"cmd": "text"}         -> {ok, text, version}
//   {"cmd": "errors"}       -> {ok, errors}
//   {"cmd": "close"}
//
// Run: harness/serve.ts [--headed]
import { createInterface } from 'node:readline'
import { loadEnv, pickProject, pickUser } from './lib/env.ts'
import { OverleafEditor } from './lib/overleaf.ts'

const headed = process.argv.includes('--headed')
const env = loadEnv()
const ed = new OverleafEditor(env.url)
await ed.launch({ headed })
let loggedIn = false

const reply = (o: object) => process.stdout.write(JSON.stringify(o) + '\n')

for await (const line of createInterface({ input: process.stdin })) {
  if (!line.trim()) continue
  let req: any
  try {
    req = JSON.parse(line)
    switch (req.cmd) {
      case 'open':
        if (!loggedIn) {
          await ed.login(pickUser(env, req.user))
          loggedIn = true
        }
        await ed.open(pickProject(env, req.project), req.file ?? 'main.tex')
        reply({ ok: true, docId: ed.docId, version: ed.version, type: ed.docType })
        break
      case 'edit':
        await ed.edit(req.edits, req.keys ? 'keys' : 'dispatch')
        reply({ ok: true })
        break
      case 'settle':
        await ed.settle(req.quietMs, req.timeoutMs)
        reply({ ok: true, version: ed.version })
        break
      case 'text':
        reply({ ok: true, text: await ed.text(), version: ed.version })
        break
      case 'errors':
        reply({ ok: true, errors: ed.serverErrors() })
        break
      case 'close':
        reply({ ok: true })
        await ed.close()
        process.exit(0)
      default:
        reply({ ok: false, error: `unknown cmd ${req.cmd}` })
    }
  } catch (err) {
    reply({ ok: false, error: String(err instanceof Error ? err.message : err) })
  }
}
await ed.close()
