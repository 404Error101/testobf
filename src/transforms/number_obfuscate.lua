-- number_obfuscate.lua: Convert numeric constants to MBA expressions
local NumberObf = {}
NumberObf.__index = NumberObf

local function rng(seed)
  seed = seed or os.time()
  return function(lo, hi)
    seed = ((seed * 6364136223846793005 + 1442695040888963407) & 0x7FFFFFFFFFFFFFFF)
    local v = (seed >> 17) & 0xFFFFFFFF
    if lo and hi then
      return math.floor((v / 0xFFFFFFFF) * (hi - lo + 1)) + lo
    end
    return v / 0xFFFFFFFF
  end
end

function NumberObf.new(config, rand)
  return setmetatable({
    config = config or {},
    rand = rand or rng(),
  }, NumberObf)
end

-- MBA identity: n = (n ^ k) ^ k  (XOR cancel)
-- MBA identity: n = (n + k) - k
-- MBA identity: n = (n | k) + (n & k) - ... etc.
-- We use integer-safe operations only

local function isInt(n)
  return math.type and math.type(n) == "integer" or (n == math.floor(n) and n >= -2^31 and n <= 2^31)
end

function NumberObf:intExpr(n, depth)
  depth = depth or 0
  if depth > 3 then return tostring(n) end

  local choice = self.rand(1, 5)

  if choice == 1 then
    -- XOR split: n = (n ~ k) ~ k
    local k = self.rand(1, 255)
    local hidden = n ~ k
    return string.format("(%d ~ %d)", hidden, k)

  elseif choice == 2 then
    -- Additive split: n = (n + k) - k
    local k = self.rand(100, 9999)
    return string.format("(%d - %d)", n + k, k)

  elseif choice == 3 then
    -- Multi-step: n = a * b + c
    if n ~= 0 and math.abs(n) < 10000 then
      local a = self.rand(2, 7)
      local product = n * a
      local extra = self.rand(10, 999)
      -- n = (product + extra * a) / a - extra ... but keep integer safe
      -- simpler: n = (n + k) // 1 - k
      local k = self.rand(100, 500)
      return string.format("((%d + %d) - %d)", n, k, k)
    else
      local k = self.rand(1, 127)
      return string.format("(%d ~ %d)", n ~ k, k)
    end

  elseif choice == 4 then
    -- Bitwise: n = (n | mask) - (mask & ~n)  (identity when bits don't overlap)
    -- Simpler safe MBA: n = -(~n) - 1
    -- ~n in Lua = -n - 1, so -(-n-1) - 1 = n
    if n >= -2^30 and n <= 2^30 then
      return string.format("(-(~%d) - 1)", n)
    else
      return tostring(n)
    end

  else
    -- Constant folding obf: split into two parts
    if math.abs(n) > 1 and math.abs(n) < 100000 then
      local half = math.floor(n / 2)
      local rest = n - half
      return string.format("(%s + %s)",
        self:intExpr(half, depth+1),
        self:intExpr(rest, depth+1))
    else
      return tostring(n)
    end
  end
end

function NumberObf:floatExpr(n)
  -- For floats, use simple additive split
  local k = self.rand(100, 9999) / 100.0
  -- Use string.format to maintain precision
  local hidden = n + k
  return string.format("(%.17g - %.17g)", hidden, k)
end

function NumberObf:obfuscate(n)
  if type(n) ~= "number" then return tostring(n) end
  if n ~= n then return "(0/0)" end          -- NaN
  if n == math.huge then return "(1/0)" end
  if n == -math.huge then return "(-1/0)" end

  -- Special trivial cases
  if n == 0 then
    local k = self.rand(1, 255)
    return string.format("(%d ~ %d)", k, k)
  end
  if n == 1 then
    return "(1 & 1)"
  end

  if isInt(n) and math.abs(n) <= 2^30 then
    return self:intExpr(math.tointeger and math.tointeger(n) or math.floor(n))
  else
    return self:floatExpr(n)
  end
end

-- Walk AST and replace Number nodes with obfuscated expressions (as raw code)
function NumberObf:transform(ast)
  self:walk(ast)
end

function NumberObf:walk(node)
  if not node or type(node) ~= "table" then return end

  if node.kind == "Number" then
    local n = tonumber(node.value)
    if n then
      node._obfExpr = self:obfuscate(n)
      node._obfuscated = true
    end
    return
  end

  for k, v in pairs(node) do
    if type(v) == "table" and k ~= "symbol" then
      self:walk(v)
    end
  end
end

return { NumberObf = NumberObf }
