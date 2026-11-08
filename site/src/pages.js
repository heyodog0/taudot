/* The pages: the landing page (what Taudot is, the waitlist, the clips), the privacy policy, the terms and the /source
   stub. One narrow column on a flat ground, small type, one framed panel for the clips (Superlogical's way of
   presenting, Glideshow's light/dark switch), in Taudot's own palette (clients/mac/Sources/TaudotShared/TaudotPalette.swift).
   Coral #ff5e4d means "you": only the icon's dot. No frameworks, no third-party anything. */

const CONTACT = 'heyodogo@gmail.com';   // the user's choice (2026-11-05); removal requests and questions
const ORIGIN = 'https://taudot.app';

/* The clips (public/clips/<id>.mp4 and .jpg poster, made by tools/camera.py), shown one at a time in the panel. `ready: false` shows an
   empty window until it's recorded. The fourth waits until "ours equals Overleaf's" is verified (docs/agents/site.md). */
export const CLIPS = [
  { id: 'type', ready: true, label: 'No compile button', caption: 'Type, and the PDF beside it follows.' },
  { id: 'coauthor', ready: true, label: 'Coauthors, live', caption: 'Your coauthor types in Overleaf in the browser. Each keystroke shows up in Taudot, and the PDF follows.' },
  { id: 'comment', ready: true, label: 'Comments in the margin', caption: 'Overleaf comments arrive as cards beside your text. Reply right there.' },
  { id: 'pdfnote', ready: true, label: 'Comments on the PDF', caption: 'Click a comment in the PDF and reply without leaving it.' },
  { id: 'sync', ready: true, label: 'PDF and source, both ways', caption: 'Double-click the PDF to jump to that line, on any page. Click a line and press ⌥⌘J to find it in the PDF.' },
  { id: 'claude', ready: true, label: 'Fix errors with Claude', caption: 'One click hands LaTeX errors to Claude Code in a floating pane. It fixes them, and the PDF comes back.' },
  { id: 'same-pdf', ready: false, hidden: true, label: 'The same PDF', caption: "Page for page, the PDF Overleaf makes." },
];

export const esc = s => String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

/* The icon, flat and inline so its parts can move: the tau draws itself in, the dot drops into place, then hops now
   and then (and on hover: the hover hop is on a wrapper, so the dot's own animations never restart and it never blinks out). public/mark.svg is the same drawing, still, for the favicon. */
const ICON = `<a class="icon" href="/" aria-label="Taudot home"><svg viewBox="0 0 1024 1024" aria-hidden="true">
<rect class="tile" width="1024" height="1024" rx="232"/>
<g transform="translate(500 520) scale(.8) translate(-560 -525)"><g class="tau" transform="translate(-110 -10) rotate(12 520 760)">
<path pathLength="1" d="M262 420 C 270 330, 320 300, 400 300 L 770 300" stroke-width="150"/>
<path pathLength="1" d="M560 330 C 552 480, 552 590, 600 680 C 636 748, 700 760, 760 744" stroke-width="142"/></g>
<g class="hopper"><circle class="dot" cx="836" cy="628" r="118"/></g></g></svg></a>
<script>for (const a of document.querySelectorAll('.icon')) {
  const g = a.querySelector('.hopper');   // the hover hop runs on its own and always finishes, so leaving never cuts it
  a.addEventListener('mouseenter', () => g.classList.add('hopping'));
  g.addEventListener('animationend', () => g.classList.remove('hopping'));
}</script>`;

const MOON = '<svg class="moon" viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>';
const SUN = '<svg class="sun" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4.5" fill="currentColor"/><g stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M12 2v2.5M12 19.5V22M2 12h2.5M19.5 12H22M4.9 4.9l1.8 1.8M17.3 17.3l1.8 1.8M4.9 19.1l1.8-1.8M17.3 6.7l1.8-1.8"/></g></svg>';

const LIGHT = `--ground: #f4f7f5; --ink: #0b2a30; --muted: #6f8784; --faint: #a9bab6; --line: rgba(11, 42, 48, .12); --field: #fff;
  --accent: #0b7a68; --tile: #0f5f5a; --hover: rgba(11, 42, 48, .05); --err: #a3322a; --window: #fbfdfc; --chrome: #e8efec;
  --panel: linear-gradient(180deg, #a6ead6 0%, #4fcaa9 38%, #8fdc8a 70%, #d9f48c 100%); --grain-blend: multiply; --grain: .07;`;
const DARK = `--ground: #061a1d; --ink: #e3efeb; --muted: #87a29e; --faint: #4f6966; --line: rgba(255, 255, 255, .11); --field: rgba(255, 255, 255, .04);
  --accent: #c8f36a; --tile: #13675d; --hover: rgba(255, 255, 255, .06); --err: #ff9b8f; --window: #0a2328; --chrome: #0f3036;
  --panel: linear-gradient(180deg, #0f3d44 0%, #146a5e 45%, #3f8a55 75%, #8fb44a 100%); --grain-blend: overlay; --grain: .10; color-scheme: dark;`;

const grain = `url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.9' numOctaves='2' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)' opacity='.5'/%3E%3C/svg%3E")`;

const CSS = `:root { ${LIGHT} }
@media (prefers-color-scheme: dark) { :root:not([data-theme=light]) { ${DARK} } }
:root[data-theme=dark] { ${DARK} }
* { box-sizing: border-box; }
html { background: var(--ground); }
body { margin: 0; min-height: 100vh; padding: clamp(40px, 10vh, 96px) 20px 32px; display: flex; flex-direction: column; align-items: center;
  color: var(--ink); font: 400 15px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; letter-spacing: -.005em;
  -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility; }
body::after { content: ""; position: fixed; inset: 0; pointer-events: none; opacity: var(--grain); mix-blend-mode: var(--grain-blend); background-image: ${grain}; }
.col { width: min(520px, 100%); display: grid; gap: 20px; }
a { color: inherit; text-decoration-color: var(--faint); text-underline-offset: 3px; text-decoration-thickness: 1px; }
a:hover { text-decoration-color: currentColor; }
a:focus-visible, button:focus-visible, input:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; border-radius: 6px; }
p { margin: 0; }

.icon { display: block; width: 40px; height: 40px; margin-bottom: 8px; }
.icon svg { display: block; width: 100%; height: 100%; overflow: visible; }
.icon .tile { fill: var(--tile); }
.icon .tau { fill: none; stroke: #fff; stroke-linecap: round; stroke-linejoin: round; }
.icon .tau path { stroke-dasharray: 1 2; stroke-dashoffset: 1; animation: draw .65s cubic-bezier(.6, 0, .25, 1) .1s forwards; }
.icon .tau path + path { animation-delay: .35s; }
.icon .dot { fill: #ff5e4d; transform-box: fill-box; transform-origin: 50% 100%; animation: drop .55s cubic-bezier(.3, 1.5, .5, 1) .85s both, hop 9s ease-in-out 3s infinite; }
.icon .hopper { transform-box: fill-box; transform-origin: 50% 100%; will-change: transform; }
.icon .hopper.hopping { animation: hop2 .7s; }
@keyframes draw { from { stroke-dashoffset: 1; opacity: 0; } 8% { opacity: 1; } to { stroke-dashoffset: 0; opacity: 1; } }
@keyframes drop { from { transform: translateY(-140%) scale(.5); opacity: 0; } 60% { opacity: 1; } }
/* A hop like a bounce: squash, launch slowing to the top, fall speeding up, squash on landing, settle. */
@keyframes hop { 0%, 92.2% { transform: none; animation-timing-function: ease-out; }
  93.1% { transform: scale(1.12, .88); animation-timing-function: cubic-bezier(.3, .6, .5, 1); }
  95.7% { transform: translateY(-70%) scale(.95, 1.05); animation-timing-function: cubic-bezier(.5, 0, .8, .4); }
  97.8% { transform: scale(1.1, .9); animation-timing-function: ease-out; } 98.9% { transform: scale(.97, 1.03); } 100% { transform: none; } }
@keyframes hop2 { 0% { transform: none; animation-timing-function: ease-out; }
  12% { transform: scale(1.12, .88); animation-timing-function: cubic-bezier(.3, .6, .5, 1); }
  45% { transform: translateY(-70%) scale(.95, 1.05); animation-timing-function: cubic-bezier(.5, 0, .8, .4); }
  72% { transform: scale(1.1, .9); animation-timing-function: ease-out; } 86% { transform: scale(.97, 1.03); } 100% { transform: none; } }

h1 { margin: 0; font-size: 21px; line-height: 1.3; font-weight: 500; letter-spacing: -.015em; }
h1 span { display: block; color: var(--muted); font-weight: 400; }

form { display: flex; align-items: center; gap: 4px; padding: 4px 4px 4px 14px; border: 1px solid var(--line); border-radius: 12px; background: var(--field); }
form:focus-within { border-color: var(--accent); }
input[type=email] { flex: 1; min-width: 0; font: inherit; border: 0; padding: 6px 0; background: none; color: var(--ink); outline: none; }
input[type=email]::placeholder { color: var(--faint); }
form button { flex: none; font: inherit; font-weight: 500; padding: 6px 12px; border: 0; border-radius: 8px; background: none; color: var(--accent); cursor: pointer; }
form button:hover { background: var(--hover); }
.hp { position: absolute; left: -9999px; width: 1px; height: 1px; overflow: hidden; }
.note { font-size: 13px; color: var(--muted); margin-top: -10px; }
.err { color: var(--err); font-size: 13px; margin-top: -10px; }
.done { display: flex; gap: 10px; align-items: center; padding: 10px 14px; border: 1px solid var(--line); border-radius: 12px; animation: fade .4s ease-out; }
.done svg { flex: none; width: 16px; height: 16px; color: var(--accent); }
@keyframes fade { from { opacity: 0; transform: translateY(3px); } }

.panel { position: relative; width: min(680px, 100%); margin-top: 48px; padding: clamp(18px, 6%, 48px) clamp(14px, 7%, 56px) 0; border-radius: 14px; background: var(--panel); overflow: hidden; }
.panel::after { content: ""; position: absolute; inset: 0; pointer-events: none; background-image: ${grain}; mix-blend-mode: overlay; opacity: .45; }
.window { position: relative; z-index: 1; border-radius: 10px 10px 0 0; background: var(--window); box-shadow: 0 18px 50px rgba(3, 25, 28, .18), 0 0 0 1px rgba(3, 25, 28, .06); overflow: hidden; }
.bar { height: 26px; display: flex; gap: 6px; align-items: center; padding: 0 10px; background: #2b2b2b; }   /* the app records dark: its frame is dark in both themes */
.bar i { width: 9px; height: 9px; border-radius: 50%; background: rgba(255, 255, 255, .16); }
.screen { position: relative; aspect-ratio: 16 / 9; }
.screen > * { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; opacity: 0; transition: opacity .35s; }
.screen > .on { opacity: 1; }
.slot { display: grid; place-items: center; color: var(--faint); font-size: 12px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
.clips { width: min(520px, 100%); margin: 18px 0 0; padding: 0; list-style: none; display: grid; gap: 2px; counter-reset: c; }
.clips button { width: 100%; display: grid; grid-template-columns: 22px 1fr; text-align: left; font: inherit; color: var(--muted); background: none; border: 0; padding: 4px 0; cursor: pointer; }
.clips button::before { counter-increment: c; content: counter(c); color: var(--faint); }
.clips button[aria-pressed=true] { color: var(--ink); }
.clips button span { display: block; }
.clips small { display: none; color: var(--muted); font-size: 13.5px; }
.clips button[aria-pressed=true] small { display: block; }

footer { width: min(520px, 100%); margin-top: auto; padding-top: 72px; display: flex; gap: 18px; font: 12px/1 ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--muted); }
footer a { text-decoration: none; } footer a:hover { color: var(--ink); }
.doc p + p { margin-top: -6px; } .doc b { font-weight: 500; } .doc .date { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; letter-spacing: .08em; text-transform: uppercase; color: var(--muted); }

#theme-toggle { position: fixed; top: 14px; right: 14px; z-index: 2; width: 32px; height: 32px; display: grid; place-items: center; border: 0; border-radius: 50%; background: none; color: var(--muted); cursor: pointer; }
#theme-toggle:hover { color: var(--ink); background: var(--hover); } #theme-toggle svg { width: 16px; height: 16px; }
#theme-toggle .sun, :root[data-theme=dark] #theme-toggle .moon { display: none; } :root[data-theme=dark] #theme-toggle .sun { display: block; }
@media (prefers-color-scheme: dark) { :root:not([data-theme=light]) #theme-toggle .moon { display: none; } :root:not([data-theme=light]) #theme-toggle .sun { display: block; } }
/* The switch: the new theme grows out of the button as a circle (a view transition), and its icon turns in. */
::view-transition-old(root), ::view-transition-new(root) { animation: none; mix-blend-mode: normal; }
@keyframes turn { from { transform: rotate(-120deg) scale(.5); opacity: 0; } to { transform: none; opacity: 1; } }
.turning #theme-toggle svg { animation: turn .7s cubic-bezier(.65, 0, .35, 1); }
@media (max-width: 560px) { #theme-toggle { position: absolute; } .panel { margin-top: 32px; } }
@media (prefers-reduced-motion: reduce) { .icon .tau path, .icon .dot, .icon .hopper.hopping, .done, .turning #theme-toggle svg { animation: none; stroke-dashoffset: 0; } .screen > * { transition: none; } }`;

/* Theme: the system's, unless the switch was used (remembered in this browser only). */
const THEME = `<script>try { const v = localStorage.getItem('taudot-theme'); if (v) document.documentElement.dataset.theme = v; } catch {}</script>`;
const TOGGLE = `<button id="theme-toggle" type="button" aria-label="Switch light or dark">${MOON}${SUN}</button>
<script>{
  const root = document.documentElement, btn = document.getElementById('theme-toggle');
  const dark = () => root.dataset.theme ? root.dataset.theme === 'dark' : matchMedia('(prefers-color-scheme: dark)').matches;
  btn.onclick = () => {
    const to = dark() ? 'light' : 'dark', apply = () => { root.dataset.theme = to; try { localStorage.setItem('taudot-theme', to); } catch {} };
    if (!document.startViewTransition || matchMedia('(prefers-reduced-motion: reduce)').matches) return apply();
    const r = btn.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
    const end = Math.hypot(Math.max(x, innerWidth - x), Math.max(y, innerHeight - y));
    root.classList.add('turning');
    const t = document.startViewTransition(apply);
    t.ready.then(() => root.animate({ clipPath: [\`circle(0px at \${x}px \${y}px)\`, \`circle(\${end}px at \${x}px \${y}px)\`] },
      { duration: 700, easing: 'cubic-bezier(.65, 0, .35, 1)', pseudoElement: '::view-transition-new(root)' })).catch(() => {});
    t.finished.finally(() => root.classList.remove('turning'));
  };
}</script>`;

/* The clips: one shown at a time; the list below picks one. Videos load when the panel comes near, play while it is
   on screen, and move to the next clip when they end. Under reduced motion they don't play by themselves. */
const CLIP_JS = `<script>{
  const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const items = [...document.querySelectorAll('.screen > *')], tabs = [...document.querySelectorAll('.clips button')];
  let cur = 0, seen = false;
  const play = () => { const v = items[cur]; if (v.tagName !== 'VIDEO' || !seen) return;
    if (!v.dataset.loaded) { v.dataset.loaded = 1; v.querySelectorAll('source').forEach(s => s.src = s.dataset.src); v.load(); }
    if (!still) { v.currentTime = 0; v.play().catch(() => {}); } };
  const show = i => { items[cur].pause?.(); cur = i;
    items.forEach((el, j) => el.classList.toggle('on', j === i)); tabs.forEach((t, j) => t.setAttribute('aria-pressed', j === i)); play(); };
  tabs.forEach((t, i) => t.onclick = () => show(i));
  items.forEach((v, i) => { if (v.tagName === 'VIDEO') { if (still) v.controls = true; v.onended = () => show(items.length > 1 ? (i + 1) % items.length : i); } });
  new IntersectionObserver(([e]) => { seen = e.isIntersecting; seen ? play() : items[cur].pause?.(); }, { rootMargin: '150px' }).observe(document.querySelector('.panel'));
}</script>`;

function head(title, opts) {
  const full = title === 'Taudot' ? opts.full || title : `${title} · Taudot`;
  const desc = opts.description ? `<meta name="description" content="${esc(opts.description)}"><meta property="og:description" content="${esc(opts.description)}">` : '';
  const canon = opts.path ? `<link rel="canonical" href="${ORIGIN}${opts.path}"><meta property="og:url" content="${ORIGIN}${opts.path}">` : '';
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(full)}</title>${desc}${canon}<meta property="og:title" content="${esc(full)}"><meta property="og:type" content="website">
<meta name="theme-color" content="#f4f7f5" media="(prefers-color-scheme: light)"><meta name="theme-color" content="#061a1d" media="(prefers-color-scheme: dark)">
<link rel="icon" href="/mark.svg" type="image/svg+xml"><link rel="apple-touch-icon" href="/apple-touch-icon.png">
${THEME}<style>${CSS}</style></head>`;
}

function html(body, status = 200) {
  return new Response(body, { status, headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': status === 200 ? 'public, max-age=300' : 'no-store' } });
}

const foot = `<footer><a href="/">Taudot</a><a href="/privacy">Privacy</a><a href="/terms">Terms</a><a href="https://github.com/heyodog0/taudot">GitHub</a></footer>`;

const FORM = (email = '') => `<form method="post" action="/waitlist">
<label class="hp" aria-hidden="true">Leave this empty <input name="website" tabindex="-1" autocomplete="off"></label>
<input type="email" name="email" required maxlength="254" autocomplete="email" placeholder="Your email" aria-label="Email address" value="${esc(email)}">
<button type="submit">Join the waitlist</button></form>`;

const DONE = `<div class="done" role="status"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>
<span>You're on the list. One email when there's a build to try.</span></div>`;

function panel() {
  const shown = CLIPS.filter(c => !c.hidden);
  const media = shown.map((c, i) => c.ready
    ? `<video class="${i ? '' : 'on'}" muted playsinline ${shown.length === 1 ? 'loop ' : ''}preload="none" poster="/clips/${c.id}.jpg" aria-label="${esc(c.caption)}"><source data-src="/clips/${c.id}.mp4" type="video/mp4"></video>`
    : `<div class="slot ${i ? '' : 'on'}">clip to come</div>`).join('');
  const tabs = shown.map((c, i) => `<li><button type="button" aria-pressed="${i === 0}"><span>${esc(c.label)}<small>${esc(c.caption)}</small></span></button></li>`).join('');
  return `<div class="panel"><div class="window"><div class="bar"><i></i><i></i><i></i></div><div class="screen">${media}</div></div></div>
<ol class="clips">${tabs}</ol>${CLIP_JS}`;
}

/* The landing page. `err` and `email` come back from a form that didn't go through; `ok` after one that did. */
export function landing(err = '', status = 200, email = '', ok = false) {
  return html(`${head('Taudot', { path: '/', full: 'Taudot: write LaTeX on your Mac, live with your coauthors',
    description: 'Taudot is a Mac app for LaTeX. Type in an editor that works like Overleaf\'s, or in Neovim, and the PDF updates beside you. It works with your Overleaf projects: coauthors see your edits live, under your name, and their comments show in the margin.' })}
<body>${TOGGLE}<main class="col">${ICON}
<h1>Taudot<span>Write LaTeX on your Mac, live with your coauthors.</span></h1>
<p>A Mac app for writing LaTeX. The editor works the way Overleaf's does, or you can write in Neovim, and the PDF beside it updates as you type. It works with your Overleaf projects: coauthors in the browser see your edits as you make them, under your name, and their comments show up next to your text.</p>
${ok ? DONE : FORM(email)}${err ? `<p class="err" role="alert">${esc(err)}</p>` : ''}
<p class="note">${ok ? 'Changed your mind? <a href="/privacy">Here is how to be removed</a>.' : 'In early testing. One email when you can try it, nothing else. <a href="/privacy">Privacy</a>. Open source: <a href="https://github.com/heyodog0/taudot">github.com/heyodog0/taudot</a>.'}</p>
</main>
${panel()}
${foot}</body></html>`, status);
}

export const joined = () => landing('', 200, '', true);

function doc(title, inner, opts) {
  return html(`${head(title, opts)}<body>${TOGGLE}<main class="col doc">${ICON}<h1>${esc(title)}</h1>${inner}</main>${foot}</body></html>`, opts.status || 200);
}

export function privacy() {
  return doc('Privacy', `<p class="date">Updated 5 November 2026</p>
<p><b>What is kept.</b> If you join the waitlist, your email address. Only the address: no name, no date, no IP address, no cookie. To stop floods, the site counts joins per IP address for one minute and doesn't store the count.</p>
<p><b>Why.</b> To send you one email when there is a build of Taudot you can try. It isn't used for anything else, isn't shared or sold, and isn't added to any other list.</p>
<p><b>Where.</b> In a Cloudflare Workers KV store that belongs to Taudot. Cloudflare, which hosts this site, keeps its own routine request logs (with IP addresses) for a short time; this site turns its own logging off. Cloudflare's privacy policy covers those logs.</p>
<p><b>Removal.</b> Write to <a href="mailto:${CONTACT}">${esc(CONTACT)}</a> from the address, or naming it, and it is deleted. The list as a whole is deleted after that one email goes out.</p>
<p><b>This site.</b> No analytics, no ads, no third-party scripts, fonts or trackers. The light or dark switch is remembered in your own browser and never sent anywhere.</p>`,
  { path: '/privacy', description: 'What the Taudot waitlist keeps (your email address only), why, where, and how to be removed.' });
}

export function terms() {
  return doc('Terms', `<p class="date">Updated 5 November 2026</p>
<p><b>This site.</b> taudot.app tells you about Taudot and keeps a waitlist. Joining costs nothing and commits you to nothing.</p>
<p><b>The app.</b> Taudot is not released yet. When it is, it will come with its own terms.</p>
<p><b>Overleaf.</b> Taudot works with Overleaf projects you have access to. It isn't made by or affiliated with Overleaf, and Overleaf's own terms still apply to your projects there.</p>
<p><b>Liability.</b> The site is provided as is. To the extent the law allows, the person running it isn't liable for any loss from using it.</p>
<p>Contact: <a href="mailto:${CONTACT}">${esc(CONTACT)}</a>.</p>`,
  { path: '/terms', description: 'The terms for taudot.app and its waitlist.' });
}

/* GPL: the live pdfTeX that ships with Taudot is a separate program, and its source goes here at release. */
export function source() {
  return doc('Source code', `<p>Taudot is open source under the GNU Affero General Public License, version 3: <a href="https://github.com/heyodog0/taudot">github.com/heyodog0/taudot</a>. Fork it, file issues and send pull requests there.</p>
<p>Taudot runs a modified pdfTeX as a separate program. pdfTeX is free software under the GNU General Public License, and so are our changes to it; they are in the same repository.</p>`,
  { path: '/source', description: 'Taudot\'s source code, on GitHub under the AGPL.' });
}

export function notFound() {
  return doc('Not found', `<p>There's no page here. <a href="/">Go to the home page</a>.</p>`, { status: 404 });
}

export const robots = `User-agent: *\nAllow: /\n\nSitemap: ${ORIGIN}/sitemap.xml\n`;

export const sitemap = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${['/', '/privacy', '/terms', '/source'].map(p => `  <url><loc>${ORIGIN}${p}</loc></url>`).join('\n')}
</urlset>
`;
