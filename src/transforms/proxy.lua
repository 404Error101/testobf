-- proxy.lua: Variable proxying and table-based indirection transform
-- Wraps global function lookups through proxy tables
local Proxy = {}
Proxy.__index = Proxy

local function rng(seed)
  seed = seed or os.time()
  return function(lo, hi)
    seed = ((seed * 1664525 + 1013904223) & 0xFFFFFFFF)
    local v = seed & 0x7FFFFFFF
    if lo and hi then return math.floor((v/0x7FFFFFFF)*(hi-lo+1))+lo end
    return v/0x7FFFFFFF
  end
end

function Proxy.new(config, rand)
  return setmetatable({
    config = config or {},
    rand = rand or rng(),
    proxyTable = nil,
    proxyVarName = nil,
    keyMap = {}, -- original key -> obf key
    _kc = 0,
  }, Proxy)
end

function Proxy:ri(lo, hi) return self.rand(lo, hi) end

function Proxy:obfKey(name)
  if self.keyMap[name] then return self.keyMap[name] end
  self._kc = self._kc + 1
  local k = "_k" .. tostring(self._kc) .. "_" .. tostring(self:ri(100,999))
  self.keyMap[name] = k
  return k
end

-- Standard library globals to proxy
local STD_GLOBALS = {
  "print","tostring","tonumber","type","pairs","ipairs","next","select",
  "unpack","table","string","math","io","os","coroutine","rawget","rawset",
  "rawequal","rawlen","setmetatable","getmetatable","require","pcall","xpcall",
  "error","assert","load","loadfile","dofile","collectgarbage",
}

-- Generate proxy table initialization code
function Proxy:makeProxyInit(varName, obfKeys)
  varName = varName or self.proxyVarName
  local lines = {}
  lines[#lines+1] = string.format("local %s = {}", varName)

  -- Shuffle the assignments for extra confusion
  local items = {}
  for orig, obf in pairs(obfKeys) do
    items[#items+1] = { orig=orig, obf=obf }
  end
  -- shuffle
  for i = #items, 2, -1 do
    local j = self:ri(1, i)
    items[i], items[j] = items[j], items[i]
  end

  for _, item in ipairs(items) do
    -- Split the assignment across multiple lines with intermediate vars for confusion
    local tmp = "_t" .. tostring(self:ri(1000,9999))
    lines[#lines+1] = string.format("local %s = %s", tmp, item.orig)
    lines[#lines+1] = string.format("%s[%q] = %s", varName, item.obf, tmp)
  end

  return lines
end

-- Generate Lua code for proxy setup
function Proxy:generateCode(proxyVarName)
  proxyVarName = proxyVarName or ("_p" .. tostring(self:ri(1000,9999)))
  self.proxyVarName = proxyVarName

  local obfKeys = {}
  for _, g in ipairs(STD_GLOBALS) do
    obfKeys[g] = self:obfKey(g)
  end
  self.obfKeys = obfKeys

  local lines = self:makeProxyInit(proxyVarName, obfKeys)
  return lines, proxyVarName, obfKeys
end

-- Get the proxy access expression for a global name
function Proxy:access(name)
  if not self.proxyVarName or not self.obfKeys then return name end
  local k = self.obfKeys[name]
  if k then
    return string.format("%s[%q]", self.proxyVarName, k)
  end
  return name
end

return { Proxy = Proxy, STD_GLOBALS = STD_GLOBALS }
