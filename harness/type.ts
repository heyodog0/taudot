#!/usr/bin/env node
// Log in as a test user, open a file in Overleaf's real editor, apply edits, wait for the server to confirm them,
// and print the editor's text.
//
//   harness/type.ts --project <id|classic|history-ot> --file main.tex --pos 0 --text hi
//   harness/type.ts --project classic --file sections/intro.tex --edits '[{"pos":0,"text":"a"},{"pos":5,"del":2}]'
//   harness/type.ts --project classic --file main.tex            # just print the text
//
// Options: --user 1|2|admin|<email> (default 1), --pos N --text S, --pos N --del N, --edits JSON,
// --keys (type with the keyboard instead of exact CodeMirror changes), --json (print {text, docId, version, type}),
// --headed, --trace FILE (write every socket frame as JSON lines).
// Positions are JavaScript string indexes (UTF-16 code units): an emoji counts as 2.
import { parseArgs } from 'node:util'
import { writeFileSync } from 'node:fs'
import { loadEnv, pickProject, pickUser } from './lib/env.ts'
import { OverleafEditor, type Edit } from './lib/overleaf.ts'

const { values: a } = parseArgs({
  options: {
    project: { type: 'string' },
    file: { type: 'string', default: 'main.tex' },
    user: { type: 'string' },
    pos: { type: 'string' },
    text: { type: 'string' },
    del: { type: 'string' },
    edits: { type: 'string' },
    keys: { type: 'boolean', default: false },
    json: { type: 'boolean', default: false },
    headed: { type: 'boolean', default: false },
    trace: { type: 'string' },
  },
})
if (!a.project) {
  console.error('usage: harness/type.ts --project <id|classic|history-ot> --file <path> [--pos N --text S | --pos N --del N | --edits JSON]')
  process.exit(2)
}

const edits: Edit[] = a.edits ? JSON.parse(a.edits) : []
if (a.pos !== undefined) {
  const pos = Number(a.pos)
  if (a.text !== undefined) edits.push({ pos, text: a.text })
  else if (a.del !== undefined) edits.push({ pos, del: Number(a.del) })
  else throw new Error('--pos needs --text or --del')
}

const env = loadEnv()
const ed = new OverleafEditor(env.url)
let code = 0
try {
  await ed.launch({ headed: a.headed, trace: !!a.trace })
  await ed.login(pickUser(env, a.user))
  await ed.open(pickProject(env, a.project), a.file)
  if (edits.length) {
    await ed.edit(edits, a.keys ? 'keys' : 'dispatch')
    await ed.settle()
  }
  const text = await ed.text()
  if (a.json) console.log(JSON.stringify({ text, docId: ed.docId, version: ed.version, type: ed.docType }))
  else process.stdout.write(text.endsWith('\n') ? text : text + '\n')
} catch (err) {
  console.error(String(err instanceof Error ? err.stack : err))
  code = 1
} finally {
  if (a.trace) writeFileSync(a.trace, ed.frames.map(f => JSON.stringify(f)).join('\n') + '\n')
  await ed.close()
}
process.exit(code)
