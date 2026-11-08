-- JSON-RPC 2.0 over the engine's Unix socket, one object per line, with vim.uv.
--
-- Callbacks run on the main loop (vim.schedule), in the order messages arrived, so a client sees every doc.changed
-- for a lower seq before the doc.edit result that follows it.

local uv = vim.uv

local M = {}
M.__index = M

---@param path string
---@param handlers { on_notify: fun(method: string, params: table), on_close: fun(err: string?) }
---@param cb fun(err: string?, client: table?)
function M.connect(path, handlers, cb)
  local pipe = uv.new_pipe(false)
  local self = setmetatable({
    pipe = pipe,
    next_id = 0,
    waiting = {},
    buf = '',
    closed = false,
    handlers = handlers,
  }, M)
  pipe:connect(path, function(err)
    vim.schedule(function()
      if err then
        pipe:close()
        return cb(err)
      end
      pipe:read_start(function(rerr, chunk)
        if rerr or not chunk then
          vim.schedule(function()
            self:_close(rerr or 'engine closed the connection')
          end)
          return
        end
        self.buf = self.buf .. chunk
        local lines = {}
        while true do
          local nl = self.buf:find('\n', 1, true)
          if not nl then
            break
          end
          lines[#lines + 1] = self.buf:sub(1, nl - 1)
          self.buf = self.buf:sub(nl + 1)
        end
        if #lines > 0 then
          vim.schedule(function()
            for _, line in ipairs(lines) do
              self:_dispatch(line)
            end
          end)
        end
      end)
      cb(nil, self)
    end)
  end)
end

function M:_dispatch(line)
  if line == '' then
    return
  end
  local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not ok or type(msg) ~= 'table' then
    return
  end
  if msg.id ~= nil and msg.method == nil then
    local cb = self.waiting[msg.id]
    self.waiting[msg.id] = nil
    if cb then
      cb(msg.error, msg.result)
    end
  elseif msg.method then
    self.handlers.on_notify(msg.method, msg.params or {})
  end
end

function M:_close(err)
  if self.closed then
    return
  end
  self.closed = true
  if not self.pipe:is_closing() then
    self.pipe:close()
  end
  for id, cb in pairs(self.waiting) do
    self.waiting[id] = nil
    cb({ code = -1, message = 'connection closed' })
  end
  self.handlers.on_close(err)
end

---@param method string
---@param params table?
---@param cb fun(err: table?, result: any)?
function M:request(method, params, cb)
  if self.closed then
    if cb then
      cb({ code = -1, message = 'not connected' })
    end
    return
  end
  self.next_id = self.next_id + 1
  local id = self.next_id
  self.waiting[id] = cb or function() end
  local msg = { jsonrpc = '2.0', id = id, method = method, params = params or vim.empty_dict() }
  self.pipe:write(vim.json.encode(msg) .. '\n')
end

function M:close()
  self:_close(nil)
end

return M
