# Taudot

A native, local-first LaTeX editing setup that stays fully compatible with Overleaf. You edit in Neovim, in Rex panes or
in a later native app. Collaborators keep using overleaf.com in the browser. Your edits reach them live, under your own
name in Overleaf's history, the same way a browser tab's edits would.

Status: prototype. Neovim edits reach a local Overleaf CE through the engine; round 2 agents are working on safe concurrent editing and the PDF preview. The product is Taudot; it was called texsync until 2026-11-04.

## Read these first

| File | What it holds |
|---|---|
| [docs/principles.md](principles.md) | The rules the design follows, and why |
| [docs/protocol.md](protocol.md) | Overleaf's real-time protocol, checked against the Overleaf CE source |
| [docs/prior-art.md](prior-art.md) | Existing clients, what to keep from them, and their bugs |
| [docs/architecture.md](architecture.md) | Engine, clients, backends, Rex and the preview |
| [docs/plan.md](plan.md) | Build order, with the first test to write |
| [docs/api.md](api.md) | The engine's JSON-RPC API that clients use |
| [docs/client-design.md](client-design.md) | How the Neovim client and the Rex panes should look and feel |
| [docs/exact-typesetting.md](exact-typesetting.md) | Plan: a live pdfTeX so the PDF is identical to Overleaf's (not started) |
| [docs/developing.md](developing.md) | What builds and tests need beyond `./install.sh` |

## Sources studied (2026-11-01)

- Overleaf CE, `github.com/overleaf/overleaf` at commit `e039ad2` (2026-08-28). Paths in `docs/protocol.md` are relative
  to that repo.
- `github.com/mei28/nvim-overleaf` (last commit 2026-04-06), `github.com/iamhyc/Overleaf-Workshop` (2026-10-03).
- Glideshow, `~/code/lab/glideshow` and `~/code/lab/glideshow-dev`, the owner's own project, used as the model for repo
  layout and workflow.
- Neovim's architecture, as the model for the engine and its clients.
- Rex beta, `rex` CLI build `dd9a201` (2026-10-27), for floating panes and inline images.
