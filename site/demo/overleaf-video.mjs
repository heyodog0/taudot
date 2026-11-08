// Bob in Overleaf's own browser editor (local CE only, headless Chrome), typing with the keyboard at a human pace
// while Playwright records the page. Prints the wall-clock time the video starts and when typing starts, so the take
// can be lined up with the Taudot window recording.
//   node site/demo/overleaf-video.mjs PROJECT_ID AFTER TEXT OUT_DIR     (WAIT ms before typing, default 3000)
import { createRequire } from 'node:module'
import { readFileSync, mkdirSync } from 'node:fs'
const harness = process.env.HARNESS || `${process.env.HOME}/code/lab/taudot/harness`
const { chromium } = createRequire(`${harness}/package.json`)('playwright')
const [project, after, text, out] = process.argv.slice(2)
const env = Object.fromEntries(readFileSync(process.env.TAUDOT_ENV_FILE || `${process.env.HOME}/code/lab/taudot/docker/.env.test`, 'utf8')
  .split('\n').filter(l => l.includes('=')).map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]))
const base = env.OVERLEAF_URL
if (!/^http:\/\/(localhost|127\.0\.0\.1):/.test(base)) throw new Error('local CE only')
mkdirSync(out, { recursive: true })
const sleep = ms => new Promise(r => setTimeout(r, ms))

const browser = await chromium.launch({ channel: 'chrome', headless: true })
// Log in first in a context without video, then reuse its cookies, so the video starts on the editor.
const login = await browser.newContext()
const lp = await login.newPage()
await lp.goto(`${base}/login`)
await lp.locator('input[name="email"]').fill(env.OVERLEAF_USER2_EMAIL)
await lp.locator('input[name="password"]').fill(env.OVERLEAF_USER2_PASSWORD)
await Promise.all([lp.waitForURL(u => !u.pathname.startsWith('/login'), { timeout: 30000 }), lp.locator('button[type="submit"]').first().click()])
const cookies = await login.cookies()
await login.close()

const ctx = await browser.newContext({ viewport: { width: 1200, height: 800 }, deviceScaleFactor: 2,
  recordVideo: { dir: out, size: { width: 1200, height: 800 } } })
await ctx.addCookies(cookies)
const page = await ctx.newPage()
const t0 = Date.now()
await page.goto(`${base}/project/${project}`)
await page.locator('.cm-content').first().waitFor({ timeout: 120000 })
await sleep(2500)
// The caret after AFTER, through CodeMirror, then scrolled into the middle of the editor.
const pos = await page.evaluate(after => {
  const c = document.querySelector('.cm-content')
  const view = c?.cmView?.view ?? c?.cmView?.rootView?.view ?? c?.cmTile?.view
  const i = view.state.doc.toString().indexOf(after)
  if (i < 0) return -1
  view.focus()
  view.dispatch({ selection: { anchor: i + after.length }, scrollIntoView: true })
  return i + after.length
}, after)
if (pos < 0) throw new Error(`no "${after}"`)
await sleep(Number(process.env.WAIT || 3000))
const t1 = Date.now()
for (const ch of text) {
  await page.keyboard.type(ch)
  await sleep(70 + Math.random() * 80 + (ch === ' ' ? 40 : 0) + (/[,.]/.test(ch) ? 180 : 0))
}
await sleep(2500)
const video = page.video()
await ctx.close()
console.log(JSON.stringify({ videoStart: t0, typingStart: t1, end: Date.now(), path: await video.path() }))
await browser.close()
