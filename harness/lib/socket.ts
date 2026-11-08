// A raw socket.io 0.9 client for Overleaf's real-time service, for protocol tests that need exact control of what
// goes over the socket (versions, timing, raw op text). The browser harness (overleaf.ts) is the reference client;
// this one is the probe. See docs/protocol.md "Connecting".
import type { TestUser } from './env.ts'

export type Event = { t: number; name: string; args: any[] }

/** Log in through the web form API and return the session cookie header ("overleaf.sid=..."). */
export async function login(baseUrl: string, user: TestUser): Promise<string> {
  const jar = new Map<string, string>()
  const keep = (res: Response) => {
    for (const c of res.headers.getSetCookie()) {
      const [kv] = c.split(';')
      const i = kv.indexOf('=')
      jar.set(kv.slice(0, i), kv.slice(i + 1))
    }
  }
  const cookie = () => [...jar].map(([k, v]) => `${k}=${v}`).join('; ')
  const csrf = async (path: string) => {
    const res = await fetch(`${baseUrl}/${path}`, { headers: { cookie: cookie() }, redirect: 'manual' })
    keep(res)
    return (await res.text()).match(/name="ol-csrfToken" content="([^"]*)"/)?.[1]
  }
  const token = await csrf('login')
  if (!token) throw new Error('no CSRF token on /login')
  const res = await fetch(`${baseUrl}/login`, {
    method: 'POST',
    redirect: 'manual',
    headers: { cookie: cookie(), 'content-type': 'application/json', 'x-csrf-token': token },
    body: JSON.stringify({ email: user.email, password: user.password }),
  })
  keep(res) // login rotates the session ID
  if (res.status >= 400) throw new Error(`login failed: ${res.status} ${await res.text()}`)
  return cookie()
}

/** One socket.io 0.9 connection to a project, joined with the ?projectId= style. */
export class RealtimeClient {
  ws!: WebSocket
  events: Event[] = []
  /** Every frame, both directions, for traces. */
  frames: { t: number; dir: 'sent' | 'recv'; data: string }[] = []
  publicId: string | undefined
  project: any
  closed = false
  private nextId = 1
  private acks = new Map<number, (args: any[]) => void>()
  private waiters: (() => void)[] = []

  baseUrl: string
  cookie: string
  constructor(baseUrl: string, cookie: string) {
    this.baseUrl = baseUrl
    this.cookie = cookie
  }

  async connect(projectId: string, timeoutMs = 30_000): Promise<void> {
    const res = await fetch(`${this.baseUrl}/socket.io/1/?projectId=${projectId}&t=${Date.now()}`, {
      headers: { cookie: this.cookie },
    })
    const body = await res.text()
    const sid = body.split(':')[0]
    if (!res.ok || !sid) throw new Error(`handshake failed: ${res.status} ${body}`)
    const wsUrl = this.baseUrl.replace(/^http/, 'ws') + `/socket.io/1/websocket/${sid}?projectId=${projectId}`
    // Node's WebSocket (undici) takes extra headers in its second argument.
    this.ws = new WebSocket(wsUrl, { headers: { cookie: this.cookie } } as any)
    this.ws.onmessage = m => this.onFrame(String(m.data))
    this.ws.onclose = () => {
      this.closed = true
      this.wake()
    }
    const ev = await this.waitEvent(e => e.name === 'joinProjectResponse' || e.name === 'connectionRejected', timeoutMs)
    if (ev.name === 'connectionRejected') throw new Error(`connectionRejected ${JSON.stringify(ev.args)}`)
    this.publicId = ev.args[0]?.publicId
    this.project = ev.args[0]?.project
  }

  close(): void {
    try {
      this.send('0::')
      this.ws.close()
    } catch {}
  }

  /** Emit an event with an ack and resolve with the ack's arguments ([err, ...results]). */
  emit(name: string, ...args: any[]): Promise<any[]> {
    const id = this.nextId++
    return new Promise((resolve, reject) => {
      this.acks.set(id, resolve)
      try {
        this.send(`5:${id}+::${JSON.stringify({ name, args })}`)
      } catch (e) {
        reject(e)
      }
    })
  }

  /** joinDoc, returning the ack's results by name. */
  async joinDoc(docId: string, fromVersion = -1, options: object = { encodeRanges: true, supportsHistoryOT: true }) {
    const [err, lines, version, ops, ranges, type, extra] = await this.emit('joinDoc', docId, fromVersion, options)
    if (err) throw new Error(`joinDoc: ${JSON.stringify(err)}`)
    return { lines, version, ops, ranges, type: type ?? 'sharejs-text-ot', extra }
  }

  /** applyOtUpdate; resolves with the ack's error (null when queued). Not a confirmation, see docs/protocol.md. */
  async applyOtUpdate(docId: string, update: object): Promise<any> {
    const [err] = await this.emit('applyOtUpdate', docId, update)
    return err ?? null
  }

  /** Wait for an event matching pred, looking at events already received from index `from` on. */
  async waitEvent(pred: (e: Event) => boolean, timeoutMs = 10_000, from = 0): Promise<Event> {
    const end = Date.now() + timeoutMs
    for (;;) {
      const found = this.events.slice(from).find(pred)
      if (found) return found
      if (this.closed) throw new Error('socket closed while waiting')
      const left = end - Date.now()
      if (left <= 0) throw new Error('timed out waiting for event')
      await new Promise<void>(r => {
        const t = setTimeout(r, left)
        this.waiters.push(() => {
          clearTimeout(t)
          r()
        })
      })
    }
  }

  /** Our own confirmations for a doc: otUpdateApplied without an op. */
  confirmations(docId: string): Event[] {
    return this.events.filter(e => e.name === 'otUpdateApplied' && e.args[0]?.doc === docId && !e.args[0]?.op)
  }

  /** Others' ops for a doc: otUpdateApplied with an op. */
  remoteOps(docId: string): Event[] {
    return this.events.filter(e => e.name === 'otUpdateApplied' && e.args[0]?.doc === docId && e.args[0]?.op)
  }

  errors(): Event[] {
    return this.events.filter(e => ['otUpdateError', 'connectionRejected', 'forceDisconnect'].includes(e.name))
  }

  private send(data: string): void {
    this.frames.push({ t: Date.now(), dir: 'sent', data })
    this.ws.send(data)
  }

  private wake(): void {
    const w = this.waiters
    this.waiters = []
    for (const f of w) f()
  }

  // Frames are "type:id:endpoint:data": 1 connect, 2 heartbeat, 5 event, 6 ack, 0 disconnect.
  private onFrame(data: string): void {
    this.frames.push({ t: Date.now(), dir: 'recv', data })
    const m = data.match(/^(\d):([^:]*):[^:]*:?(.*)$/s)
    if (!m) return
    const [, type, , body] = m
    if (type === '2') this.send('2::')
    else if (type === '0') this.closed = true
    else if (type === '5') {
      const msg = JSON.parse(body)
      this.events.push({ t: Date.now(), name: msg.name, args: msg.args ?? [] })
    } else if (type === '6') {
      const am = body.match(/^(\d+)\+?(.*)$/s)
      if (am) {
        const cb = this.acks.get(Number(am[1]))
        this.acks.delete(Number(am[1]))
        cb?.(JSON.parse(am[2] || '[]'))
      }
    }
    this.wake()
  }
}

/** Find a doc's ID by path ("sections/intro.tex") in a joinProjectResponse project tree. */
export function docIdByPath(project: any, path: string): string {
  let folder = project.rootFolder[0]
  const parts = path.split('/')
  for (const p of parts.slice(0, -1)) {
    folder = folder.folders.find((f: any) => f.name === p)
    if (!folder) throw new Error(`no folder ${p}`)
  }
  const doc = folder.docs.find((d: any) => d.name === parts.at(-1))
  if (!doc) throw new Error(`no doc ${path}`)
  return doc._id
}

/** Text of a joined doc: classic lines are UTF-8 packed in Latin-1; history-ot sends {content, ...} raw. */
export function joinedText(j: { lines: any; type: string }): string {
  if (j.type === 'history-ot') return j.lines.content
  return decodeURIComponent(escape((j.lines as string[]).join('\n')))
}

/** Git blob SHA-1 of a doc, as sharejs computes its hash: length in UTF-16 units, content as UTF-8. */
export async function shareJsHash(text: string): Promise<string> {
  const { createHash } = await import('node:crypto')
  return createHash('sha1').update('blob ' + text.length + '\x00').update(text, 'utf8').digest('hex')
}
