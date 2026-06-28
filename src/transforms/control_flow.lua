-- control_flow.lua: Control flow flattening transform
-- Converts function bodies into state-machine dispatcher loops
-- This is a code-generation level transform that operates on AST blocks

local CFF = {}
CFF.__index = CFF

local function rng(seed)
  seed = seed or os.time()
  return function(lo, hi)
    seed = ((seed * 1664525 + 1013904223) & 0xFFFFFFFF)
    local v = seed & 0x7FFFFFFF
    if lo and hi then return math.floor((v / 0x7FFFFFFF) * (hi-lo+1)) + lo end
    return v / 0x7FFFFFFF
  end
end

function CFF.new(config, rand)
  return setmetatable({
    config = config or {},
    rand = rand or rng(),
    stateVar = nil,
  }, CFF)
end

function CFF:randInt(lo, hi)
  return self.rand(lo, hi)
end

-- Generate a shuffled list of state IDs
function CFF:makeStateIds(n)
  local ids = {}
  local used = {}
  for i = 1, n do
    local id
    repeat id = self:randInt(100, 9999) until not used[id]
    used[id] = true
    ids[i] = id
  end
  return ids
end

-- Flatten a function body's statements into a state machine
-- Returns the Lua code for the state-machine wrapper
function CFF:flattenBody(stmts, genCode, stateVarName, dispatchVarName)
  if #stmts < 2 then return nil end -- not worth flattening

  local stateIds = self:makeStateIds(#stmts + 1) -- +1 for exit state
  local exitState = stateIds[#stateIds]

  local lines = {}
  lines[#lines+1] = string.format("local %s = %d", stateVarName, stateIds[1])
  lines[#lines+1] = string.format("while %s ~= %d do", stateVarName, exitState)

  -- Build dispatcher: if/elseif chain over state variable
  -- We shuffle the order to prevent trivial reconstruction
  local order = {}
  for i = 1, #stmts do order[i] = i end
  -- simple shuffle
  for i = #order, 2, -1 do
    local j = self:randInt(1, i)
    order[i], order[j] = order[j], order[i]
  end

  local first = true
  for _, idx in ipairs(order) do
    local kw = first and "if" or "elseif"
    first = false
    lines[#lines+1] = string.format("  %s %s == %d then",
      kw, stateVarName, stateIds[idx])
    -- emit the original statement code
    local code = genCode(stmts[idx])
    for _, ln in ipairs(code) do
      lines[#lines+1] = "    " .. ln
    end
    -- transition to next state
    local nextState = (idx < #stmts) and stateIds[idx+1] or exitState
    lines[#lines+1] = string.format("    %s = %d", stateVarName, nextState)
  end
  lines[#lines+1] = "  end"  -- close if/elseif
  lines[#lines+1] = "end"    -- close while

  return lines
end

-- Mark function nodes for CFF (transform happens in codegen)
function CFF:transform(ast)
  self:walk(ast)
end

function CFF:walk(node)
  if not node or type(node) ~= "table" then return end

  -- Mark function bodies for CFF if they have enough statements
  if (node.kind == "Function" or node.kind == "LocalFunction" or node.kind == "FunctionStat") then
    local body = node.body or (node.func and node.func.body)
    if body and body.body and #body.body >= 2 then
      body._flattenCFF = true
      body._stateVar = "_s" .. tostring(self:randInt(1000,9999))
      body._exitState = self:randInt(10000, 99999)
      local ids = self:makeStateIds(#body.body + 1)
      body._stateIds = ids
      body._exitState = ids[#ids]
    end
  end

  for k, v in pairs(node) do
    if type(v) == "table" and k ~= "symbol" then
      self:walk(v)
    end
  end
end

return { CFF = CFF }
