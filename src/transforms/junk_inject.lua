-- junk_inject.lua: Dead/junk code injection transform
local JunkInject = {}
JunkInject.__index = JunkInject

local function rng(seed)
  seed = seed or os.time()
  return function(lo, hi)
    seed = ((seed * 1664525 + 1013904223) & 0xFFFFFFFF)
    local v = seed & 0x7FFFFFFF
    if lo and hi then return math.floor((v/0x7FFFFFFF)*(hi-lo+1))+lo end
    return v / 0x7FFFFFFF
  end
end

function JunkInject.new(config, rand)
  return setmetatable({
    config = config or {},
    rand = rand or rng(),
    _vc = 0,
  }, JunkInject)
end

function JunkInject:ri(lo,hi) return self.rand(lo,hi) end
function JunkInject:rf() return self.rand() end

function JunkInject:varName()
  self._vc = self._vc + 1
  return "_j" .. tostring(self._vc)
end

-- Returns a list of junk code line strings
function JunkInject:makeJunk(kind)
  kind = kind or self:ri(1,8)
  local v = self:varName()

  if kind == 1 then
    -- Dead numeric computation
    local a,b = self:ri(1,1000), self:ri(1,100)
    return {
      string.format("local %s = %d * %d + %d", v, a, b, self:ri(0,99)),
      string.format("if %s > %d then %s = %s - %d end",
        v, a*b+100, v, v, self:ri(1,50)),
    }

  elseif kind == 2 then
    -- Always-false branch
    local k = self:ri(1,255)
    return {
      string.format("if (%d ~ %d) == %d then", k, k, self:ri(1,254)),
      string.format("  local %s = %q", v, "unreachable_"..self:ri(1000,9999)),
      "end",
    }

  elseif kind == 3 then
    -- Dead table construction
    local size = self:ri(2,5)
    local entries = {}
    for i=1,size do
      entries[i] = string.format("[%d]=%d", i, self:ri(0,9999))
    end
    return {
      string.format("local %s = {%s}", v, table.concat(entries,",")),
      string.format("%s[%d] = %s[%d] or %d",
        v, self:ri(1,size), v, self:ri(1,size), self:ri(0,9999)),
    }

  elseif kind == 4 then
    -- Redundant string op
    local words = {"obfuscated","protected","secured","encoded","hidden"}
    local w = words[self:ri(1,#words)]
    return {
      string.format("local %s = string.rep(%q, 0)", v, w),
      string.format("if #%s > 0 then %s = '' end", v, v),
    }

  elseif kind == 5 then
    -- Opaque predicate using math
    -- (n^2 >= 0) is always true; we invert to make always-false branch
    local n = self:ri(1,99)
    return {
      string.format("if not (%d * %d >= 0) then", n, n),
      string.format("  error('impossible_%d')", self:ri(1000,9999)),
      "end",
    }

  elseif kind == 6 then
    -- Bogus loop that never executes
    return {
      string.format("local %s = %d", v, self:ri(10,99)),
      string.format("while %s < %d do", v, self:ri(0,9)),
      string.format("  %s = %s + 1", v, v),
      "end",
    }

  elseif kind == 7 then
    -- Fake function call chain result ignored
    local fns = {"math.max","math.min","math.abs","math.floor"}
    local fn = fns[self:ri(1,#fns)]
    return {
      string.format("local %s = %s(%d, %d)",
        v, fn, self:ri(0,100), self:ri(0,100)),
      string.format("%s = %s + 0", v, v),
    }

  else
    -- XOR no-op
    local k = self:ri(1,255)
    return {
      string.format("local %s = %d ~ %d ~ %d", v, k, self:ri(1,255), self:ri(1,255)),
      string.format("_ = %s", v),
    }
  end
end

-- Inject junk into a block's body list (mutates the list by inserting junk strings)
-- We mark injection points, actual emission is in codegen
function JunkInject:injectIntoBlock(block, density)
  density = density or self.config.junkDensity or 0.3
  if not block or not block.body then return end

  -- We'll add metadata markers between statements
  local newBody = {}
  for i, stmt in ipairs(block.body) do
    -- Inject before some statements
    if self:rf() < density then
      local junk = self:makeJunk()
      newBody[#newBody+1] = {
        kind = "_Junk",
        lines = junk,
        line = stmt.line or 0,
      }
    end
    newBody[#newBody+1] = stmt
  end
  -- Maybe inject at end
  if self:rf() < density * 0.5 then
    newBody[#newBody+1] = {
      kind = "_Junk",
      lines = self:makeJunk(),
      line = 0,
    }
  end
  block.body = newBody
end

function JunkInject:transform(ast, density)
  self:walk(ast, density)
end

function JunkInject:walk(node, density)
  if not node or type(node) ~= "table" then return end

  if node.kind == "Block" and node.body then
    self:injectIntoBlock(node, density)
  end

  for k, v in pairs(node) do
    if type(v) == "table" and k ~= "symbol" then
      self:walk(v, density)
    end
  end
end

return { JunkInject = JunkInject }
