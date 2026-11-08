/* taudot.app: the pages (pages.js), the static files in public/ (logo, clips)  */

import { landing, privacy, terms, source, notFound, robots, sitemap } from './pages.js';

const PUBLIC = ['/', '/privacy', '/terms', '/source'];

export default {
  async fetch(req, env) {
    const res = await route(req, env);
    const h = new Headers(res.headers);
    const path = new URL(req.url).pathname;
    // No third-party anything: scripts, styles and media only talk to this origin.
    h.set('content-security-policy', "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' data:; media-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'");
    h.set('referrer-policy', 'no-referrer');
    h.set('x-content-type-options', 'nosniff');
    if (!PUBLIC.includes(path) || res.status !== 200) h.set('x-robots-tag', 'noindex');
    return new Response(res.body, { status: res.status, headers: h });
  },
};

async function route(req, env) {
  const url = new URL(req.url), path = url.pathname;
  if (url.hostname === 'www.taudot.app') return Response.redirect(`https://taudot.app${path}${url.search}`, 301);
  if (req.method !== 'GET' && req.method !== 'HEAD') return new Response('Method not allowed', { status: 405, headers: { allow: 'GET, HEAD' } });
  if (path === '/') return landing();
  if (path === '/privacy') return privacy();
  if (path === '/terms') return terms();
  if (path === '/source') return source();
  if (path === '/robots.txt') return text(robots);
  if (path === '/sitemap.xml') return text(sitemap, 'application/xml');
  const asset = await env.ASSETS.fetch(req);
  if (asset.status !== 404) {
    const h = new Headers(asset.headers);
    h.set('cache-control', path.startsWith('/clips/') ? 'public, max-age=86400' : 'public, max-age=3600');
    return new Response(asset.body, { status: asset.status, headers: h });
  }
  return notFound();
}

const text = (body, type = 'text/plain') => new Response(body, { headers: { 'content-type': `${type}; charset=utf-8`, 'cache-control': 'public, max-age=3600' } });
