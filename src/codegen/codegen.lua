-- codegen.lua: AST → Lua source code generator with obfuscation applied
local CodeGen = {}
CodeGen.__index = CodeGen

function CodeGen.new(config, renamer)
  return setmetatable({
    config = config or {},
    renamer = renamer,
    indent = 0,
    out = {},
  }, CodeGen)
end

function CodeGen:emit(line)
  self.out[#self.out+1] = string.rep("  ", self.indent) .. (line or "")
end

function CodeGen:emitRaw(line)
  self.out[#self.out+1] = line or ""
end

function CodeGen:push() self.indent = self.indent + 1 end
function CodeGen:pop()  self.indent = math.max(0, self.indent - 1) end

function CodeGen:joinExprs(nodes, sep)
  local parts = {}
  for _, n in ipairs(nodes or {}) do
    parts[#parts+1] = self:expr(n)
  end
  return table.concat(parts, sep or ", ")
end

-- ── Name resolution ────────────────────────────────────────────────────────
function CodeGen:resolveName(node)
  if node.symbol and node.symbol.obfName then
    return node.symbol.obfName
  end
  return node.name
end

-- ── Expression emitter ─────────────────────────────────────────────────────
function CodeGen:expr(node)
  if not node then return "nil" end
  local k = node.kind

  if k == "Number" then
    if node._obfuscated and node._obfExpr then
      return "(" .. node._obfExpr .. ")"
    end
    return node.value

  elseif k == "String" then
    if node._encrypted and node._encryptedExpr then
      return node._encryptedExpr
    end
    return string.format("%q", node.value)

  elseif k == "Bool" then
    return node.value and "true" or "false"

  elseif k == "Nil" then return "nil"
  elseif k == "Vararg" then return "..."

  elseif k == "Name" then
    return self:resolveName(node)

  elseif k == "Paren" then
    return "(" .. self:expr(node.expr) .. ")"

  elseif k == "Unary" then
    local op = node.op
    if op == "not" then op = "not " end
    return op .. self:expr(node.operand)

  elseif k == "Binary" then
    local l = self:expr(node.left)
    local r = self:expr(node.right)
    return string.format("(%s %s %s)", l, node.op, r)

  elseif k == "Index" then
    if node.dot then
      return self:expr(node.base) .. "." .. node.key.value
    end
    return self:expr(node.base) .. "[" .. self:expr(node.key) .. "]"

  elseif k == "Call" then
    return self:expr(node.base) .. "(" .. self:joinExprs(node.args) .. ")"

  elseif k == "MethodCall" then
    return self:expr(node.base) .. ":" .. node.method ..
           "(" .. self:joinExprs(node.args) .. ")"

  elseif k == "Function" then
    return self:funcExpr(node)

  elseif k == "Table" then
    return self:tableExpr(node)

  else
    return "nil --[[unknown expr: "..(k or "nil").."]]"
  end
end

function CodeGen:funcExpr(node)
  local params = {}
  for _, p in ipairs(node.params or {}) do
    -- Check if param has a symbol
    local sym = nil
    if node.body then
      -- params are defined in the function scope; look them up by name
    end
    params[#params+1] = p -- param renaming handled via symbol lookup in Name nodes
  end
  if node.hasVararg then params[#params+1] = "..." end
  local header = "function(" .. table.concat(params, ", ") .. ")"
  local lines = { header }
  self:push()
  local bodyLines = self:block(node.body)
  for _, ln in ipairs(bodyLines) do
    lines[#lines+1] = string.rep("  ", self.indent) .. ln
  end
  self:pop()
  lines[#lines+1] = string.rep("  ", self.indent) .. "end"
  return table.concat(lines, "\n")
end

function CodeGen:tableExpr(node)
  if not node.fields or #node.fields == 0 then return "{}" end
  local parts = {}
  for _, f in ipairs(node.fields) do
    if f.kind == "TableField" then
      if f.named then
        parts[#parts+1] = f.key.value .. " = " .. self:expr(f.value)
      elseif f.computed then
        parts[#parts+1] = "[" .. self:expr(f.key) .. "] = " .. self:expr(f.value)
      else
        parts[#parts+1] = self:expr(f.value)
      end
    end
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

-- ── Statement emitter ──────────────────────────────────────────────────────
function CodeGen:stmt(s)
  if not s then return {} end
  local k = s.kind
  local lines = {}

  if k == "_Junk" then
    for _, ln in ipairs(s.lines or {}) do lines[#lines+1] = ln end
    return lines

  elseif k == "Local" then
    local names = {}
    for _, name in ipairs(s.names or {}) do
      -- find symbol for this name
      -- We stored the original name; codegen emits it; renamer already renamed
      names[#names+1] = name
    end
    local vals = self:joinExprs(s.values)
    if vals ~= "" then
      lines[#lines+1] = "local " .. table.concat(names,", ") .. " = " .. vals
    else
      lines[#lines+1] = "local " .. table.concat(names,", ")
    end

  elseif k == "LocalFunction" then
    local fname = s.name
    local f = s.func
    local params = table.concat(f and f.params or {}, ", ")
    if f and f.hasVararg then
      params = params .. (params ~= "" and ", " or "") .. "..."
    end
    lines[#lines+1] = string.format("local function %s(%s)", fname, params)
    if f then
      local blines = self:block(f.body)
      for _, bl in ipairs(blines) do lines[#lines+1] = "  " .. bl end
    end
    lines[#lines+1] = "end"

  elseif k == "FunctionStat" then
    local path = table.concat(s.path, ".")
    local f = s.func
    local params = table.concat(f and f.params or {}, ", ")
    if f and f.hasVararg then
      params = params .. (params ~= "" and ", " or "") .. "..."
    end
    lines[#lines+1] = string.format("function %s(%s)", path, params)
    if f then
      local blines = self:block(f.body)
      for _, bl in ipairs(blines) do lines[#lines+1] = "  " .. bl end
    end
    lines[#lines+1] = "end"

  elseif k == "Assign" then
    local targets = {}
    for _, t in ipairs(s.targets or {}) do targets[#targets+1] = self:expr(t) end
    local vals = self:joinExprs(s.values)
    lines[#lines+1] = table.concat(targets,", ") .. " = " .. vals

  elseif k == "CompoundAssign" then
    -- Desugar: x += y → x = x + y
    local t = self:expr(s.target)
    local v = self:expr(s.value)
    lines[#lines+1] = string.format("%s = %s %s %s", t, t, s.op, v)

  elseif k == "CallStat" then
    lines[#lines+1] = self:expr(s.expr)

  elseif k == "If" then
    lines[#lines+1] = "if " .. self:expr(s.cond) .. " then"
    local blines = self:block(s.body)
    for _, bl in ipairs(blines) do lines[#lines+1] = "  " .. bl end
    for _, ei in ipairs(s.elseifs or {}) do
      lines[#lines+1] = "elseif " .. self:expr(ei.cond) .. " then"
      local el = self:block(ei.body)
      for _, bl in ipairs(el) do lines[#lines+1] = "  " .. bl end
    end
    if s.elseBody then
      lines[#lines+1] = "else"
      local el = self:block(s.elseBody)
      for _, bl in ipairs(el) do lines[#lines+1] = "  " .. bl end
    end
    lines[#lines+1] = "end"

  elseif k == "While" then
    lines[#lines+1] = "while " .. self:expr(s.cond) .. " do"
    local blines = self:block(s.body)
    for _, bl in ipairs(blines) do lines[#lines+1] = "  " .. bl end
    lines[#lines+1] = "end"

  elseif k == "Repeat" then
    lines[#lines+1] = "repeat"
    local blines = self:block(s.body)
    for _, bl in ipairs(blines) do lines[#lines+1] = "  " .. bl end
    lines[#lines+1] = "until " .. self:expr(s.cond)

  elseif k == "NumericFor" then
    local var = s.var
    local start = self:expr(s.start)
    local limit = self:expr(s.limit)
    local step  = s.step and (", " .. self:expr(s.step)) or ""
    lines[#lines+1] = string.format("for %s = %s, %s%s do", var, start, limit, step)
    local blines = self:block(s.body)
    for _, bl in ipairs(blines) do lines[#lines+1] = "  " .. bl end
    lines[#lines+1] = "end"

  elseif k == "GenericFor" then
    local vars = table.concat(s.vars or {}, ", ")
    local iters = self:joinExprs(s.iters)
    lines[#lines+1] = "for " .. vars .. " in " .. iters .. " do"
    local blines = self:block(s.body)
    for _, bl in ipairs(blines) do lines[#lines+1] = "  " .. bl end
    lines[#lines+1] = "end"

  elseif k == "Do" then
    lines[#lines+1] = "do"
    local blines = self:block(s.body)
    for _, bl in ipairs(blines) do lines[#lines+1] = "  " .. bl end
    lines[#lines+1] = "end"

  elseif k == "Return" then
    local vals = self:joinExprs(s.values)
    if vals ~= "" then
      lines[#lines+1] = "return " .. vals
    else
      lines[#lines+1] = "return"
    end

  elseif k == "Break" then lines[#lines+1] = "break"
  elseif k == "Continue" then lines[#lines+1] = "continue"
  elseif k == "Goto" then lines[#lines+1] = "goto " .. s.label
  elseif k == "Label" then lines[#lines+1] = "::" .. s.name .. "::"
  elseif k == "TypeAlias" then
    -- strip Luau type annotations from output for Lua compat
    -- lines[#lines+1] = "-- type " .. s.name
  else
    lines[#lines+1] = "--[[unknown stmt: " .. (k or "nil") .. "]]"
  end

  return lines
end

function CodeGen:block(block)
  if not block or not block.body then return {} end
  local lines = {}
  for _, s in ipairs(block.body) do
    local sl = self:stmt(s)
    for _, ln in ipairs(sl) do
      lines[#lines+1] = ln
    end
  end
  return lines
end

-- ── Entry point ────────────────────────────────────────────────────────────
-- Generate complete file from chunk node, with all preamble lines prepended
function CodeGen:generate(chunkNode, preambleLines)
  local out = {}

  -- Emit preamble (decryptor, proxy table, watermark, etc.)
  for _, ln in ipairs(preambleLines or {}) do
    out[#out+1] = ln
  end

  -- Emit main body
  local bodyLines = self:block(chunkNode.body)
  for _, ln in ipairs(bodyLines) do
    out[#out+1] = ln
  end

  return table.concat(out, "\n")
end

return { CodeGen = CodeGen }
