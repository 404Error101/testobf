-- renamer.lua: High-entropy identifier renaming transform
local Renamer = {}
Renamer.__index = Renamer

-- Characters valid in Lua identifiers (after first char)
local ALPHA = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
local ALNUM = ALPHA .. "0123456789_"

-- Visually confusing character sets for maximum entropy
local CONFUSE_SETS = {
  -- Set 1: mix of l, I, 1-like chars where possible
  { "l","I","lI","Il","lIl","IlI","llI","Ill" },
  -- Set 2: O, 0 confusion
  { "O","OO","OOO" },
  -- Set 3: mixed case entropy
  { "xX","Xx","xXx","XxX" },
}

local function rng(seed)
  -- Xorshift32
  seed = seed or os.time()
  return function()
    seed = seed ~ (seed << 13)
    seed = seed ~ (seed >> 7)
    seed = seed ~ (seed << 17)
    seed = seed & 0xFFFFFFFF
    return seed / 0xFFFFFFFF
  end
end

function Renamer.new(config, seed)
  local r = rng(seed or os.time())
  return setmetatable({
    config = config or {},
    rand = r,
    used = {},
    map = {},    -- original name → obf name (per scope chain)
    counter = 0,
  }, Renamer)
end

function Renamer:randChar(set)
  local i = math.floor(self.rand() * #set) + 1
  return set:sub(i,i)
end

function Renamer:randInt(lo, hi)
  return math.floor(self.rand() * (hi - lo + 1)) + lo
end

-- Generate a single high-entropy identifier
function Renamer:genName(minLen, maxLen)
  minLen = minLen or 8
  maxLen = maxLen or 20
  local len = self:randInt(minLen, maxLen)

  -- Strategy: use visually confusing l/I/O patterns
  local styles = {
    -- Style A: pure lI confuse
    function(n)
      local chars = {"l","I"}
      local r = {}
      for i=1,n do r[i] = chars[self:randInt(1,2)] end
      return table.concat(r)
    end,
    -- Style B: underscore prefix + hex-like
    function(n)
      local hex = "0123456789abcdef"
      local r = {"_"}
      for i=2,n do
        if self.rand() < 0.3 then r[i] = "_"
        else r[i] = hex:sub(self:randInt(1,16),self:randInt(1,16):gsub(".",""):len()+self:randInt(1,16)) end
      end
      -- fix: just build it cleanly
      r = {"_"}
      for i=2,n do
        local pick = self:randInt(1, #hex)
        r[i] = hex:sub(pick,pick)
      end
      return table.concat(r)
    end,
    -- Style C: mixed case madness
    function(n)
      local r = {}
      -- first char must be alpha
      r[1] = ALPHA:sub(self:randInt(1,#ALPHA), self:randInt(1,#ALPHA))
      if #r[1] > 1 then r[1] = r[1]:sub(1,1) end
      for i=2,n do
        local c = ALNUM:sub(self:randInt(1,#ALNUM), self:randInt(1,#ALNUM))
        r[i] = c:sub(1,1)
      end
      return table.concat(r)
    end,
  }

  local style = styles[self:randInt(1,#styles)]
  local name = style(len)

  -- Ensure first char is valid (letter or _)
  local fc = name:sub(1,1)
  if not fc:match("[%a_]") then
    name = ALPHA:sub(self:randInt(1,#ALPHA),self:randInt(1,#ALPHA)):sub(1,1) .. name:sub(2)
  end

  return name
end

-- Generate a guaranteed-unique name
function Renamer:unique(minLen, maxLen)
  local attempts = 0
  while true do
    local name = self:genName(minLen, maxLen)
    if not self.used[name] then
      self.used[name] = true
      return name
    end
    attempts = attempts + 1
    if attempts > 1000 then
      -- fallback: append counter
      self.counter = self.counter + 1
      name = name .. tostring(self.counter)
      self.used[name] = true
      return name
    end
  end
end

-- Rename all eligible symbols in the resolver's symbol table
function Renamer:renameAll(resolver, config)
  config = config or self.config
  local preserve = config.preserve or {}
  local preserveSet = {}
  for _, n in ipairs(preserve) do preserveSet[n] = true end

  -- Always preserve _G, _ENV, self
  for _, n in ipairs({"_G","_ENV","self","..."}) do
    preserveSet[n] = true
  end

  for _, sym in ipairs(resolver.symbols) do
    if sym.kind == "global" then
      -- don't rename globals by default (they refer to std lib etc.)
      if config.renameGlobals and not preserveSet[sym.name] then
        sym.obfName = self:unique()
      end
    elseif sym.kind == "local" or sym.kind == "param" then
      if not preserveSet[sym.name] then
        sym.obfName = self:unique()
      end
    end
  end
end

-- Apply renames to AST nodes (after resolver has set .symbol on Name nodes)
-- This is done during code generation, not here.
-- But we export a helper:
function Renamer:getName(sym)
  if sym and sym.obfName then return sym.obfName end
  if sym then return sym.name end
  return nil
end

return { Renamer = Renamer }
