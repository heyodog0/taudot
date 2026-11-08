// A local replica of a real project, for testing review features without touching the real one.
//
//   node harness/replicate.ts snapshot --from <overleaf.com project id> --to <name>
//   node harness/replicate.ts build <name> [--title "Demo Paper (replica)"]
//   node harness/replicate.ts check <name>
//
// `snapshot` is read-only on overleaf.com: a throwaway engine (its own home, your `taudot login` session from the
// Keychain) clones the project into ~/.taudot/replicas/<name>/files and saves every doc's text and ranges and the
// comment threads, then forgets the project and stops. Nothing is sent but what opening a project sends.
//
// `build` makes the replica on the local CE (docker/.env.test): the project from the snapshot's files, owned by the
// CE user standing in for the original owner, with every tracked change and comment at the same place, by the same
// stand-in author, with the original times, and every thread with its messages and resolved state. Authors map to
// CE users: you (who took the snapshot) to user1 (alice, the one the app signs in as), the owner to user2 (bob), the
// others to admin and then extra users made here (carol, dave...). Run it again to replace the replica. CE needs the
// thread routes from harness/ce-threads/install.sh.
//
// `check` opens the replica with a throwaway CE engine and compares its ranges and threads with the snapshot.
//
// Snapshots stay outside the repo: the paper belongs to the user's collaborators.
import { execFileSync, spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join, resolve } from 'node:path'

const repo = resolve(dirname(new URL(import.meta.url).pathname), '..')
const taudot = join(repo, 'target/debug/taudot')
const replicas = join(homedir(), '.taudot/replicas')
const envFile = process.env.TAUDOT_ENV_FILE ?? join(homedir(), 'code/lab/taudot/docker/.env.test')
const CE = 'texsync-sharelatex'
const MONGO = 'texsync-mongo'
const EXTRA = ['carol', 'dave', 'erin', 'frank']

type User = { user_id: string; name: string; initials?: string }
type Range = { id: string; kind: string; start: number; end: number; text: string; author: User; ts: number; thread_id?: string }
type Message = { id: string; text: string; ts: number; user: User }
type Thread = { thread_id: string; resolved: boolean; resolved_at: number | null; resolved_by: User | null; messages: Message[];
  doc_id: string; path: string; start: number; end: number; text: string }
type Snapshot = {
  meta: { project_id: string; name: string; server: string; owner: User; me: User; track_changes: Record<string, boolean> | boolean; taken: string }
  docs: { doc_id: string; path: string; text: string; ranges: Range[] }[]
  threads: Thread[]
}

// ---------- engines ----------

class Engine {
  home: string
  proc: ReturnType<typeof spawn> | undefined
  args: string[]
  constructor(args: string[]) {
    this.args = args
    // Unix socket paths are short (SUN_LEN), so not the long $TMPDIR.
    this.home = `/tmp/txrep-${process.pid}-${Math.random().toString(36).slice(2, 6)}`
    mkdirSync(this.home, { recursive: true })
  }
  async start() {
    this.proc = spawn(taudot, ['serve', '--home', this.home, ...this.args], { stdio: ['ignore', 'ignore', 'pipe'] })
    let err = ''
    this.proc.stderr!.on('data', d => (err += d))
    for (let i = 0; i < 100 && !existsSync(join(this.home, 'engine.sock')); i++) await sleep(100)
    if (!existsSync(join(this.home, 'engine.sock'))) throw new Error(`engine didn't start: ${err}`)
  }
  call(method: string, params: object = {}): any {
    const out = execFileSync(taudot, ['rpc', '--home', this.home, method, JSON.stringify(params)], { encoding: 'utf8', maxBuffer: 1 << 28 })
    return JSON.parse(out)
  }
  stop() {
    this.proc?.kill()
    rmSync(this.home, { recursive: true, force: true })
  }
}

const sleep = (ms: number) => new Promise(r => setTimeout(r, ms))

// ---------- snapshot (overleaf.com, read-only) ----------

async function snapshot(from: string, name: string) {
  const dir = join(replicas, name)
  if (existsSync(dir)) rmSync(dir, { recursive: true })
  mkdirSync(join(dir, 'docs'), { recursive: true })
  const e = new Engine(['--url', 'https://www.overleaf.com'])
  await e.start()
  try {
    const me = e.call('account.status', {})
    if (!me.logged_in) throw new Error('not signed in to overleaf.com: run `taudot login --url https://www.overleaf.com`')
    const listed = e.call('projects.list', {}).projects.find((p: any) => p.id === from)
    if (!listed) throw new Error(`project ${from} isn't in your project list`)
    e.call('project.clone', { project_id: from, folder: join(dir, 'files') })
    const status = e.call('project.status', { project_id: from })
    const docs = status.docs.map((d: any) => {
      const open = e.call('doc.open', { project_id: from, path: d.path })
      const r = e.call('doc.ranges', { doc_id: d.doc_id })
      if (open.seq !== r.seq) throw new Error(`${d.path} changed while reading it; run again`)
      return { doc_id: d.doc_id, path: d.path, text: open.text, ranges: r.ranges }
    })
    const threads = e.call('thread.list', { project_id: from }).threads
    e.call('project.forget', { project_id: from, folder: join(dir, 'files') })
    rmSync(join(dir, 'files/.taudot.json'), { force: true })
    const snap: Snapshot = {
      meta: { project_id: from, name: listed.name, server: 'https://www.overleaf.com', taken: new Date().toISOString(),
        owner: { user_id: listed.owner.id, name: listed.owner.name }, me: { user_id: me.user_id, name: me.name },
        track_changes: status.overleaf_track_changes },
      docs, threads,
    }
    writeFileSync(join(dir, 'snapshot.json'), JSON.stringify(snap, null, 1))
    console.log(`${listed.name}: ${docs.length} docs, ${count(snap).changes} tracked changes, ${threads.length} threads -> ${dir}`)
  } finally {
    e.stop()
  }
}

function count(s: Snapshot) {
  const all = s.docs.flatMap(d => d.ranges)
  return { changes: all.filter(r => r.kind !== 'comment').length, comments: all.filter(r => r.kind === 'comment').length }
}

// ---------- CE plumbing ----------

function env(): Record<string, string> {
  return Object.fromEntries(readFileSync(envFile, 'utf8').split('\n').filter(l => /^[A-Z_0-9]+=/.test(l)).map(l => {
    const i = l.indexOf('=')
    return [l.slice(0, i), l.slice(i + 1)]
  }))
}

function mongo(js: string): any {
  const out = execFileSync('docker', ['exec', MONGO, 'mongosh', '--quiet', 'sharelatex', '--eval',
    `const r = (() => { ${js} })(); print('@@' + (r === undefined ? 'null' : JSON.stringify(r)))`], { encoding: 'utf8', maxBuffer: 1 << 28 })
  const line = out.split('\n').find(l => l.startsWith('@@'))
  if (line === undefined) throw new Error(`mongosh: ${out}`)
  return JSON.parse(line.slice(2)) ?? undefined
}

/** A request to one of CE's internal services, from inside the container. */
function internal(method: string, url: string, body?: object): any {
  const args = ['exec', '-i', CE, 'curl', '-sS', '-f', '-X', method, url]
  if (body) args.push('-H', 'Content-Type: application/json', '--data-binary', '@-')
  const out = execFileSync('docker', args, { input: body ? JSON.stringify(body) : undefined, encoding: 'utf8', maxBuffer: 1 << 28 })
  return out.trim() ? JSON.parse(out) : undefined
}
const DOCSTORE = 'http://127.0.0.1:3016'
const DOCUPDATER = 'http://127.0.0.1:3003'
const CHAT = 'http://127.0.0.1:3010'

/** A signed-in web session on CE. */
class Web {
  cookies = new Map<string, string>()
  csrf = ''
  url: string
  constructor(url: string) {
    this.url = url
  }
  private store(r: Response) {
    for (const c of r.headers.getSetCookie()) {
      const [kv] = c.split(';')
      const i = kv.indexOf('=')
      this.cookies.set(kv.slice(0, i), kv.slice(i + 1))
    }
  }
  async req(method: string, path: string, body?: object | FormData): Promise<Response> {
    const headers: Record<string, string> = { Cookie: [...this.cookies].map(([k, v]) => `${k}=${v}`).join('; '), 'X-Csrf-Token': this.csrf }
    let b: any = body
    if (body && !(body instanceof FormData)) {
      headers['Content-Type'] = 'application/json'
      b = JSON.stringify(body)
    }
    const r = await fetch(this.url + path, { method, headers, body: b, redirect: 'manual' })
    this.store(r)
    return r
  }
  async login(email: string, password: string) {
    const page = await (await this.req('GET', '/login')).text()
    this.csrf = page.match(/name="ol-csrfToken" content="([^"]+)"/)![1]
    const r = await this.req('POST', '/login', { email, password })
    if (r.status >= 400) throw new Error(`CE login as ${email}: ${r.status} ${await r.text()}`)
    const list = await this.req('GET', '/project')
    if (list.status !== 200) throw new Error(`CE login as ${email}: /project answers ${list.status}`)
    const p = await list.text()
    this.csrf = p.match(/name="ol-csrfToken" content="([^"]+)"/)![1]
  }
}

type CEUser = { id: string; email: string; name: string; key?: string }

/** The CE user for each original author. */
async function standIns(s: Snapshot, e: Record<string, string>, admin: Web): Promise<Map<string, CEUser>> {
  const named = (key: string): CEUser => {
    const id = e[`OVERLEAF_${key}_ID`]
    const u = mongo(`const u = db.users.findOne({_id: ObjectId(${JSON.stringify(id)})}); return {first_name: u.first_name, last_name: u.last_name}`)
    return { id, email: e[`OVERLEAF_${key}_EMAIL`], name: [u.first_name, u.last_name].filter(Boolean).join(' '), key }
  }
  const pool = [named('ADMIN')]
  const authors: string[] = []
  const see = (u?: User | null) => u?.user_id && !authors.includes(u.user_id) && authors.push(u.user_id)
  see(s.meta.me)
  see(s.meta.owner)
  for (const d of s.docs) for (const r of d.ranges) see(r.author)
  for (const t of s.threads) {
    for (const m of t.messages) see(m.user)
    see(t.resolved_by)
  }
  const map = new Map<string, CEUser>([[s.meta.me.user_id, named('USER1')]])
  if (s.meta.owner.user_id !== s.meta.me.user_id) map.set(s.meta.owner.user_id, named('USER2'))
  else pool.unshift(named('USER2'))
  let extra = 0
  for (const a of authors) {
    if (map.has(a)) continue
    let u = pool.shift()
    if (!u) {
      const who = EXTRA[extra++]
      if (!who) throw new Error('too many authors')
      u = await extraUser(who, admin)
    }
    map.set(a, u)
  }
  return map
}

/** carol@texsync.test and so on: made once through CE's admin registration, with a name. Nobody signs in as them. */
async function extraUser(who: string, admin: Web): Promise<CEUser> {
  const email = `${who}@texsync.test`
  const find = () => mongo(`const u = db.users.findOne({email: ${JSON.stringify(email)}}); return u && u._id.toString()`)
  let id = find()
  if (!id) {
    const r = await admin.req('POST', '/admin/register', { email })
    if (!r.ok) throw new Error(`registering ${email}: ${r.status} ${await r.text()}`)
    id = find()
  }
  const name = who[0].toUpperCase() + who.slice(1)
  mongo(`db.users.updateOne({_id: ObjectId(${JSON.stringify(id)})}, {$set: {first_name: ${JSON.stringify(name)}, last_name: ''}})`)
  return { id, email, name }
}

/** UTF-8 byte offset to JavaScript string offset (the unit of Overleaf's classic ranges). */
function utf16(text: string, bytes: number): number {
  return Buffer.from(text, 'utf8').subarray(0, bytes).toString('utf8').length
}

// ---------- build (local CE) ----------

async function build(name: string, title: string) {
  const dir = join(replicas, name)
  const s: Snapshot = JSON.parse(readFileSync(join(dir, 'snapshot.json'), 'utf8'))
  const e = env()
  const url = e.OVERLEAF_URL ?? 'http://localhost:8800'
  const web = (key: string) => {
    const w = new Web(url)
    return w.login(e[`OVERLEAF_${key}_EMAIL`], e[`OVERLEAF_${key}_PASSWORD`]).then(() => w)
  }
  const admin = await web('ADMIN')
  const users = await standIns(s, e, admin)
  const owner = users.get(s.meta.owner.user_id)!
  const ownerWeb = await web(owner.key!)
  const pick = (u?: User | null) => (u?.user_id ? users.get(u.user_id) : undefined) ?? owner

  // An earlier replica of the same name goes first.
  const old: string[] = mongo(`return db.projects.find({name: ${JSON.stringify(title)}, owner_ref: ObjectId(${JSON.stringify(owner.id)})}).toArray().map(p => p._id.toString())`)
  for (const id of old) {
    const r = await ownerWeb.req('DELETE', `/project/${id}`)
    if (!r.ok) throw new Error(`deleting the old replica ${id}: ${r.status}`)
  }

  // The project from the files, as an uploaded zip.
  const zip = join(dir, 'upload.zip')
  rmSync(zip, { force: true })
  execFileSync('zip', ['-q', '-r', '-X', zip, '.', '-x', '.taudot.json', '-x', '*.DS_Store'], { cwd: join(dir, 'files') })
  const form = new FormData()
  form.append('name', `${title}.zip`)
  form.append('qqfile', new Blob([readFileSync(zip)], { type: 'application/zip' }), `${title}.zip`)
  const up = await ownerWeb.req('POST', '/project/new/upload', form)
  const upj: any = await up.json()
  rmSync(zip)
  if (!upj.success) throw new Error(`upload: ${JSON.stringify(upj)}`)
  const pid: string = upj.project_id
  const rename = await ownerWeb.req('POST', `/project/${pid}/rename`, { newProjectName: title })
  if (!rename.ok) throw new Error(`rename: ${rename.status}`)

  // Everyone else as a collaborator who can edit, and Overleaf's track-changes setting, per stand-in.
  const others = [...new Set([...users.values()].map(u => u.id))].filter(id => id !== owner.id)
  const tc = typeof s.meta.track_changes === 'object'
    ? Object.fromEntries(Object.entries(s.meta.track_changes).filter(([k]) => users.has(k)).map(([k, v]) => [users.get(k)!.id, v]))
    : s.meta.track_changes
  mongo(`db.projects.updateOne({_id: ObjectId(${JSON.stringify(pid)})}, {$set: {
    collaberator_refs: ${JSON.stringify(others)}.map(x => ObjectId(x)), track_changes: ${JSON.stringify(tc)} }})`)

  // Docs by path. Nobody has opened the project, but make sure the doc updater holds nothing before writing ranges.
  internal('DELETE', `${DOCUPDATER}/project/${pid}`)
  const known = new Set((internal('GET', `${DOCSTORE}/project/${pid}/doc`) as any[]).map(d => d._id))
  const byPath = docPaths(pid)
  let changes = 0
  let comments = 0
  for (const d of s.docs) {
    const id = byPath[d.path]
    if (!id || !known.has(id)) throw new Error(`no doc ${d.path} in the replica`)
    const cur = internal('GET', `${DOCSTORE}/project/${pid}/doc/${id}`)
    const text = cur.lines.join('\n')
    if (text !== d.text) throw new Error(`${d.path}: the uploaded text differs from the snapshot`)
    const ch = d.ranges.filter(r => r.kind !== 'comment').map(r => ({
      id: r.id,
      op: r.kind === 'tracked_insert' ? { i: r.text, p: utf16(d.text, r.start) } : { d: r.text, p: utf16(d.text, r.start) },
      metadata: { user_id: pick(r.author).id, ts: new Date(r.ts).toISOString() },
    }))
    const cm = d.ranges.filter(r => r.kind === 'comment').map(r => ({
      id: r.thread_id ?? r.id,
      op: { c: r.text, p: utf16(d.text, r.start), t: r.thread_id ?? r.id },
    }))
    if (!ch.length && !cm.length) continue
    const ranges: any = {}
    if (ch.length) ranges.changes = ch.sort((a, b) => a.op.p - b.op.p)
    if (cm.length) ranges.comments = cm.sort((a, b) => a.op.p - b.op.p)
    internal('POST', `${DOCSTORE}/project/${pid}/doc/${id}`, { lines: cur.lines, version: cur.version, ranges })
    changes += ch.length
    comments += cm.length
  }

  // Threads: each message through the chat service as its stand-in author, then the original time put back.
  const times: [string, number][] = []
  for (const t of s.threads) {
    for (const m of t.messages) {
      const made = internal('POST', `${CHAT}/project/${pid}/thread/${t.thread_id}/messages`, { user_id: pick(m.user).id, content: m.text })
      times.push([made.id, m.ts])
    }
    if (t.resolved) {
      internal('POST', `${CHAT}/project/${pid}/thread/${t.thread_id}/resolve`, { user_id: pick(t.resolved_by).id })
      if (t.resolved_at) mongo(`db.rooms.updateOne({project_id: ObjectId(${JSON.stringify(pid)}), thread_id: ObjectId(${JSON.stringify(t.thread_id)})},
        {$set: {'resolved.ts': new Date(${t.resolved_at})}})`)
      const docId = byPath[t.path]
      if (docId) internal('POST', `${DOCUPDATER}/project/${pid}/doc/${docId}/comment/${t.thread_id}/resolve`, { user_id: pick(t.resolved_by).id })
    }
  }
  if (times.length) mongo(`${JSON.stringify(times)}.forEach(([id, ts]) => db.messages.updateOne({_id: ObjectId(id)}, {$set: {timestamp: ts}}))`)

  const ce = Object.fromEntries([...users].map(([orig, u]) => [orig, u.email]))
  writeFileSync(join(dir, 'replica.json'), JSON.stringify({ project_id: pid, title, server: url, built: new Date().toISOString(), owner: owner.email, users: ce }, null, 1))
  console.log(`${title}: ${url}/project/${pid}, owned by ${owner.email}; ${changes} tracked changes, ${comments} comments, ${s.threads.length} threads (${times.length} messages)`)
  for (const [orig, u] of users) console.log(`  ${nameOf(s, orig)} -> ${u.name} <${u.email}>`)
}

function nameOf(s: Snapshot, id: string): string {
  if (s.meta.me.user_id === id) return `${s.meta.me.name} (you)`
  if (s.meta.owner.user_id === id) return `${s.meta.owner.name} (owner)`
  for (const d of s.docs) for (const r of d.ranges) if (r.author.user_id === id) return r.author.name
  for (const t of s.threads) for (const m of t.messages) if (m.user.user_id === id) return m.user.name
  return id
}

/** doc path -> doc id, from the project's folder tree. */
function docPaths(pid: string): Record<string, string> {
  return mongo(`
    const out = {}
    const walk = (f, pre) => {
      for (const d of f.docs || []) out[pre + d.name] = d._id.toString()
      for (const sub of f.folders || []) walk(sub, pre + sub.name + '/')
    }
    walk(db.projects.findOne({_id: ObjectId(${JSON.stringify(pid)})}).rootFolder[0], '')
    return out`)
}

// ---------- check ----------

async function check(name: string) {
  const dir = join(replicas, name)
  const s: Snapshot = JSON.parse(readFileSync(join(dir, 'snapshot.json'), 'utf8'))
  const rep = JSON.parse(readFileSync(join(dir, 'replica.json'), 'utf8'))
  const nameFor = (orig: string) => rep.users[orig]
  const e = new Engine(['--url', rep.server, '--env-file', envFile, '--user', 'user1'])
  await e.start()
  const problems: string[] = []
  try {
    e.call('project.open', { project_id: rep.project_id })
    const emails: Record<string, string> = {}
    for (const k of ['ADMIN', 'USER1', 'USER2']) emails[env()[`OVERLEAF_${k}_ID`]] = env()[`OVERLEAF_${k}_EMAIL`]
    const ceEmail = (id: string) => emails[id] ?? mongo(`return db.users.findOne({_id: ObjectId(${JSON.stringify(id)})}).email`)
    let n = { changes: 0, comments: 0 }
    for (const d of s.docs) {
      const open = e.call('doc.open', { project_id: rep.project_id, path: d.path })
      if (open.text !== d.text) problems.push(`${d.path}: text differs`)
      const got: Range[] = e.call('doc.ranges', { doc_id: open.doc_id }).ranges
      const key = (r: Range, who: string) => `${r.kind} ${r.start}-${r.end} ${JSON.stringify(r.text)} ${who} ${r.kind === 'comment' ? '' : r.ts}`
      const want = d.ranges.map(r => key(r, r.kind === 'comment' ? '' : nameFor(r.author.user_id))).sort()
      const have = got.map(r => key(r, r.kind === 'comment' ? '' : ceEmail(r.author.user_id))).sort()
      for (const w of want) if (!have.includes(w)) problems.push(`${d.path}: missing ${w.slice(0, 120)}`)
      for (const h of have) if (!want.includes(h)) problems.push(`${d.path}: unexpected ${h.slice(0, 120)}`)
      n.changes += got.filter(r => r.kind !== 'comment').length
      n.comments += got.filter(r => r.kind === 'comment').length
    }
    const tl = e.call('thread.list', { project_id: rep.project_id })
    if (!tl.supported) problems.push('CE has no thread routes: run harness/ce-threads/install.sh')
    for (const t of s.threads) {
      const g = tl.threads.find((x: any) => x.thread_id === t.thread_id)
      if (!g) { problems.push(`thread ${t.thread_id} missing`); continue }
      if (g.path !== t.path || g.start !== t.start || g.end !== t.end) problems.push(`thread ${t.thread_id} at ${g.path}:${g.start}-${g.end}, not ${t.path}:${t.start}-${t.end}`)
      if (g.resolved !== t.resolved) problems.push(`thread ${t.thread_id} resolved=${g.resolved}`)
      const want = t.messages.map(m => `${m.ts} ${nameFor(m.user.user_id)} ${m.text}`)
      const have = g.messages.map((m: any) => `${m.ts} ${ceEmail(m.user.user_id)} ${m.text}`)
      if (JSON.stringify(want) !== JSON.stringify(have)) problems.push(`thread ${t.thread_id} messages differ:\n    want ${JSON.stringify(want)}\n    have ${JSON.stringify(have)}`)
    }
    const c = count(s)
    console.log(`snapshot: ${c.changes} tracked changes, ${c.comments} comments, ${s.threads.length} threads`)
    console.log(`replica:  ${n.changes} tracked changes, ${n.comments} comments, ${tl.threads.length} threads`)
    e.call('project.forget', { project_id: rep.project_id })
  } finally {
    e.stop()
  }
  if (problems.length) {
    console.log(`${problems.length} problems:\n  ${problems.join('\n  ')}`)
    process.exit(1)
  }
  console.log('positions, authors, times, texts and threads match')
}

// ---------- main ----------

const [cmd, ...rest] = process.argv.slice(2)
const opt = (k: string) => {
  const i = rest.indexOf(k)
  return i >= 0 ? rest.splice(i, 2)[1] : undefined
}
if (!existsSync(taudot)) execFileSync('cargo', ['build', '-q', '-p', 'taudot-engine'], { cwd: repo, stdio: 'inherit' })
if (cmd === 'snapshot') {
  const from = opt('--from'), to = opt('--to')
  if (!from || !to) throw new Error('snapshot --from <project id> --to <name>')
  await snapshot(from, to)
} else if (cmd === 'build') {
  const title = opt('--title')
  const name = rest[0]
  if (!name) throw new Error('build <name> [--title ...]')
  const s = JSON.parse(readFileSync(join(replicas, name, 'snapshot.json'), 'utf8'))
  await build(name, title ?? `${s.meta.name} (replica)`)
} else if (cmd === 'check') {
  await check(rest[0])
} else {
  console.log(readFileSync(new URL(import.meta.url), 'utf8').split('\n').slice(0, 20).join('\n'))
  process.exit(cmd ? 1 : 0)
}
