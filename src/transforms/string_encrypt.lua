-- string_encrypt.lua: Multi-layer string encryption transform
local StringEncrypt = {}
StringEncrypt.__index = StringEncrypt

local function rng(seed)
  seed = seed or os.time()
  return function(lo, hi)
    seed = ((seed * 1664525 + 1013904223) & 0xFFFFFFFF)
    if lo and hi then
      return math.floor((seed / 0xFFFFFFFF) * (hi - lo + 1)) + lo
    end
    return seed / 0xFFFFFFFF
  end
end

function StringEncrypt.new(config, rand)
  return setmetatable({
    config = config or {},
    rand = rand or rng(),
  }, StringEncrypt)
end

-- XOR encrypt with a random key
function StringEncrypt:xorEncrypt(s, key)
  local out = {}
  for i = 1, #s do
    local b = s:byte(i)
    local k = key:byte(((i-1) % #key) + 1)
    out[i] = string.char(b ~ k)
  end
  return table.concat(out)
end

-- Rotation cipher
function StringEncrypt:rotate(s, n)
  n = n % 256
  local out = {}
  for i = 1, #s do
    out[i] = string.char((s:byte(i) + n) % 256)
  end
  return table.concat(out)
end

-- Generate a random key string
function StringEncrypt:genKey(len)
  len = len or self.rand(4, 12)
  local chars = {}
  for i = 1, len do
    chars[i] = string.char(self.rand(1, 255))
  end
  return table.concat(chars)
end

-- Encode bytes to a Lua string literal with escapes
function StringEncrypt:toLuaStr(s)
  local parts = {}
  for i = 1, #s do
    local b = s:byte(i)
    parts[i] = string.format("\\%d", b)
  end
  return '"' .. table.concat(parts) .. '"'
end

-- Encode key as Lua string literal
function StringEncrypt:keyToLua(key)
  return self:toLuaStr(key)
end

-- Generate the runtime decryptor function (emitted once at top of file)
-- Returns: function name, function definition code
function StringEncrypt:makeDecryptorCode(funcName, rot)
  rot = rot or self.rand(1, 200)
  -- The decryptor does: unrotate then xor
  return funcName, rot, string.format([[
local function %s(s, k, r)
  local t = {}
  for i = 1, #s do
    t[i] = string.char((s:byte(i) - r + 256) %% 256 ~ k:byte(((i-1) %% #k)+1))
  end
  return table.concat(t)
end]], funcName)
end

-- Encrypt a single string value, return Lua expression that decrypts at runtime
function StringEncrypt:encryptString(s, decFuncName, rot)
  if #s == 0 then return '""' end
  local key = self:genKey()
  -- Apply rotation first, then XOR
  local rotated = self:rotate(s, rot)
  local xored = self:xorEncrypt(rotated, key)
  return string.format("%s(%s, %s, %d)",
    decFuncName,
    self:toLuaStr(xored),
    self:keyToLua(key),
    rot
  )
end

-- Walk AST and encrypt all string literals
function StringEncrypt:transform(ast, decFuncName, rot)
  self:walkNode(ast, decFuncName, rot)
end

function StringEncrypt:walkNode(node, decFuncName, rot)
  if not node or type(node) ~= "table" then return end

  if node.kind == "String" then
    -- Mark for encryption; store encrypted expression
    node._encryptedExpr = self:encryptString(node.value, decFuncName, rot)
    node._encrypted = true
    return
  end

  -- Walk all table fields recursively
  for k, v in pairs(node) do
    if type(v) == "table" and k ~= "symbol" then
      self:walkNode(v, decFuncName, rot)
    end
  end
end

return { StringEncrypt = StringEncrypt }
