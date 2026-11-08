-- Byte-offset text operations for the Neovim client.
--
-- An op is { comps = {...}, base = n, target = m }. A component is a positive integer (retain), a negative integer
-- (delete) or a string (insert), with lengths in bytes, which is what Lua strings and on_bytes count. This is ot.js's
-- TextOperation (MIT, Tim Baumann), written from crates/ot2's history::TextOperation, which is the same op counted in
-- UTF-16 units. crates/ot2/tests/byte_fixtures.rs computes the expected results of every function here with ot2;
-- tests/ot_spec.lua checks them.
--
-- The engine transforms a client's stale edits, but a remote edit can still cross the client's own unconfirmed edits
-- on the socket, so the client transforms incoming edits past those (see docs/agents/nvim.log.md).

local M = {}

local function new()
  return { comps = {}, base = 0, target = 0 }
end

-- The builders keep an op in one form: neighbours of a kind merged, nothing empty, and an insert next to a delete
-- before it.
local function retain(op, n)
  if n == 0 then
    return
  end
  op.base, op.target = op.base + n, op.target + n
  local c = op.comps
  local last = c[#c]
  if type(last) == 'number' and last > 0 then
    c[#c] = last + n
  else
    c[#c + 1] = n
  end
end

local function insert(op, s)
  if s == '' then
    return
  end
  op.target = op.target + #s
  local c = op.comps
  local n = #c
  local last = c[n]
  if type(last) == 'string' then
    c[n] = last .. s
  elseif type(last) == 'number' and last < 0 then
    if type(c[n - 1]) == 'string' then
      c[n - 1] = c[n - 1] .. s
    else
      c[n], c[n + 1] = s, last
    end
  else
    c[n + 1] = s
  end
end

local function delete(op, n)
  if n == 0 then
    return
  end
  op.base = op.base + n
  local c = op.comps
  local last = c[#c]
  if type(last) == 'number' and last < 0 then
    c[#c] = last - n
  else
    c[#c + 1] = -n
  end
end

local function push(op, c)
  if type(c) == 'string' then
    insert(op, c)
  elseif c > 0 then
    retain(op, c)
  elseif c < 0 then
    delete(op, -c)
  end
end

-- An op from components, normalized.
function M.from_comps(comps)
  local op = new()
  for _, c in ipairs(comps) do
    push(op, c)
  end
  return op
end

function M.identity(len)
  local op = new()
  retain(op, len)
  return op
end

-- The op for one edit {pos, del, ins} (bytes) on a text len bytes long. Errors if the edit doesn't fit.
function M.from_edit(e, len)
  if e.pos < 0 or e.del < 0 or e.pos + e.del > len then
    error(('edit out of range: pos %d del %d on %d bytes'):format(e.pos, e.del, len))
  end
  local op = new()
  retain(op, e.pos)
  insert(op, e.ins or '')
  delete(op, e.del)
  retain(op, len - e.pos - e.del)
  return op
end

-- The op for edits applied in order to a text len bytes long.
function M.from_edits(edits, len)
  local op = M.identity(len)
  for _, e in ipairs(edits) do
    op = M.compose(op, M.from_edit(e, op.target))
  end
  return op
end

-- The edits {pos, del, ins} an op makes, applied in order: one per insert and one per delete.
function M.to_edits(op)
  local out, pos = {}, 0
  for _, c in ipairs(op.comps) do
    if type(c) == 'string' then
      out[#out + 1] = { pos = pos, del = 0, ins = c }
      pos = pos + #c
    elseif c < 0 then
      out[#out + 1] = { pos = pos, del = -c, ins = '' }
    else
      pos = pos + c
    end
  end
  return out
end

-- Number of edits an op would send, for the statusline. nil counts 0.
function M.count(op)
  return op and #M.to_edits(op) or 0
end

local function len(c)
  if type(c) == 'string' then
    return #c
  end
  return c < 0 and -c or c
end

-- The first n bytes of a component, and what is left (nil when nothing is).
local function split(c, n)
  if n >= len(c) then
    return c, nil
  end
  if type(c) == 'string' then
    return c:sub(1, n), c:sub(n + 1)
  end
  if c < 0 then
    return -n, c + n
  end
  return n, c - n
end

-- Walks a component list, handing out parts of the current component.
local function cursor(comps)
  local i, head = 1, comps[1]
  local cur = {}
  function cur.peek()
    return head
  end
  function cur.whole()
    local h = head
    i = i + 1
    head = comps[i]
    return h
  end
  function cur.take(n)
    local a, rest = split(head, n)
    if rest == nil then
      i = i + 1
      rest = comps[i]
    end
    head = rest
    return a
  end
  return cur
end

local function is_insert(c)
  return type(c) == 'string'
end

local function is_delete(c)
  return type(c) == 'number' and c < 0
end

-- The op that applies a, then b. Errors if b doesn't start from a's result.
function M.compose(a, b)
  if a.target ~= b.base then
    error(('compose: first op makes %d bytes, second starts from %d'):format(a.target, b.base))
  end
  local out = new()
  local x, y = cursor(a.comps), cursor(b.comps)
  while x.peek() ~= nil or y.peek() ~= nil do
    if is_delete(x.peek()) then
      push(out, x.whole())
    elseif is_insert(y.peek()) then
      push(out, y.whole())
    else
      local n = math.min(len(x.peek()), len(y.peek()))
      local p, q = x.take(n), y.take(n)
      if is_delete(q) then
        if not is_insert(p) then
          delete(out, n)
        end
      elseif is_insert(p) then
        insert(out, p)
      else
        retain(out, n)
      end
    end
  end
  return out
end

-- transform(a, b) -> a', b' with compose(a, b') == compose(b, a'). On equal insert positions a goes first. Errors if
-- the two don't start from the same length.
function M.transform(a, b)
  if a.base ~= b.base then
    error(('transform: ops start from %d and %d bytes'):format(a.base, b.base))
  end
  local a2, b2 = new(), new()
  local x, y = cursor(a.comps), cursor(b.comps)
  while x.peek() ~= nil or y.peek() ~= nil do
    if is_insert(x.peek()) then
      local s = x.whole()
      insert(a2, s)
      retain(b2, #s)
    elseif is_insert(y.peek()) then
      local s = y.whole()
      retain(a2, #s)
      insert(b2, s)
    else
      local n = math.min(len(x.peek()), len(y.peek()))
      local p, q = x.take(n), y.take(n)
      if is_delete(p) and not is_delete(q) then
        delete(a2, n)
      elseif is_delete(q) and not is_delete(p) then
        delete(b2, n)
      elseif not is_delete(p) then
        retain(a2, n)
        retain(b2, n)
      end
    end
  end
  return a2, b2
end

-- Byte length of the common prefix of a and b, backed off to a character start in both.
local function cont(s, i)
  local c = s:byte(i)
  return c ~= nil and c >= 0x80 and c < 0xC0
end

-- Components turning a into b: common prefix and suffix kept (whole characters), the middle replaced. Also returns
-- the inserted ranges in b, as { {from, to} }.
function M.diff_comps(a, b)
  local n = math.min(#a, #b)
  local p = 0
  while p < n and a:byte(p + 1) == b:byte(p + 1) do
    p = p + 1
  end
  while p > 0 and (cont(a, p + 1) or cont(b, p + 1)) do
    p = p - 1
  end
  local s = 0
  while s < n - p and a:byte(#a - s) == b:byte(#b - s) do
    s = s + 1
  end
  while s > 0 and cont(a, #a - s + 1) do
    s = s - 1
  end
  local ins = b:sub(p + 1, #b - s)
  local op = new()
  retain(op, p)
  insert(op, ins)
  delete(op, #a - s - p)
  retain(op, s)
  local marks = {}
  if ins ~= '' then
    marks[1] = { p, p + #ins }
  end
  return op.comps, marks
end

-- Byte offset where each line starts, then the length (so starts[k] is line k's start, 1-based, and one past the last
-- line is the end).
local function line_starts(s)
  local out, i = { 0 }, 1
  while true do
    local j = s:find('\n', i, true)
    if not j then
      break
    end
    out[#out + 1] = j
    i = j + 1
  end
  if out[#out] ~= #s then
    out[#out + 1] = #s
  end
  return out
end

-- The op turning a into b, as fine as a line diff refined to characters: changes far apart stay apart, so another op
-- transformed past this one keeps its own edits between them (a single prefix/suffix diff would replace the whole
-- middle). Used to rebase unconfirmed edits on text that changed meanwhile.
function M.diff(a, b)
  if a == b then
    return M.identity(#a)
  end
  local ok, hunks = pcall(vim.diff, a, b, { result_type = 'indices', algorithm = 'histogram' })
  if not ok or type(hunks) ~= 'table' then
    return M.from_comps((M.diff_comps(a, b)))
  end
  local sa, sb = line_starts(a), line_starts(b)
  local function at(starts, line, count)
    -- byte range of `count` lines from `line` (1-based); count 0: the empty range after line `line`
    if count == 0 then
      local k = math.min(line + 1, #starts)
      return starts[k], starts[k]
    end
    return starts[math.min(line, #starts)], starts[math.min(line + count, #starts)]
  end
  local comps, pa = {}, 0
  for _, h in ipairs(hunks) do
    local a1, a2 = at(sa, h[1], h[2])
    local b1, b2 = at(sb, h[3], h[4])
    if a1 > pa then
      comps[#comps + 1] = a1 - pa
    end
    for _, c in ipairs((M.diff_comps(a:sub(a1 + 1, a2), b:sub(b1 + 1, b2)))) do
      comps[#comps + 1] = c
    end
    pa = a2
  end
  if #a > pa then
    comps[#comps + 1] = #a - pa
  end
  local okop, op = pcall(M.from_comps, comps)
  if okop and op.base == #a and op.target == #b and M.apply_string(a, M.to_edits(op)) == b then
    return op
  end
  return M.from_comps((M.diff_comps(a, b)))
end

-- Move a byte position through an op. stick 'left' stays before text inserted at the position; 'right' moves after
-- it. A position inside deleted text moves to where the delete was.
function M.map_pos(op, p, stick)
  local src, dst = 0, 0
  for _, c in ipairs(op.comps) do
    if type(c) == 'string' then
      if src > p or (src == p and stick ~= 'right') then
        break
      end
      dst = dst + #c
    elseif c < 0 then
      if p < src - c then
        return dst
      end
      src = src - c
    else
      if p < src + c then
        return dst + (p - src)
      end
      src, dst = src + c, dst + c
    end
  end
  return dst + (p - src)
end

-- Apply edits {pos, del, ins} in order to a string.
function M.apply_string(s, edits)
  for _, e in ipairs(edits) do
    s = s:sub(1, e.pos) .. e.ins .. s:sub(e.pos + e.del + 1)
  end
  return s
end

return M
