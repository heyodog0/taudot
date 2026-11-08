-- The plugin was called texsync until 2026-11-04; it is taudot now. A config that still says
-- require('texsync') or require('texsync.<module>') gets taudot's.
table.insert(package.loaders or package.searchers, 2, function(name)
  local rest = name:match('^texsync%.(.+)$')
  if rest then
    return function()
      return require('taudot.' .. rest)
    end
  end
end)
return require('taudot')
