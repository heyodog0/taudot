// Bob types into Overleaf's own browser editor (the harness's serve.ts, headless, as CE user2): one character at a
// time at a human pace, inserted after the first occurrence of AFTER in FILE.
//   node site/demo/bob.mjs PROJECT_ID FILE AFTER TEXT        (HARNESS: the harness folder, default the main clone's)
import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'
const [project, file, after, text] = process.argv.slice(2)
const harness = process.env.HARNESS || `${process.env.HOME}/code/lab/taudot/harness`
const p = spawn('node', ['serve.ts'], { cwd: harness, stdio: ['pipe', 'pipe', 'inherit'] })
const lines = createInterface({ input: p.stdout })[Symbol.asyncIterator]()
const call = async cmd => { p.stdin.write(JSON.stringify(cmd) + '\n'); const { value } = await lines.next(); const r = JSON.parse(value); if (!r.ok) throw new Error(value); return r }
const sleep = ms => new Promise(r => setTimeout(r, ms))
await call({ cmd: 'open', project, file, user: '2' })
const { text: doc } = await call({ cmd: 'text' })
let pos = doc.indexOf(after)
if (pos < 0) throw new Error(`no "${after}" in ${file}`)
pos += after.length
console.log('ready'); 
if (process.env.WAIT) await sleep(Number(process.env.WAIT))
for (const ch of text) {
  await call({ cmd: 'edit', edits: [{ pos, text: ch }] })
  pos += ch.length
  await sleep(60 + Math.random() * 60 + (ch === ' ' ? 40 : 0) + (/[,.)]/.test(ch) ? 150 : 0))
}
await call({ cmd: 'settle' })
console.log('done')
await call({ cmd: 'close' }).catch(() => {})
p.kill()
