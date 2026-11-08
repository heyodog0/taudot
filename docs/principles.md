# Principles

Each rule says where it came from.

## Compatibility

1. **Speak Overleaf's own editor protocol.** Edits go over the same socket the browser editor uses, as small OT
   operations. Overleaf then stamps them with your user ID, shows them live to collaborators, and puts them in history
   under your name. Git, GitHub sync and whole-file uploads can't do this. (Overleaf CE: the server sets
   `meta.user_id` from the session.)
2. **Overleaf's server is the source of truth.** The local folder is a copy that the engine keeps in sync. A change on
   disk becomes the smallest diff, never a whole-file replacement. (nvim-overleaf's file mode replaces whole files and
   wipes concurrent edits, comments and tracked-change ranges.)
3. **Support both of Overleaf's edit formats from day one.** Projects are moving from `sharejs-text-ot` to `history-ot`,
   and a client that only speaks the old one is refused on migrated projects. Every third-party client found so far
   only speaks the old one. (Overleaf CE, see protocol.md.)
4. **Copy the browser client's recovery behaviour exactly.** Wait for the real confirmation, resend with `dupIfSource`,
   catch up with `joinDoc(fromVersion)`, back up unsent edits. The browser client is the one Overleaf tests against.

## Correctness

5. **Never drop the user's edits.** Unsent edits are backed up on disk every couple of seconds. Every recovery path
   rebases them onto fresh server state instead of resetting. When in doubt, go read-only and keep the edits.
   (nvim-overleaf's `Document.reset` and Workshop's cache clear both lose edits.)
6. **A wrong transform corrupts everyone's document, not just yours.** The OT core gets a fuzz test with several
   simulated clients against a local Overleaf CE before any UI work. Convergence of all clients to the same text is the
   pass condition.
7. **Count positions the way the server does.** Classic-format positions are JavaScript string indexes, so emoji and
   other astral characters count as two. nvim-overleaf counts them as one.
8. **Fail safe on protocol drift.** Overleaf's protocol is unofficial and has changed before. Keep it behind one backend
   module, check the server's responses against what we expect, and stop writing when they don't match.

## Shape

9. **One engine owns all state, every interface is a client.** Neovim, Rex panes, the CLI, agents and a later native
   app hold nothing of their own. Closing any of them never interrupts sync. (Neovim's core and UI split.)
10. **Positions that move with the text live in the engine.** Comments, collaborator cursors, tracked changes and "my
    recent edits" are ranges the engine moves on every op, like Neovim's extmarks. Clients only draw them.
11. **A versioned API that only grows.** Clients ask the engine for its API level. Functions get added, never changed.
    A reconnecting client asks for the events since its last sequence number. (Neovim's `api_info` and `--remote-ui`.)
12. **Overleaf is one backend, not the foundation.** The core knows nothing about Overleaf, so a later own backend (a
    CRDT such as Yjs or Loro) or a local-only mode is a second backend, not a rewrite.
13. **Plain files, plain commands.** The project is a normal folder any tool can read. Every engine feature has a
    non-interactive CLI command with `--json`, so agents can use it. (Glideshow's deck folder and CLI.)
14. **Rex shows things, it doesn't hold state.** Floating layers for activity and alerts, a pane for the PDF preview,
    Neovim with live highlights. All of them are clients of the engine.

## Workflow (from Glideshow)

15. **Docs first, then a plan worked top to bottom.** `docs/plan.md` items get checked off with a one-line note of what
    was done and how it was checked.
16. **Measure against the real thing.** Glideshow's fidelity harness compares against Google's own render. Here the
    reference is Overleaf CE running its own code, with a real browser client in the same test.
17. **Tests never touch real data.** Test servers and projects live in temp folders and local Docker, never on
    overleaf.com projects with collaborators.
