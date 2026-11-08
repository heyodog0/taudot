// Shared setup for the socket-level protocol tests. Each test runs against its own project (docker/seed.sh --name),
// never the shared demo projects, and prints one JSON result line. Exit code 0 means the answer matched
// docs/protocol.md.
import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { loadEnv, type TestEnv } from '../lib/env.ts'
import { login, RealtimeClient, docIdByPath, joinedText } from '../lib/socket.ts'

export const env: TestEnv = loadEnv()
const seed = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'docker', 'seed.sh')

/** Get (or with reset, recreate) a test project of our own. */
export function project(name: string, opts: { historyOt?: boolean; reset?: boolean; from?: string } = {}): string {
  const args = ['--name', name]
  if (opts.historyOt) args.push('--history-ot')
  if (opts.reset) args.push('--reset')
  if (opts.from) args.push('--from', opts.from)
  return execFileSync(seed, args, { encoding: 'utf8', env: { ...process.env, TAUDOT_ENV_FILE: env.path } }).trim()
}

// Overleaf rate-limits logins per email, so a test run logs in once per user and keeps the cookie in a temp file
// for the next test (checked with a web request, which also keeps the session alive).
const cookies = new Map<number, string>()
export async function cookieFor(user: 1 | 2): Promise<string> {
  if (cookies.has(user)) return cookies.get(user)!
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
  cookies.set(user, cookie)
  return cookie
}

/** A connected client for user 1 or 2. */
export async function client(user: 1 | 2, projectId: string): Promise<RealtimeClient> {
  const c = new RealtimeClient(env.url, await cookieFor(user))
  await c.connect(projectId)
  return c
}

export async function joined(c: RealtimeClient, path: string) {
  const docId = docIdByPath(c.project, path)
  const j = await c.joinDoc(docId)
  return { docId, ...j, text: joinedText(j) }
}

export const sleep = (ms: number) => new Promise(r => setTimeout(r, ms))

/** Check a condition, collect failures, print the result and exit. */
export class Check {
  failures: string[] = []
  facts: Record<string, unknown> = {}
  name: string
  constructor(name: string) {
    this.name = name
  }
  that(ok: boolean, what: string): void {
    if (!ok) this.failures.push(what)
  }
  note(key: string, value: unknown): void {
    this.facts[key] = value
  }
  done(): never {
    const ok = this.failures.length === 0
    console.log(JSON.stringify({ test: this.name, ok, failures: this.failures, ...this.facts }, null, 1))
    process.exit(ok ? 0 : 1)
  }
}

export { docIdByPath, joinedText }

/** Overleaf's browser editor, launched and logged in as user 1 or 2 with the cached session. */
export async function browser(user: 1 | 2, opts: { trace?: boolean; headed?: boolean } = {}) {
  const { OverleafEditor } = await import('../lib/overleaf.ts')
  const ed = new OverleafEditor(env.url)
  await ed.launch(opts)
  await ed.useCookie(await cookieFor(user))
  return ed
}
