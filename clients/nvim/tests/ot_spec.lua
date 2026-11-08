-- nvim --headless --clean -l tests/ot_spec.lua
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h'))
local ot = require('taudot.ot')

local seed = 7
local function r()
  seed = (seed * 1103515245 + 12345) % 2147483648
  return seed / 2147483648
end
local alphabet = { 'a', 'b', '\n', 'é', '😀', 'xy' }

local function chars(s)
  local t = {}
  for c in s:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
    t[#t + 1] = c
  end
  return t
end

local function random_edits(text)
  local edits, t = {}, text
  for _ = 1, 1 + math.floor(r() * 3) do
    local cs = chars(t)
    local i = math.floor(r() * (#cs + 1))
    local d = math.floor(r() * math.min(3, #cs - i + 1))
    local ins = ''
    for _ = 1, math.floor(r() * 3) do
      ins = ins .. alphabet[1 + math.floor(r() * #alphabet)]
    end
    local pos = #table.concat(cs, '', 1, i)
    local del = #table.concat(cs, '', i + 1, i + d)
    edits[#edits + 1] = { pos = pos, del = del, ins = ins }
    t = t:sub(1, pos) .. ins .. t:sub(pos + del + 1)
  end
  return edits
end

local fails = 0
for _ = 1, 5000 do
  local t = 'ab é😀\ncd\nef'
  local ea, eb = random_edits(t), random_edits(t)
  local a, b = ot.from_edits(ea, #t), ot.from_edits(eb, #t)
  assert(ot.apply_string(t, ot.to_edits(a)) == ot.apply_string(t, ea), 'round trip')
  local a2, b2 = ot.transform(a, b)
  local left = ot.apply_string(ot.apply_string(t, ea), ot.to_edits(b2))
  local right = ot.apply_string(ot.apply_string(t, eb), ot.to_edits(a2))
  if left ~= right then
    fails = fails + 1
    if fails < 3 then
      print(vim.inspect({ ea = ea, eb = eb, left = left, right = right }))
    end
  end
end
local a = ot.from_edits({ { pos = 1, del = 0, ins = 'A' } }, 2)
local b = ot.from_edits({ { pos = 1, del = 0, ins = 'B' } }, 2)
local _, b2 = ot.transform(a, b)
assert(ot.apply_string('xAy', ot.to_edits(b2)) == 'xABy', 'tie order')
if fails > 0 then
  print('FAIL ' .. fails)
  os.exit(1)
end
print('ot ok')
