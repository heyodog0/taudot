# overleaf

Overleaf's real-time protocol in Rust, spoken the way the browser editor speaks it. Your edits reach coauthors live
under your name, theirs reach you, and comments and history work both ways.

- **Layers**, bottom up: `sio` (socket.io 0.9 frames), `socket` (one WebSocket connection), `http` (login and REST),
  `project` (join a project and its docs), `doc` (one doc's state and its operational transforms).
- **Also:** `tree` (the file tree), `rest` (uploads and blob hashes), `history` (Overleaf's history API).
- **`fake`** (a feature) is a small real-time server for tests, so they never touch real projects.

The sync engine (`crates/engine`) uses this crate to keep a local folder and an Overleaf project in step.

## Test

```console
$ cargo test --features fake       # against the fake server
```

Tests against a real server use a local Overleaf CE in Docker (`docker/`), never other people's projects.

## Docs

- [docs/protocol.md](../../docs/protocol.md): the protocol, each claim marked verified, observed or unverified.

Not affiliated with Overleaf.
