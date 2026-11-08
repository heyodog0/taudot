-- nvim --headless --clean -l tests/ot_fixtures_spec.lua
-- Checks taudot.ot against crates/ot2/fixtures/byte_ops.json, whose expected values ot2 computed
-- (crates/ot2/tests/byte_fixtures.rs). TAUDOT_OT_FIXTURE=<path> checks another fixture file instead.
local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
vim.opt.rtp:prepend(vim.fn.fnamemodify(here, ':h'))
local ot = require('taudot.ot')

local path = os.getenv('TAUDOT_OT_FIXTURE') or (here .. '/../../../crates/ot2/fixtures/byte_ops.json')
local f = assert(io.open(path, 'rb'))
local cases = vim.json.decode(f:read('*a'))
f:close()

local fails = 0
local function check(i, what, got, want)
  if not vim.deep_equal(got, want) then
    fails = fails + 1
    if fails <= 5 then
      print(('case %d %s:\n  got  %s\n  want %s\n  case %s'):format(i, what, vim.inspect(got), vim.inspect(want),
        vim.json.encode(cases[i])))
    end
  end
end

local function edits(es)
  local out = {}
  for _, e in ipairs(es) do
    out[#out + 1] = { pos = e.pos, del = e.del, ins = e.ins }
  end
  return out
end

for i, c in ipairs(cases) do
  local a, b = ot.from_comps(c.a), ot.from_comps(c.b)
  check(i, 'from_comps(a)', a.comps, c.a)
  check(i, 'base/target', { a.base, a.target }, { #c.base, #c.after_a })
  check(i, 'compose', ot.compose(a, ot.from_comps(c.c)).comps, c.compose_ac)
  local a2, b2 = ot.transform(a, b)
  check(i, 'transform', { a2.comps, b2.comps }, c.transform_ab)
  check(i, 'from_comps(raw)', ot.from_comps(c.raw).comps, c.from_comps)
  local ok, fe = pcall(ot.from_edits, edits(c.edits), #c.base)
  check(i, 'from_edits', ok and fe.comps or vim.NIL, c.from_edits)
  if #c.edits == 1 and c.from_edits ~= vim.NIL then
    check(i, 'from_edit', ot.from_edit(c.edits[1], #c.base).comps, c.from_edits)
  end
  local ea = ot.to_edits(a)
  check(i, 'to_edits', ea, edits(c.to_edits_a))
  check(i, 'count', ot.count(a), c.count_a)
  check(i, 'apply_string', ot.apply_string(c.base, ea), c.after_a)
  for _, m in ipairs(c.map_a) do
    check(i, ('map_pos %d %s'):format(m[1], m[2]), ot.map_pos(a, m[1], m[2]), m[3])
  end
  local comps, marks = ot.diff_comps(c.base, c.other)
  check(i, 'diff_comps', { comps, marks }, { c.diff.comps, c.diff.marks })
  if c.wrong_len ~= vim.NIL then
    local x = ot.from_comps(c.wrong_len)
    check(i, 'compose refuses', (pcall(ot.compose, a, x)), a.target == x.base)
    check(i, 'transform refuses', (pcall(ot.transform, a, x)), false)
  end
end
check(0, 'count(nil)', ot.count(nil), 0)
if fails > 0 then
  print(('FAIL %d differences in %d cases'):format(fails, #cases))
  os.exit(1)
end
print(('ot fixtures ok: %d cases'):format(#cases))
