local M = {}

function M.check()
  local h = vim.health
  local config = require('taudot.config')
  h.start('taudot')

  if vim.fn.has('nvim-0.12') == 1 then
    h.ok('Neovim ' .. tostring(vim.version()))
  else
    h.error('Neovim 0.12 or later is needed, this is ' .. tostring(vim.version()))
  end

  local sock = config.socket()
  local state = vim.fs.joinpath(vim.fs.dirname(sock), 'engine.json')
  local f = io.open(state)
  if f then
    local ok, info = pcall(vim.json.decode, f:read('*a'))
    f:close()
    if ok and type(info) == 'table' then
      h.ok(('engine.json: pid %s, api level %s, version %s'):format(info.pid, info.api_level, info.version))
      if info.pid and not pcall(vim.uv.kill, info.pid, 0) then
        h.warn('engine.json names pid ' .. info.pid .. ', which is not running (stale file)')
      end
    else
      h.warn(state .. ' is not valid JSON')
    end
  else
    h.info('no ' .. state .. ' (no engine has started here)')
  end

  if not vim.uv.fs_stat(sock) then
    h.error('engine socket ' .. sock .. ' does not exist', { 'Start the engine, or the mock: deno task start in clients/mock-engine' })
  else
    local done, result = false, nil
    require('taudot.rpc').connect(sock, { on_notify = function() end, on_close = function() end }, function(err, client)
      if err then
        done, result = true, { err = err }
        return
      end
      client:request('engine.info', nil, function(e, info)
        done, result = true, { err = e and vim.inspect(e), info = info }
        client:close()
      end)
    end)
    vim.wait(2000, function()
      return done
    end, 20)
    if not done then
      h.error('no answer from ' .. sock .. ' within 2 s')
    elseif result.err then
      h.error('cannot talk to the engine: ' .. tostring(result.err))
    else
      local lvl = result.info.api_level
      h.ok(('engine answers: %s, api level %s'):format(result.info.version, lvl))
      if type(lvl) ~= 'number' or lvl < 0 then
        h.error('unexpected api level ' .. tostring(lvl))
      end
    end
  end

  local p = require('taudot').project()
  if p then
    h.ok(('project %s at %s, %s'):format(p.project_id or '?', p.folder, p.connection))
    for _, b in pairs(require('taudot').buffers()) do
      h.info(('%s: seq %d, %d unconfirmed'):format(b.path, b.seq, b:unconfirmed()))
    end
  else
    h.info('no project open in this Neovim (:Taudot open <folder>)')
  end

  local o = config.options
  if not o.mappings then
    h.info('review mappings off (mappings = false)')
  else
    h.ok(('review mappings under %s (`:h taudot-mappings`)'):format(o.mapping_prefix))
    local skipped = require('taudot.keys').skipped
    local keys = vim.tbl_keys(skipped)
    table.sort(keys)
    for _, k in ipairs(keys) do
      h.warn(('%s is already mapped (%s); taudot left it alone'):format(k, skipped[k]))
    end
  end
  if pcall(require, 'telescope.pickers') then
    h.ok('Telescope found: :Taudot comments and changes use it')
  else
    h.info('Telescope not found: :Taudot comments and changes use vim.ui.select')
  end

  if vim.o.termguicolors then
    h.ok('termguicolors on: author colours fade from your colourscheme')
  else
    h.info('termguicolors off: author colours use the terminal ANSI palette, without a smooth fade')
  end
  if vim.fn.executable('rex') == 1 then
    h.ok('rex found: clients/rex/taudot-layout.sh can build a session')
  else
    h.info('rex not found (optional)')
  end
end

return M
