# taudot.app

The landing page (one tagline, one paragraph, the work in progress, three clips), `/privacy`, `/terms` and `/source`,
served by one Cloudflare Worker. Modelled on Glideshow's public pages (`~/code/lab/glideshow/cloud/pages.js`), in
Taudot's own palette. **Not deployed.**

| File | What it is |
|---|---|
| `src/worker.js` | Routes, security headers, (the old waitlist POST is gone) |
| `src/pages.js` | Every page: one template, inline CSS, system fonts; the clip list (`CLIPS`) and the copy |
| `public/` | `mark.svg` (the web icon, also the favicon: a flatter take on the app icon), `clips/` |
| `tools/clip.sh` | A screen recording → `clips/<id>.webm`, `.mp4` and `.jpg` poster |
| `tools/shots.py` | Screenshots at desktop and phone width, light and dark, in headless Chrome |
| `wrangler.toml` | The Worker, its KV namespace `WAITLIST` and the `JOINS` rate limit |

## Run it locally

```sh
cd site
npx wrangler@4.157.0 dev --port 8790 --ip 127.0.0.1     # or: npm run dev
open http://127.0.0.1:8790/
```

`wrangler dev` uses a local KV store in `.wrangler/state` (gitignored). See what the form stored:

```sh
curl -s http://127.0.0.1:8790/cdn-cgi/local/explorer/api/storage/kv/namespaces/00000000000000000000000000000000/keys
```

Screenshots (with `wrangler dev` running): `uv run site/tools/shots.py <out-dir> / /privacy /terms /source`
from the repo root. They also submit the form once, so `shots@example.org` lands in the local KV.

## The waitlist

A plain HTML form, no JavaScript needed. The Worker lowercases the address, checks it looks like one, and stores it as
the key `email:<address>` with an empty value: no date, no IP, no cookie. It answers with the same confirmation
whether the address was new or not, so the form can't be used to check who signed up. A hidden field drops bots, and
`JOINS` allows 5 joins a minute per IP (counted, not stored). Workers Logs are off. `/privacy` says all of this; keep
it in step with the code.

Read the list once deployed: `npx wrangler kv key list --binding WAITLIST --remote`. Remove someone:
`npx wrangler kv key delete --binding WAITLIST --remote "email:<address>"`.

## Clips

`CLIPS` in `src/pages.js` lists them. A clip with `ready: false` shows an empty frame with its caption. To add one:

```sh
site/tools/clip.sh ~/Desktop/recording.mov type 2.0 6     # id, start second, length; optional crop w:h:x:y
```

then set `ready: true`. Videos load when they scroll near, play only while on screen, loop silently, and show the
poster with controls under reduced motion. Record only from a made-up sample paper on the local Overleaf CE (or the
throwaway projects in `docker/.env.overleafcom`), never anyone's real paper. The fourth clip (`same-pdf`) stays
`hidden: true` until "ours equals Overleaf's" is verified.

## How it would deploy (the user decides; nothing here is done)

1. `npx wrangler kv namespace create WAITLIST` and put its id in `wrangler.toml`.
2. Uncomment the `routes` line for `taudot.app` and `www.taudot.app` (the domain must be on the user's Cloudflare
   account).
3. Set up email routing for the contact address (`CONTACT` in `src/pages.js`, now `hello@taudot.app`), since
   `/privacy` tells people to write there to be removed.
4. `npx wrangler deploy` from `site/`.
