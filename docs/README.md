# Docs

Start with the root [README](../README.md) and [developing.md](developing.md). Status: alpha.

## Design

| File | What it holds |
|---|---|
| [principles.md](principles.md) | The rules the design follows, and why |
| [architecture.md](architecture.md) | Engine, clients, backends, Rex and the preview |
| [mac-app.md](mac-app.md) | How the Mac app is built |
| [client-design.md](client-design.md) | How the Neovim client and the Rex panes look and feel |
| [state-machines.md](state-machines.md) | Component states and their transitions |

## Overleaf

| File | What it holds |
|---|---|
| [protocol.md](protocol.md) | Overleaf's real-time protocol, checked against the Overleaf CE source |
| [history.md](history.md) | Overleaf's version history and what Taudot uses |
| [api.md](api.md) | The engine's JSON-RPC API that clients use |

## Typesetting

| File | What it holds |
|---|---|
| [universal.md](universal.md) | Live, exact typesetting on unmodified pdfTeX, XeTeX and LuaTeX |
| [live-protocol.md](live-protocol.md) | The live engine's interactive protocol |
| [bench.md](bench.md) | Benchmarks against other live LaTeX systems and `latexmk` |
| [pdfsource.md](pdfsource.md) | PDF → source, proven by re-typesetting |
| [texstore.md](texstore.md) | The TeX Live store, files by hash |
| [prior-art.md](prior-art.md) | Other Overleaf clients, and live and incremental typesetting |
| [research/libtau-and-speed.md](research/libtau-and-speed.md) | Notes on libghostty, Typst's speed and incremental TeX |

## Shipping

| File | What it holds |
|---|---|
| [release.md](release.md) | Building a self-contained Taudot.app |
| [developing.md](developing.md) | What builds and tests need beyond `./install.sh` |

The Overleaf source studied is Overleaf CE `github.com/overleaf/overleaf` at commit `e039ad2` (2026-08-28); paths in
`protocol.md` are relative to it.
