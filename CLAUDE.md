# Notes for agents

Start with `docs/README.md`, then the docs it lists, in order. `docs/protocol.md` marks every claim as **verified** (read in
Overleaf's source), **observed** (seen in a working client) or **unverified**. Check unverified claims against Overleaf
CE before building on them, and update the doc when you do.

- Python: `uv` only. Never bare `python` or `pip`.
- Overleaf's code is AGPL. Read it to learn the protocol. Don't copy it into this repo.
- Never test against real collaborators' projects. Use a local Overleaf CE in Docker, or a throwaway project of your own.
- Commit messages: one short phrase, no attribution trailers.
