# Taudot for Neovim

Thin Lua client of the Taudot engine (`docs/api.md`). See `doc/taudot.txt` (`:h taudot`).

```lua
-- lazy.nvim, from a checkout
{ dir = '~/code/lab/taudot/clients/nvim', opts = {} }
```

```vim
:Taudot open ~/papers/grid
```

## Comments and tracked changes

Open the paper, then press `<leader>ap`: the review panel opens on the right with every comment and tracked change in
the file as a card (who, when, the text, the messages), in the order they come in the text. It updates as others
comment, and the card under your cursor lights up. In the panel, `r` replies, `R` resolves (or reopens), `a` accepts,
`x` rejects, `d` deletes the thread, `H` shows resolved ones, `<CR>` goes to the text, `q` closes it.

In the file itself (all under `<leader>a`, which you can change with `mapping_prefix`):

| Keys | Does |
|---|---|
| `<leader>ap` | review panel on/off |
| `<leader>ac` | comment on the selection (visual) or the word under the cursor |
| `<leader>ar` / `<leader>aR` | reply to / resolve or reopen the comment under the cursor |
| `<leader>aa` / `<leader>ax` | accept / reject the tracked change under the cursor (or in the selected lines) |
| `<leader>ad` / `<leader>ae` | delete the thread / edit your message |
| `<leader>al` / `<leader>aL` | every comment / every tracked change in the project, in Telescope when you have it |
| `<leader>at` | track your own edits on/off (`TC` in the statusline) |
| `<leader>ai` | comment text at the end of commented lines on/off |
| `K` | the thread or change under the cursor in a float |

Comments and replies open a small box: write as much as you like, `<C-s>` sends, `q` cancels. Keys you've already
mapped are left alone; `:checkhealth taudot` lists any it skipped. In Telescope (`<leader>al`): `<C-r>` reply, `<C-e>`
resolve or reopen, `<C-d>` delete, `<C-a>` show resolved; for changes `<C-y>` accept, `<C-x>` reject. Overleaf CE has
no comment messages, so there you see the comments but can't reply or resolve; overleaf.com has them.

| File | Does |
|---|---|
| `lua/taudot/rpc.lua` | JSON-RPC over the Unix socket with `vim.uv` |
| `lua/taudot/buffer.lua` | One attached buffer: `on_bytes` → edits, remote edits → `nvim_buf_set_text` behind an echo guard |
| `lua/taudot/ot.lua` | Byte TextOperation, twin of `clients/mock-engine/ot.ts` |
| `lua/taudot/ui.lua` | Fading author colours, unconfirmed underline, cursors, comments, tracked changes, the review float |
| `lua/taudot/init.lua` | Project, `:Taudot`, statusline |
| `lua/taudot/review.lua` | Review actions: comment on a selection, reply, resolve, delete, accept and reject, track |
| `lua/taudot/panel.lua` | The review panel |
| `lua/taudot/picker.lua` | `:Taudot comments` and `changes`: Telescope, `vim.ui.select` or quickfix |
| `lua/taudot/input.lua` | The floating box for comments and replies |
| `lua/taudot/keys.lua` | Mappings under `mapping_prefix`, skipping keys you have |
| `lua/taudot/health.lua` | `:checkhealth taudot` |
| `lua/taudot/preview.lua` | SyncTeX link with the PDF preview pane (see below) |

Tests, headless against the mock engine with its bot:

```sh
nvim --headless --clean -l tests/ot_spec.lua   # 5000-case transform fuzz
tests/run.sh                                   # e2e, review UI, Telescope (when installed); LATENCY=400 to stress
tests/ce_review.sh                             # review features on the local Overleaf CE, Bob in a browser
```

## PDF preview link

When `$TAUDOT_PREVIEW_SOCKET` is set (`clients/rex/taudot-layout.sh` sets it), the plugin connects to the preview
pane (`clients/preview`) and keeps retrying while it isn't there. When the cursor rests on a new line of a `.tex` file
for 150 ms it sends `{"cursor": {"path", "line"}}`, and the preview scrolls there if the line is out of view and
marks it. A double-click in the PDF sends back `{"jump": {"path", "line"}}`: the plugin opens that file in the window
that shows it (or the current one), puts the cursor on the line, leaves insert mode and centres it.
`tests/preview_spec.lua` (run by `tests/run.sh`) tests this against a fake preview.

Known gaps, fine against the mock, to fix against the real engine:

- On reconnect, an edit that was in flight is resent. If the engine had applied it, it lands twice. Needs the
  engine to say which of a client's edits it has.
- A resync after an inconsistency drops unconfirmed edits (with a warning) instead of rebasing them.
- Positions sent with `presence.cursor` don't account for edits still in flight.
