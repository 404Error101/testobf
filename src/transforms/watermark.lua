-- watermark.lua: Embed forensic watermarks into obfuscated output
local Watermark = {}
Watermark.__index = Watermark

local function rng(seed)
  seed = seed or os.time()
  return function(lo, hi)
    seed = ((seed * 1664525 + 1013904223) & 0xFFFFFFFF)
    local v = seed & 0x7FFFFFFF
    if lo and hi then return math.floor((v/0x7FFFFFFF)*(hi-lo+1))+lo end
    return v/0x7FFFFFFF
  end
end

function Watermark.new(config, rand)
  return setmetatable({
    config = config or {},
    rand = rand or rng(),
  }, Watermark)
end

function Watermark:ri(lo,hi) return self.rand(lo,hi) end

-- Encode a string as binary-like numeric constants hidden in dead code
function Watermark:encodeString(s)
  local nums = {}
  for i = 1, #s do nums[i] = s:byte(i) end
  return nums
end

-- Generate watermark code that hides the mark in unreachable computations
function Watermark:generateCode(mark, varPrefix)
  mark = mark or (self.config.watermark or ("WM_" .. tostring(os.time())))
  varPrefix = varPrefix or ("_wm" .. tostring(self:ri(100,999)))

  local bytes = self:encodeString(mark)
  local lines = {}

  -- Store watermark bytes in a dead table
  lines[#lines+1] = string.format("-- [Watermark ID: %s]", mark)
  lines[#lines+1] = string.format("local %s = {", varPrefix)
  for i, b in ipairs(bytes) do
    -- obfuscate each byte as xor expression
    local k = self:ri(1, 127)
    lines[#lines+1] = string.format("  [%d] = %d ~ %d,", i, b ~ k, k)
  end
  lines[#lines+1] = "}"
  -- Ensure the table is "used" to prevent optimizers from stripping it
  lines[#lines+1] = string.format("local %s_len = #%s", varPrefix, varPrefix)
  lines[#lines+1] = string.format("if %s_len < 0 then error('wm') end", varPrefix)

  return lines, mark
end

return { Watermark = Watermark }
