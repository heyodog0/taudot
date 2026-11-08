-- SyncTeX link with the PDF preview (clients/preview). Independent of the engine connection.
--
-- The preview listens on a Unix socket ($TAUDOT_PREVIEW_SOCKET). We connect, retrying while it isn't there, and
-- exchange one JSON object per line:
--   to the preview:   {"cursor": {"path": "/abs/main.tex", "line": 12}}   when the cursor rests on a new line
--   from the preview: {"jump": {"path": "/abs/main.tex", "line": 12}}     after a double-click in the PDF

local uv = vim.uv
local api = vim.api

local M = {}

local pipe = nil -- connected uv pipe
local socket_path = nil
local retry = nil -- uv timer
local cursor_timer = nil
local last_sent = nil -- "path:line"
local group = nil

local delay_ms = 150

local function realpath(p)
  return p ~= '' and (uv.fs_realpath(p) or p) or p
end

local function send(obj)
  if pipe then
    pipe:write(vim.json.encode(obj) .. '\n')
  end
end

-- Send the cursor if it rests on a new line of a .tex file.
local function send_cursor(force)
  if not pipe then
    return
  end
  local buf = api.nvim_get_current_buf()
  local name = api.nvim_buf_get_name(buf)
  if not name:match('%.tex$') then
    return
  end
  local path = realpath(name)
  local line = api.nvim_win_get_cursor(0)[1]
  local key = path .. ':' .. line
  if key == last_sent and not force then
    return
  end
  last_sent = key
  send({ cursor = { path = path, line = line } })
end

local function schedule_cursor()
  if not pipe then
    return
  end
  cursor_timer = cursor_timer or uv.new_timer()
  cursor_timer:stop()
  cursor_timer:start(delay_ms, 0, vim.schedule_wrap(function()
    send_cursor(false)
  end))
end

--- Open `path` at `line` in the current window (or the window already showing it) and centre it.
function M.jump(path, line, col)
  local target = realpath(path)
  local win = nil
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if realpath(api.nvim_buf_get_name(api.nvim_win_get_buf(w))) == target then
      win = w
      break
    end
  end
  if vim.fn.mode():match('^[iR]') then
    vim.cmd.stopinsert()
  end
  if win then
    api.nvim_set_current_win(win)
  else
    local buf = nil
    for _, b in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_loaded(b) and realpath(api.nvim_buf_get_name(b)) == target then
        buf = b
        break
      end
    end
    if buf then
      api.nvim_win_set_buf(0, buf)
    else
      vim.cmd.edit(vim.fn.fnameescape(path))
    end
  end
  local n = api.nvim_buf_line_count(0)
  line = math.max(1, math.min(line, n))
  if col then
    local text = api.nvim_buf_get_lines(0, line - 1, line, false)[1] or ''
    api.nvim_win_set_cursor(0, { line, math.max(0, math.min(col, #text - 1)) })
    vim.cmd('normal! zvzz')
  else
    api.nvim_win_set_cursor(0, { line, 0 })
    vim.cmd('normal! ^zvzz')
  end
  last_sent = realpath(api.nvim_buf_get_name(0)) .. ':' .. line
end

local function on_line(l)
  local ok, msg = pcall(vim.json.decode, l)
  if ok and type(msg) == 'table' and type(msg.jump) == 'table' and msg.jump.path and msg.jump.line then
    M.jump(msg.jump.path, tonumber(msg.jump.line))
  end
end

local connect

local function schedule_retry()
  if not socket_path then
    return
  end
  retry = retry or uv.new_timer()
  retry:stop()
  retry:start(1000, 0, vim.schedule_wrap(connect))
end

connect = function()
  if pipe or not socket_path then
    return
  end
  local p = uv.new_pipe(false)
  p:connect(socket_path, function(err)
    if err then
      p:close()
      schedule_retry()
      return
    end
    pipe = p
    local buf = ''
    p:read_start(function(rerr, chunk)
      if rerr or not chunk then
        if pipe == p then
          pipe = nil
        end
        if not p:is_closing() then
          p:close()
        end
        schedule_retry()
        return
      end
      buf = buf .. chunk
      while true do
        local nl = buf:find('\n', 1, true)
        if not nl then
          break
        end
        local line = buf:sub(1, nl - 1)
        buf = buf:sub(nl + 1)
        vim.schedule(function()
          on_line(line)
        end)
      end
    end)
    vim.schedule(function()
      send_cursor(true)
    end)
  end)
end

--- Start the link. `path` defaults to $TAUDOT_PREVIEW_SOCKET; does nothing without one.
function M.start(path)
  path = path or vim.env.TAUDOT_PREVIEW_SOCKET
  if not path or path == '' or socket_path then
    return
  end
  socket_path = path
  group = api.nvim_create_augroup('taudot_preview', { clear = true })
  api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'BufEnter' }, {
    group = group,
    callback = schedule_cursor,
  })
  connect()
end

function M.stop()
  socket_path = nil
  if group then
    api.nvim_del_augroup_by_id(group)
    group = nil
  end
  for _, t in ipairs({ retry, cursor_timer }) do
    if t and not t:is_closing() then
      t:stop()
      t:close()
    end
  end
  retry, cursor_timer = nil, nil
  if pipe and not pipe:is_closing() then
    pipe:close()
  end
  pipe = nil
end

function M.connected()
  return pipe ~= nil
end

return M
