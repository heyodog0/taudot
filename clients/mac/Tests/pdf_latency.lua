-- Typing at human speed (100-250 ms between keys) for Tests/pdf_latency.sh: ~60 s in the abstract (line 163 of the
-- maintainer's paper, page 1), then ~60 s in a later section (line 361, page 3). TYPE_LOG gets "key T" per keystroke (T on
-- the same clock as the app's CACurrentMediaTime) and "part ..." markers.
local api, uv = vim.api, vim.loop
local log = io.open(os.getenv('TYPE_LOG') or '/dev/null', 'a')
local function say(s) log:write(s .. '\n'); log:flush() end
local now = function() return uv.hrtime() / 1e9 end
math.randomseed(tonumber(os.getenv('TYPE_SEED') or '11'))
local secs = tonumber(os.getenv('PART_SECONDS') or '60')
local text = 'the agents learn quickly when the environment is simple and the reward is dense but they struggle '
  .. 'when rewards are sparse and the levels change between episodes so we vary both in our experiments '
local parts = { { line = 163, name = 'abstract' }, { line = 361, name = 'section' } }
local p, k, t_end = 0, 0, 0
local function key()
  if now() > t_end then
    api.nvim_feedkeys(api.nvim_replace_termcodes('<Esc>', true, false, true), 'nt', false)
    p = p + 1
    local part = parts[p]
    if not part then say('end'); return end
    vim.defer_fn(function()
      vim.cmd('normal! ' .. part.line .. 'G0w')
      api.nvim_feedkeys('i', 'nt', false)
      say(string.format('part %s %.4f', part.name, now()))
      t_end = now() + secs
      vim.defer_fn(key, 1500)
    end, 2500)
    return
  end
  k = k + 1
  local ch = text:sub((k - 1) % #text + 1, (k - 1) % #text + 1)
  if k % 17 == 0 then ch = '<BS>' end
  api.nvim_feedkeys(api.nvim_replace_termcodes(ch, true, false, true), 'nt', false)
  say(string.format('key %.4f', now()))
  vim.defer_fn(key, 100 + math.random(150))
end
vim.defer_fn(function() say(string.format('start %.4f', now())); key() end, tonumber(os.getenv('START_MS') or '10000'))
