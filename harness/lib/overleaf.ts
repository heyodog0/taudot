// Drives Overleaf's own browser editor (CodeMirror 6) against the local CE.
// Edits go through the real editor, so they reach the server exactly as a person's would.
import { chromium, type Browser, type BrowserContext, type Page, type WebSocket } from 'playwright'
import type { TestUser } from './env.ts'

export type Frame = { t: number; dir: 'sent' | 'recv'; data: string }

export type Edit =
  | { pos: number; text: string } // insert text at pos
  | { pos: number; del: number } // delete del characters from pos

export type OpenOptions = {
  headed?: boolean
  /** Keep every socket frame, for protocol investigations. */
  trace?: boolean
}

/**
 * Positions are CodeMirror positions, which are JavaScript string indexes (UTF-16 code units), the same unit as
 * sharejs-text-ot positions. An emoji counts as 2.
 */
export class OverleafEditor {
  browser!: Browser
  context!: BrowserContext
  page!: Page
  frames: Frame[] = []
  /** The doc ID of the most recently joined doc. */
  docId: string | undefined
  /** The version the server last confirmed or broadcast for docId. */
  version: number | undefined
  /** Edit format of the joined doc, from the joinDoc response. */
  docType: string | undefined
  connectionId: string | undefined
  private sent = 0
  private confirmed = 0
  private lastActivity = Date.now()
  private lastEditAt = 0
  private lastSendAt = 0
  private ackNames = new Map<string, string>()
  private errors: string[] = []
  /** Uncaught exceptions in the page, such as the history-ot ApplyError after an emoji. */
  pageErrors: string[] = []
  private trace = false

  readonly baseUrl: string

  constructor(baseUrl: string) {
    this.baseUrl = baseUrl
  }

  async launch(opts: OpenOptions = {}): Promise<void> {
    this.trace = !!opts.trace
    // Installed Chrome with its sandbox on: Playwright's bundled Chromium lags Chrome's security fixes.
    this.browser = await chromium.launch({ channel: 'chrome', chromiumSandbox: true, headless: !opts.headed })
    this.context = await this.browser.newContext({ viewport: { width: 1400, height: 900 } })
    this.page = await this.context.newPage()
    this.page.on('websocket', ws => this.watchSocket(ws))
    this.page.on('pageerror', e => this.pageErrors.push(String(e)))
  }

  async close(): Promise<void> {
    await this.browser?.close()
  }

  /** Use an existing session cookie ("overleaf.sid=...") instead of logging in, to stay under the login rate limit. */
  async useCookie(cookie: string): Promise<void> {
    const url = new URL(this.baseUrl)
    await this.context.addCookies(
      cookie.split('; ').map(kv => {
        const i = kv.indexOf('=')
        return { name: kv.slice(0, i), value: kv.slice(i + 1), domain: url.hostname, path: '/' }
      })
    )
  }

  async login(user: TestUser): Promise<void> {
    const page = this.page
    await page.goto(`${this.baseUrl}/login`)
    await page.locator('input[name="email"]').fill(user.email)
    await page.locator('input[name="password"]').fill(user.password)
    await Promise.all([
      page.waitForURL(u => !u.pathname.startsWith('/login'), { timeout: 30_000 }),
      page.locator('button[type="submit"]').first().click(),
    ])
  }

  /** Open a project and the given file (path relative to the project root, e.g. "sections/intro.tex"). */
  async open(projectId: string, file: string): Promise<void> {
    const page = this.page
    await page.goto(`${this.baseUrl}/project/${projectId}`)
    await page.locator('.cm-content').first().waitFor({ timeout: 120_000 })
    await this.waitFor(() => this.docId !== undefined, 60_000, 'first joinDoc')
    const parts = file.split('/')
    const tree = page.locator('[role="tree"]').first()
    for (let i = 0; i < parts.length; i++) {
      const item = tree.getByRole('treeitem', { name: parts[i], exact: true }).first()
      await item.waitFor({ timeout: 30_000 })
      if (i < parts.length - 1) {
        if ((await item.getAttribute('aria-expanded')) !== 'true') await item.click()
      } else if ((await item.getAttribute('aria-selected')) !== 'true') {
        const before = this.docId
        await item.click()
        await this.waitFor(() => this.docId !== before, 30_000, `joinDoc for ${file}`)
      }
    }
    // Let the editor render the joined doc.
    await page.waitForTimeout(300)
    await this.text()
  }

  /** The editor's current text. */
  async text(): Promise<string> {
    return await this.page.evaluate(() => {
      const content = document.querySelector('.cm-content') as any
      const view = content?.cmView?.view ?? content?.cmView?.rootView?.view ?? content?.cmTile?.view
      if (!view) throw new Error('cannot find the CodeMirror EditorView on .cm-content')
      return view.state.doc.toString() as string
    })
  }

  /**
   * Apply edits through CodeMirror, one transaction each, in order. Each sees the result of the ones before.
   * mode "dispatch" makes an exact change as a user input event. mode "keys" moves the cursor and types with the
   * keyboard, which is closer to a person but lets editor features (auto-close brackets, auto-indent on Enter)
   * change what lands.
   */
  async edit(edits: Edit[], mode: 'dispatch' | 'keys' = 'dispatch'): Promise<void> {
    for (let e of edits) {
      // The editor replaces each surrogate code unit with U+FFFD on input (filter-characters.ts), so an emoji
      // lands as two U+FFFD. Do the same up front: a dispatched change with surrogates makes the browser's
      // history-ot code throw "base length must be equal to the string's length" (seen on CE 6.3.0).
      if (mode === 'dispatch' && 'text' in e) e = { pos: e.pos, text: e.text.replace(/[\0\uD800-\uDFFF]/g, '\uFFFD') }
      if ("text" in e ? e.text === "" : e.del === 0) continue // no change, nothing will be sent
      if (mode === 'dispatch') {
        await this.page.evaluate(e => {
          const content = document.querySelector('.cm-content') as any
          const view = content?.cmView?.view ?? content?.cmView?.rootView?.view ?? content?.cmTile?.view
          const len = view.state.doc.length
          if (e.pos < 0 || e.pos > len) throw new Error(`pos ${e.pos} outside doc of length ${len}`)
          if ('text' in e) {
            view.dispatch({
              changes: { from: e.pos, insert: e.text },
              selection: { anchor: e.pos + e.text.length },
              userEvent: 'input.type',
            })
          } else {
            if (e.pos + e.del > len) throw new Error(`delete ${e.pos}+${e.del} outside doc of length ${len}`)
            view.dispatch({ changes: { from: e.pos, to: e.pos + e.del }, userEvent: 'delete' })
          }
        }, e)
      } else {
        await this.page.evaluate(pos => {
          const content = document.querySelector('.cm-content') as any
          const view = content?.cmView?.view ?? content?.cmView?.rootView?.view ?? content?.cmTile?.view
          view.focus()
          view.dispatch({ selection: { anchor: pos } })
        }, e.pos)
        if ('text' in e) await this.page.keyboard.type(e.text)
        else for (let i = 0; i < e.del; i++) await this.page.keyboard.press('Delete')
      }
      this.lastActivity = Date.now()
      this.lastEditAt = Date.now()
    }
  }

  /**
   * Wait until the browser has sent its buffered edits and the server has confirmed every one
   * (otUpdateApplied without an op, sent only to the sender).
   */
  async settle(quietMs = 500, timeoutMs = 30_000): Promise<void> {
    await this.waitFor(
      // The browser holds edits for about 2 s before sending. A send after the last edit carries every edit
      // made so far (sharejs moves all pending ops into the next inflight op). With --keys the browser may send
      // everything while keys are still being typed, so a quiet spell well past that delay also counts.
      () =>
        (this.lastSendAt >= this.lastEditAt || Date.now() - this.lastEditAt > 3500) &&
        this.sent === this.confirmed &&
        Date.now() - this.lastActivity > quietMs,
      timeoutMs,
      () => `confirmations (sent ${this.sent}, confirmed ${this.confirmed})`
    )
    if (this.errors.length) throw new Error(`server errors: ${this.errors.join('; ')}`)
  }

  /** Server-side errors seen on the socket (otUpdateError, connectionRejected, ...). */
  serverErrors(): string[] {
    return [...this.errors]
  }

  private async waitFor(cond: () => boolean, timeoutMs: number, describe: string | (() => string)): Promise<void> {
    const end = Date.now() + timeoutMs
    while (!cond()) {
      const what = typeof describe === "string" ? describe : describe()
      if (Date.now() > end) throw new Error(`timed out waiting for ${what}`)
      if (this.errors.length) throw new Error(`server errors while waiting for ${what}: ${this.errors.join('; ')}`)
      await new Promise(r => setTimeout(r, 50))
    }
  }

  // socket.io 0.9 frames look like "type:id:endpoint:data", e.g. 5:3+::{"name":"joinDoc","args":[...]} and
  // the ack 6:::3+[null, lines, version, ...]. See docs/protocol.md.
  private watchSocket(ws: WebSocket): void {
    ws.on('framesent', f => this.onFrame('sent', String(f.payload)))
    ws.on('framereceived', f => this.onFrame('recv', String(f.payload)))
  }

  private onFrame(dir: 'sent' | 'recv', data: string): void {
    if (this.trace) this.frames.push({ t: Date.now(), dir, data })
    const m = data.match(/^(\d):([^:]*):[^:]*:?(.*)$/s)
    if (!m) return
    const [, type, id, body] = m
    if (type === '5') {
      let msg: { name: string; args: any[] }
      try {
        msg = JSON.parse(body)
      } catch {
        return
      }
      if (dir === 'sent') {
        if (id) this.ackNames.set(id.replace('+', ''), msg.name)
        if (msg.name === 'applyOtUpdate') {
          this.lastActivity = Date.now()
          this.lastSendAt = Date.now()
          const update = msg.args[1]
          if (!update?.dupIfSource) this.sent++
        }
      } else {
        this.onEvent(msg.name, msg.args)
      }
    } else if (type === '6' && dir === 'recv') {
      const am = body.match(/^(\d+)\+?(.*)$/s)
      if (!am) return
      const name = this.ackNames.get(am[1])
      let args: any[] = []
      try {
        args = JSON.parse(am[2] || '[]')
      } catch {}
      if (name === 'joinDoc') {
        if (args[0]) this.errors.push(`joinDoc: ${JSON.stringify(args[0])}`)
        else {
          // [err, lines, version, ops, ranges, type, ...]
          this.version = args[2]
          this.docType = args[5] ?? 'sharejs-text-ot'
          this.docId = this.pendingJoin
        }
      }
    }
    if (type === '5' && dir === 'sent') {
      try {
        const msg = JSON.parse(body)
        if (msg.name === 'joinDoc') this.pendingJoin = msg.args[0]
      } catch {}
    }
  }

  private pendingJoin: string | undefined

  private onEvent(name: string, args: any[]): void {
    switch (name) {
      case 'connectionAccepted':
        this.connectionId = args[1]
        break
      case 'joinProjectResponse':
        this.connectionId = args[0]?.publicId ?? this.connectionId
        break
      case 'otUpdateApplied': {
        const u = args[0]
        if (u?.doc === this.docId && typeof u.v === 'number') this.version = u.v + 1
        if (u && u.op === undefined && u.doc === this.docId) {
          this.confirmed++
          this.lastActivity = Date.now()
        }
        break
      }
      case 'otUpdateError':
      case 'connectionRejected':
      case 'forceDisconnect':
        this.errors.push(`${name}: ${JSON.stringify(args)}`)
        break
    }
  }
}
