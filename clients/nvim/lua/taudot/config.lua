local M = {}

M.defaults = {
  -- Engine socket. $TAUDOT_SOCKET wins over this.
  -- The engine's home was ~/.texsync before the rename; it moves (leaving a symlink) when the new engine starts.
  socket = (function()
    local home = vim.env.HOME or '~'
    local new = vim.fs.joinpath(home, '.taudot', 'engine.sock')
    local old = vim.fs.joinpath(home, '.texsync', 'engine.sock')
    return (vim.uv.fs_stat(new) or not vim.uv.fs_stat(old)) and new or old
  end)(),
  -- Collaborators get these groups in order. Linked, never hex.
  author_groups = { 'DiagnosticInfo', 'DiagnosticWarn', 'DiagnosticOk', 'DiagnosticHint', 'Special', 'DiagnosticError' },
  fade_ms = 3000,
  underline_unconfirmed = true,
  -- 'inline' (initials right at the cursor), 'eol', or 'none'
  cursor_label = 'inline',
  signs = { comment = '▍', change = '▎' },
  -- How comments show in the text: 'tint' (a faint background in the author's colour that brightens while the
  -- cursor is inside), 'tint+underline' (the same, underlined), 'underline' (DiagnosticUnderlineInfo) or 'bar' (no
  -- colour on the text, a mark in the author's colour in the sign column that brightens likewise).
  comment_style = 'tint',
  -- Draw resolved comments too (dimmed). The review list hides them unless asked (`:Taudot comments all`).
  show_resolved = false,
  -- ms to wait before sending a batch of edits, and before sending your cursor
  send_delay = 0, -- the engine batches for Overleaf; a delay here only slows the PDF
  cursor_delay = 150,
  -- Review mappings under mapping_prefix (`:h taudot-mappings`). A key you have already mapped is left alone.
  mappings = true,
  mapping_prefix = '<leader>a',
  -- K on a comment or tracked change shows it (else LSP hover, else K).
  comment_K = true,
  -- End-of-line text on a line with a comment ("▍ Bob: first words… (+2)"); hidden while the review panel is open.
  inline = true,
  -- comments uncoloured and without signs in the text (their ranges still work: cursor, panel, jumps)
  comments_hidden = false,
  -- Show the thread in a float when the cursor rests on a comment (CursorHold).
  hover = false,
  -- The review panel: a split on the right.
  panel = { width = 44 },
  -- :Taudot comments and changes: 'auto' (Telescope when installed, else vim.ui.select), 'telescope', 'select' or
  -- 'quickfix'.
  picker = 'auto',
  reconnect = true,
  -- Synced buffers read as prose: whole paragraphs are one line in most Overleaf projects, so wrap at word
  -- boundaries, keep continuation lines aligned, scroll by screen line (`smoothscroll`), show what fits of the last
  -- line instead of @@@. Window-local, set when a synced buffer is shown; false leaves your settings alone.
  prose = true,
  -- Overleaf-style comforts: completion (cite, ref, commands, files), \begin auto-close, Cmd-/ comments, folding.
  comforts = true,
}

M.options = vim.deepcopy(M.defaults)

function M.set(opts)
  opts = opts or {}
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts)
  -- The old name: default_mappings = false turned them off.
  if opts.default_mappings ~= nil and opts.mappings == nil then
    M.options.mappings = opts.default_mappings
  end
end

function M.socket()
  return vim.env.TAUDOT_SOCKET or M.options.socket
end

return M
