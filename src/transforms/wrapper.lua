-- wrapper.lua: IIFE / nested function wrapper transform
local Wrapper = {}
Wrapper.__index = Wrapper

local function rng(seed)
  seed = seed or os.time()
  return function(lo, hi)
    seed = ((seed * 1664525 + 1013904223) & 0xFFFFFFFF)
    local v = seed & 0x7FFFFFFF
    if lo and hi then return math.floor((v/0x7FFFFFFF)*(hi-lo+1))+lo end
    return v/0x7FFFFFFF
  end
end

function Wrapper.new(config, rand)
  return setmetatable({
    config = config or {},
    rand = rand or rng(),
  }, Wrapper)
end

function Wrapper:ri(lo,hi) return self.rand(lo,hi) end

-- Wrap code lines in an IIFE layer
-- Returns lines array with the wrapping applied
function Wrapper:wrapOnce(lines, extraArgs)
  extraArgs = extraArgs or {}
  local argNames = {}
  local argVals  = {}
  for _, pair in ipairs(extraArgs) do
    argNames[#argNames+1] = pair[1]
    argVals[#argVals+1]   = pair[2]
  end

  local out = {}
  local argStr = table.concat(argNames, ", ")
  local valStr = table.concat(argVals,  ", ")

  out[#out+1] = string.format("(function(%s)", argStr)
  for _, ln in ipairs(lines) do
    out[#out+1] = "  " .. ln
  end
  out[#out+1] = string.format("end)(%s)", valStr)
  return out
end

-- Wrap code lines N times with optional env-passing
function Wrapper:wrapN(lines, n, passEnv)
  n = n or (self.config.wrapLayers or 1)
  local result = lines
  for i = 1, n do
    local extras = {}
    if passEnv and i == 1 then
      extras[#extras+1] = {"_ENV", "_ENV"}
    end
    -- Optionally pass a dummy arg for confusion
    if self:ri(1,2) == 1 then
      local k = self:ri(100,9999)
      extras[#extras+1] = { "_x"..i, tostring(k) }
    end
    result = self:wrapOnce(result, extras)
  end
  return result
end

-- Generate the full wrapping preamble/epilogue as line lists
function Wrapper:generate(innerLines)
  local layers = self.config.wrapLayers or 1
  return self:wrapN(innerLines, layers, false)
end

return { Wrapper = Wrapper }
