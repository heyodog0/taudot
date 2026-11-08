#!/usr/bin/env node
// N copies of Overleaf's own browser editor type random edits into one doc for T seconds, then every browser's text
// is compared with the server's. Other clients (taudot engines) can edit the same doc at the same time; give them
// the project ID and doc path this prints first, and use --tail so they settle before the comparison.
//
//   harness/fuzz.ts --browsers 3 --seconds 30                       # on its own project "protocol fuzz"
//   harness/fuzz.ts --project <id> --file sections/intro.tex --browsers 2 --seconds 60 --tail 5
//   harness/fuzz.ts --history-ot ...                                # on "protocol fuzz history-ot"
//
// Options: --project ID (default: make "protocol fuzz[ history-ot]" with docker/seed.sh), --file PATH (main.tex),
// --browsers N (3), --seconds T (20), --seed S (random), --min-ms/--max-ms pause between edits (100/600),
// --keys (type with the keyboard), --unicode (BMP non-ASCII text too), --emoji (astral too, breaks history-ot tabs,
// see docs/protocol.md), --tail S (wait S seconds after typing stops before comparing, 3), --headed, --json,
// --mirror DIR (repeatable: an engine's project folder; DIR/<file> must equal the server text too).
// Exit 0 when every browser equals the server and no server error was seen.
//
// Expect history-ot runs with more than one browser to fail: Overleaf CE 6.3.0 numbers concurrent history-ot ops
// wrongly and the browser then drops them (docs/protocol.md "history-ot versions").
import { parseArgs } from 'node:util'
import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { loadEnv } from './lib/env.ts'
import { OverleafEditor, type Edit } from './lib/overleaf.ts'
import { login, RealtimeClient, docIdByPath, joinedText } from './lib/socket.ts'

const { values: a } = parseArgs({
  options: {
    project: { type: 'string' },
    file: { type: 'string', default: 'main.tex' },
    browsers: { type: 'string', default: '3' },
    seconds: { type: 'string', default: '20' },
    seed: { type: 'string' },
    'min-ms': { type: 'string', default: '100' },
    'max-ms': { type: 'string', default: '600' },
    'history-ot': { type: 'boolean', default: false },
    keys: { type: 'boolean', default: false },
    unicode: { type: 'boolean', default: false },
    emoji: { type: 'boolean', default: false },
    tail: { type: 'string', default: '3' },
    headed: { type: 'boolean', default: false },
    json: { type: 'boolean', default: false },
    mirror: { type: 'string', multiple: true, default: [] },
  },
})

const env = loadEnv()
const here = dirname(fileURLToPath(import.meta.url))
const log = (...m: unknown[]) => console.error('[fuzz]', ...m)
const seed = a.seed !== undefined ? Number(a.seed) : Math.floor(Math.random() * 2 ** 31)
const N = Number(a.browsers)
const T = Number(a.seconds) * 1000

// mulberry32: small seeded PRNG, so a failing run can be repeated with --seed.
function rng(s: number) {
  return () => {
    s |= 0
    s = (s + 0x6d2b79f5) | 0
    let t = Math.imul(s ^ (s >>> 15), 1 | s)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

const ALPHABET = ['a', 'b', 'c', 'x', 'y', 'z', ' ', ' ', '\n', '\\', '{', '}', '%']
const UNICODE = ['é', 'ß', 'α', 'Ж', '日', '本', '€', '→', '�']
const EMOJI = ['😀', '𝔸']
function randomEdit(r: () => number, len: number): Edit {
  if (len > 0 && r() < 0.35) {
    const pos = Math.floor(r() * len)
    return { pos, del: 1 + Math.floor(r() * Math.min(5, len - pos)) }
  }
  const pool = [...ALPHABET, ...(a.unicode ? UNICODE : []), ...(a.emoji ? EMOJI : [])]
  let text = ''
  const n = 1 + Math.floor(r() * 4)
  for (let i = 0; i < n; i++) text += pool[Math.floor(r() * pool.length)]
  return { pos: Math.floor(r() * (len + 1)), text }
}

async function cookieFor(user: 1 | 2): Promise<string> {
  const file = join(tmpdir(), `taudot-harness-${new URL(env.url).port}-user${user}.cookie`)
  let cookie = existsSync(file) ? readFileSync(file, 'utf8').trim() : ''
  if (cookie) {
    const res = await fetch(`${env.url}/user/settings`, { headers: { cookie }, redirect: 'manual' })
    if (res.status !== 200) cookie = ''
  }
  if (!cookie) {
    cookie = await login(env.url, env.users[user - 1])
    writeFileSync(file, cookie, { mode: 0o600 })
  }
  return cookie
}

const projectId =
  a.project ??
  execFileSync(join(here, '..', 'docker', 'seed.sh'), ['--name', a['history-ot'] ? 'protocol fuzz history-ot' : 'protocol fuzz', ...(a['history-ot'] ? ['--history-ot'] : [])], {
    encoding: 'utf8',
    env: { ...process.env, TAUDOT_ENV_FILE: env.path },
  }).trim()
if (projectId === env.projects.classic || projectId === env.projects.historyOt) {
  throw new Error('refusing to fuzz the shared demo project; use docker/seed.sh --name to make your own')
}
log(`project ${projectId} file ${a.file} browsers ${N} seconds ${T / 1000} seed ${seed}`)

type Run = { ed: OverleafEditor; user: 1 | 2; edits: number; editErrors: string[]; failure?: string }
const runs: Run[] = []
const result: Record<string, unknown> = { projectId, file: a.file, seed, browsers: N, seconds: T / 1000 }
let code = 0
try {
  for (let i = 0; i < N; i++) {
    const user = (i % 2 === 0 ? 1 : 2) as 1 | 2
    const ed = new OverleafEditor(env.url)
    await ed.launch({ headed: a.headed })
    await ed.useCookie(await cookieFor(user))
    await ed.open(projectId, a.file)
    runs.push({ ed, user, edits: 0, editErrors: [] })
  }
  result.type = runs[0].ed.docType
  log(`opened, ${result.type}, doc ${runs[0].ed.docId}; typing`)

  const end = Date.now() + T
  const minMs = Number(a['min-ms'])
  const maxMs = Number(a['max-ms'])
  await Promise.all(
    runs.map(async (run, i) => {
      const r = rng(seed + i * 7919)
      while (Date.now() < end && !run.failure) {
        try {
          const len = (await run.ed.text()).length
          await run.ed.edit([randomEdit(r, len)], a.keys ? 'keys' : 'dispatch')
          run.edits++
        } catch (e) {
          // A dispatch can race a remote op landing in the editor (seen: CodeMirror "RangeError: Position N is out
          // of range for changeset"). Count it and go on; the browser stays usable.
          run.editErrors.push(String(e instanceof Error ? e.message : e).split("\n")[0].slice(0, 200))
          if (run.editErrors.length > 20) run.failure = "more than 20 failed edits"
        }
        await new Promise(res => setTimeout(res, minMs + r() * (maxMs - minMs)))
      }
    })
  )
  log('typing stopped; settling')
  await Promise.all(
    runs.map(async run => {
      try {
        await run.ed.settle(500, 60_000)
      } catch (e) {
        run.failure ??= String(e instanceof Error ? e.message : e).slice(0, 300)
      }
    })
  )
  await new Promise(res => setTimeout(res, Number(a.tail) * 1000))

  // The server's text, from a fresh raw join.
  const c = new RealtimeClient(env.url, await cookieFor(1))
  await c.connect(projectId)
  const docId = docIdByPath(c.project, a.file)
  const j = await c.joinDoc(docId)
  const server = joinedText(j)
  c.close()
  result.serverVersion = j.version
  result.serverLength = server.length
  result.surrogatesOnServer = /[\uD800-\uDFFF]/.test(server)

  const per = []
  for (const [i, run] of runs.entries()) {
    const text = await run.ed.text()
    let firstDiff = -1
    if (text !== server) {
      firstDiff = 0
      while (firstDiff < Math.min(text.length, server.length) && text[firstDiff] === server[firstDiff]) firstDiff++
    }
    per.push({
      browser: i,
      user: run.user,
      edits: run.edits,
      editErrors: run.editErrors.length,
      ...(run.editErrors.length ? { firstEditError: run.editErrors[0] } : {}),
      inSync: text === server,
      ...(text !== server ? { length: text.length, firstDiff, near: JSON.stringify(text.slice(Math.max(0, firstDiff - 10), firstDiff + 10)), serverNear: JSON.stringify(server.slice(Math.max(0, firstDiff - 10), firstDiff + 10)) } : {}),
      serverErrors: run.ed.serverErrors(),
      pageErrors: run.ed.pageErrors.slice(0, 3),
      ...(run.failure ? { failure: run.failure } : {}),
    })
  }
  result.browsersResult = per
  // Engine folder mirrors (--mirror DIR, repeatable): DIR/<file> must equal the server text.
  const mirrors = (a.mirror as string[]).map(dir => {
    const path = join(dir, a.file!)
    const text = existsSync(path) ? readFileSync(path, 'utf8') : null
    return { dir, inSync: text === server, ...(text === null ? { missing: true } : text !== server ? { length: text.length } : {}) }
  })
  if (mirrors.length) result.mirrors = mirrors
  result.ok = per.every(p => p.inSync && p.serverErrors.length === 0) && mirrors.every(m => m.inSync)
  if (!result.ok) code = 1
} catch (e) {
  result.ok = false
  result.error = String(e instanceof Error ? e.stack : e)
  code = 2
} finally {
  await Promise.all(runs.map(r => r.ed.close()))
}
if (a.json) console.log(JSON.stringify(result))
else console.log(JSON.stringify(result, null, 1))
process.exit(code)
