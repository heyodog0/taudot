-- Completion from the engine (`complete.items`) through an in-process language server, so Neovim's own completion
-- (`vim.lsp.completion`, autotriggered on `\`, `{` and `,`) shows it with no plugins, and blink.cmp or nvim-cmp
-- pick it up as an LSP source when installed.

local api = vim.api

local M = {}

-- LSP CompletionItemKind for each engine kind, and the short label the popup shows.
local LSP_KIND = { cite = 18, ref = 18, command = 3, env = 9, file = 17 }
local SHORT = { cite = 'cite', ref = 'ref', command = 'cmd', env = 'env', file = 'file' }

local function snippet_escape(s)
  return (s:gsub('[\\$}]', '\\%0'))
end

-- Engine result -> LSP CompletionList. `row` and `line_off` place the byte offsets `from`/`to` on the cursor's line.
function M.to_lsp(res, row, line_off)
  local items = {}
  if not res or not res.items then
    return { isIncomplete = false, items = items }
  end
  local range = {
    start = { line = row, character = res.from - line_off },
    ['end'] = { line = row, character = res.to - line_off },
  }
  for i, it in ipairs(res.items) do
    local text, format = it.insert, 1
    if it.cursor then
      text = snippet_escape(it.insert:sub(1, it.cursor)) .. '$0' .. snippet_escape(it.insert:sub(it.cursor + 1))
      format = 2
    end
    items[i] = {
      label = it.label,
      kind = LSP_KIND[it.kind],
      detail = it.detail ~= '' and it.detail or nil,
      filterText = it.label,
      sortText = ('%05d'):format(i),
      insertTextFormat = format,
      textEdit = { range = range, newText = text },
      data = { kind = it.kind, context = res.context },
    }
  end
  return { isIncomplete = false, items = items }
end

-- Ask the engine. `cb(err, CompletionList)`.
function M.request(buf, row, col, cb)
  local Buffer = require('taudot.buffer')
  local b = Buffer.by_buf[buf]
  local empty = { isIncomplete = false, items = {} }
  if not b or b.detached or not b.project or not b.project.client then
    return cb(nil, empty)
  end
  local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
  col = math.min(col, #line)
  local off = api.nvim_buf_get_offset(buf, row)
  local params = { doc_id = b.doc_id, pos = off + col, before = line:sub(1, col) }
  b.project.client:request('complete.items', params, function(err, res)
    if err or not res then
      return cb(nil, empty)
    end
    cb(nil, M.to_lsp(res, row, off))
  end)
end

-- The language server: just enough of LSP for completion.
local function server(dispatchers)
  local closing, id = false, 0
  return {
    request = function(method, params, callback)
      id = id + 1
      if method == 'initialize' then
        callback(nil, {
          capabilities = {
            positionEncoding = 'utf-8',
            completionProvider = { triggerCharacters = { '\\', '{', ',' } },
          },
          serverInfo = { name = 'taudot' },
        })
      elseif method == 'textDocument/completion' then
        local buf = vim.uri_to_bufnr(params.textDocument.uri)
        M.request(buf, params.position.line, params.position.character, callback)
      else
        callback(nil, nil)
      end
      return true, id
    end,
    notify = function(method)
      if method == 'exit' then
        closing = true
        dispatchers.on_exit(0, 15)
      end
      return true
    end,
    is_closing = function()
      return closing
    end,
    terminate = function()
      closing = true
    end,
  }
end

-- How the popup shows an item: the kind as a small label, the detail beside it.
local function convert(item)
  local data = item.data or {}
  local detail = item.detail or ''
  if vim.fn.strchars(detail) > 60 then
    detail = vim.fn.strcharpart(detail, 0, 59) .. '…'
  end
  return {
    kind = SHORT[data.kind] or '',
    kind_hlgroup = 'TaudotCompleteKind',
    menu = detail,
  }
end

local function other_engine()
  return package.loaded['blink.cmp'] ~= nil or package.loaded['cmp'] ~= nil
end

-- Inside the empty braces of a cite/ref/input/begin just completed: ask again for what goes in them.
local RETRIGGER = { cite = true, ref = true, file = true, env = true }

local function after_complete(buf)
  local item = vim.v.completed_item
  local lsp = vim.tbl_get(item or {}, 'user_data', 'nvim', 'lsp', 'completion_item')
  if not lsp or not lsp.data then
    return
  end
  vim.schedule(function()
    if api.nvim_get_current_buf() ~= buf or not api.nvim_get_mode().mode:find('^i') then
      return
    end
    if lsp.data.kind == 'env' and lsp.data.context == 'env' then
      local col = api.nvim_win_get_cursor(0)[2]
      if api.nvim_get_current_line():sub(1, col):match('\\begin{[^{}]+$') then
        require('taudot.comforts.envs').complete_begin(buf)
      end
      return
    end
    if lsp.data.kind == 'command' then
      local col = api.nvim_win_get_cursor(0)[2]
      local line = api.nvim_get_current_line()
      local name = line:sub(1, col):match('\\(%a+)%*?{$')
      if name and line:sub(col + 1, col + 1) == '}' then
        local kind = name:lower():find('cite') and 'cite' or (name:find('ref$') and name ~= 'href' and 'ref')
          or ((name == 'begin' or name == 'end') and 'env')
          or (({ input = 1, include = 1, includegraphics = 1, bibliography = 1, addbibresource = 1 })[name] and 'file')
        if kind and RETRIGGER[kind] and vim.lsp.completion.get then
          pcall(vim.lsp.completion.get, { ctx = { triggerKind = 1 } })
        end
      end
    end
  end)
end

local function accept_maps(buf)
  -- Free, or only Neovim's own default (sid -8, such as the snippet-jump <Tab>), which the mapping falls back to.
  local function free(lhs)
    local m = vim.fn.maparg(lhs, 'i', false, true)
    return vim.tbl_isempty(m) or (m.sid == -8 and m.buffer == 0)
  end
  if free('<Tab>') then
    vim.keymap.set('i', '<Tab>', function()
      if vim.fn.pumvisible() == 0 then
        if vim.snippet and vim.snippet.active({ direction = 1 }) then
          return '<Cmd>lua vim.snippet.jump(1)<CR>'
        end
        return '<Tab>'
      end
      return vim.fn.complete_info({ 'selected' }).selected == -1 and '<C-n><C-y>' or '<C-y>'
    end, { buffer = buf, expr = true, desc = 'Taudot: accept completion' })
  end
  if free('<CR>') then
    vim.keymap.set('i', '<CR>', function()
      if vim.fn.pumvisible() == 1 and vim.fn.complete_info({ 'selected' }).selected ~= -1 then
        return '<C-y>'
      end
      return '<CR>'
    end, { buffer = buf, expr = true, desc = 'Taudot: accept completion' })
  end
end

M.client_id = nil

function M.attach(buf, b)
  local root = b and b.project and b.project.folder or vim.fn.getcwd()
  local id = vim.lsp.start({
    name = 'taudot',
    cmd = server,
    root_dir = root,
  }, { bufnr = buf, silent = true })
  if not id then
    return
  end
  M.client_id = id
  if other_engine() or not vim.lsp.completion then
    return
  end
  vim.lsp.completion.enable(true, id, buf, { autotrigger = true, convert = convert })
  vim.bo[buf].completeopt = 'menuone,noinsert,popup,fuzzy'
  accept_maps(buf)
  local group = api.nvim_create_augroup('taudot.complete.' .. buf, { clear = true })
  api.nvim_create_autocmd('CompleteDone', {
    group = group,
    buffer = buf,
    callback = function()
      after_complete(buf)
    end,
  })
  -- `\cite{a, ` : the space after the comma closed the popup; open it again for the next key.
  api.nvim_create_autocmd('TextChangedI', {
    group = group,
    buffer = buf,
    callback = function()
      if vim.fn.pumvisible() == 1 then
        return
      end
      local col = api.nvim_win_get_cursor(0)[2]
      local before = api.nvim_get_current_line():sub(1, col)
      local name = before:match('\\(%a+)%*?%b[]{[^{}]*,%s+$') or before:match('\\(%a+)%*?{[^{}]*,%s+$')
      if name and (name:lower():find('cite') or (name:find('ref$') and name ~= 'href')) then
        pcall(vim.lsp.completion.get)
      end
    end,
  })
end

return M
