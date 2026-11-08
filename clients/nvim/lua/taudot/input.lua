-- A floating multi-line input for comments and replies. Markdown, submit with <C-s> (or <CR> in normal mode), cancel
-- with q or <Esc> in normal mode. Text left behind by leaving the window is kept as a draft for the same title.

local api = vim.api

local M = {}

local drafts = {}

-- opts: { title, default (string), on_submit(text) }. Returns the float's buffer and window.
function M.open(opts)
  local title = opts.title or 'Comment'
  local width = math.min(72, math.max(40, math.floor(vim.o.columns * 0.5)))
  local height = 6
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'markdown'
  local text = drafts[title] or opts.default or ''
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, '\n', { plain = true }))
  -- Below the cursor when there is room, else above it.
  local row = vim.fn.winline() < vim.api.nvim_win_get_height(0) - height - 3 and 1 or -(height + 2)
  local win = api.nvim_open_win(buf, true, {
    relative = 'cursor',
    row = row,
    col = 0,
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. title .. ' ',
    title_pos = 'left',
    footer = ' <C-s> send · q cancel ',
    footer_pos = 'right',
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].winhighlight = 'FloatTitle:TaudotInputTitle,FloatFooter:TaudotInputFooter'

  local done = false
  local function close()
    done = true
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
    vim.cmd.stopinsert()
  end
  local function submit()
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local s = vim.trim(table.concat(lines, '\n'))
    drafts[title] = nil
    close()
    if s ~= '' then
      opts.on_submit(s)
    end
  end
  local function cancel()
    drafts[title] = nil
    close()
  end
  local o = { buffer = buf, nowait = true }
  vim.keymap.set({ 'n', 'i' }, '<C-s>', submit, o)
  vim.keymap.set('n', '<CR>', submit, o)
  vim.keymap.set('n', 'q', cancel, o)
  vim.keymap.set('n', '<Esc>', cancel, o)
  api.nvim_create_autocmd('WinLeave', {
    buffer = buf,
    once = true,
    callback = function()
      if done then
        return
      end
      local s = vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n'))
      drafts[title] = s ~= '' and s or nil
      vim.schedule(close)
    end,
  })
  if text == '' then
    vim.cmd.startinsert()
  else
    api.nvim_win_set_cursor(win, { api.nvim_buf_line_count(buf), 0 })
    vim.cmd.startinsert({ bang = true })
  end
  return buf, win
end

return M
