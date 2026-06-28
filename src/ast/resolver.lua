-- resolver.lua: Scope analysis and symbol table building
local Resolver = {}
Resolver.__index = Resolver

function Resolver.new()
  return setmetatable({
    scopes = {},
    symbols = {}, -- flat list of all symbols
    currentScope = nil,
  }, Resolver)
end

function Resolver:pushScope(kind)
  local scope = {
    kind = kind or "block",
    vars = {},
    parent = self.currentScope,
    id = #self.scopes + 1,
  }
  self.scopes[#self.scopes+1] = scope
  self.currentScope = scope
  return scope
end

function Resolver:popScope()
  self.currentScope = self.currentScope and self.currentScope.parent
end

function Resolver:define(name, kind, node)
  if not self.currentScope then return end
  local sym = {
    name = name,
    kind = kind or "local", -- local, param, upvalue, global
    scope = self.currentScope,
    node = node,
    refs = {},
    obfName = nil, -- filled by renamer
    id = #self.symbols + 1,
  }
  self.currentScope.vars[name] = sym
  self.symbols[#self.symbols+1] = sym
  return sym
end

function Resolver:lookup(name)
  local scope = self.currentScope
  while scope do
    if scope.vars[name] then return scope.vars[name] end
    scope = scope.parent
  end
  return nil
end

function Resolver:resolve(ast)
  self:pushScope("global")
  -- pre-define common globals
  for _, g in ipairs({
    "print","tostring","tonumber","type","pairs","ipairs","next",
    "select","unpack","table","string","math","io","os","coroutine",
    "pcall","xpcall","error","assert","rawget","rawset","rawequal","rawlen",
    "setmetatable","getmetatable","require","load","loadfile","dofile",
    "collectgarbage","gcinfo","newproxy","warn","_VERSION","_G","_ENV",
    "bit32","utf8","task","game","script","workspace","Vector3","CFrame",
  }) do
    self:define(g, "global", nil)
  end
  self:resolveBlock(ast.body)
  self:popScope()
end

function Resolver:resolveBlock(block)
  if not block or not block.body then return end
  for _, stmt in ipairs(block.body) do
    self:resolveStmt(stmt)
  end
end

function Resolver:resolveStmt(s)
  if not s then return end
  local k = s.kind
  if k == "Local" then
    -- resolve RHS first (before names come into scope)
    for _, v in ipairs(s.values or {}) do self:resolveExpr(v) end
    for _, name in ipairs(s.names or {}) do
      self:define(name, "local", s)
    end
  elseif k == "LocalFunction" then
    self:define(s.name, "local", s)
    self:pushScope("function")
    self:define("self", "param", s) -- might be unused but safe
    local f = s.func
    if f then
      for _, p in ipairs(f.params or {}) do self:define(p, "param", s) end
      self:resolveBlock(f.body)
    end
    self:popScope()
  elseif k == "FunctionStat" then
    self:pushScope("function")
    local f = s.func
    if f then
      for _, p in ipairs(f.params or {}) do self:define(p, "param", s) end
      self:resolveBlock(f.body)
    end
    self:popScope()
  elseif k == "Assign" then
    for _, t in ipairs(s.targets or {}) do self:resolveExpr(t) end
    for _, v in ipairs(s.values or {}) do self:resolveExpr(v) end
  elseif k == "CompoundAssign" then
    self:resolveExpr(s.target)
    self:resolveExpr(s.value)
  elseif k == "CallStat" then
    self:resolveExpr(s.expr)
  elseif k == "If" then
    self:resolveExpr(s.cond)
    self:pushScope("block"); self:resolveBlock(s.body); self:popScope()
    for _, ei in ipairs(s.elseifs or {}) do
      self:resolveExpr(ei.cond)
      self:pushScope("block"); self:resolveBlock(ei.body); self:popScope()
    end
    if s.elseBody then
      self:pushScope("block"); self:resolveBlock(s.elseBody); self:popScope()
    end
  elseif k == "While" then
    self:resolveExpr(s.cond)
    self:pushScope("block"); self:resolveBlock(s.body); self:popScope()
  elseif k == "Repeat" then
    self:pushScope("block"); self:resolveBlock(s.body)
    self:resolveExpr(s.cond); self:popScope()
  elseif k == "NumericFor" then
    self:resolveExpr(s.start); self:resolveExpr(s.limit)
    if s.step then self:resolveExpr(s.step) end
    self:pushScope("block")
    self:define(s.var, "local", s)
    self:resolveBlock(s.body)
    self:popScope()
  elseif k == "GenericFor" then
    for _, it in ipairs(s.iters or {}) do self:resolveExpr(it) end
    self:pushScope("block")
    for _, v in ipairs(s.vars or {}) do self:define(v, "local", s) end
    self:resolveBlock(s.body)
    self:popScope()
  elseif k == "Do" then
    self:pushScope("block"); self:resolveBlock(s.body); self:popScope()
  elseif k == "Return" then
    for _, v in ipairs(s.values or {}) do self:resolveExpr(v) end
  end
  -- Break, Continue, Goto, Label, TypeAlias: no sub-expressions to resolve
end

function Resolver:resolveExpr(e)
  if not e then return end
  local k = e.kind
  if k == "Name" then
    local sym = self:lookup(e.name)
    if sym then
      sym.refs[#sym.refs+1] = e
      e.symbol = sym
    else
      -- implicit global
      local gsym = self:define(e.name, "global", e)
      e.symbol = gsym
    end
  elseif k == "Index" then
    self:resolveExpr(e.base); self:resolveExpr(e.key)
  elseif k == "Call" then
    self:resolveExpr(e.base)
    for _, a in ipairs(e.args or {}) do self:resolveExpr(a) end
  elseif k == "MethodCall" then
    self:resolveExpr(e.base)
    for _, a in ipairs(e.args or {}) do self:resolveExpr(a) end
  elseif k == "Binary" then
    self:resolveExpr(e.left); self:resolveExpr(e.right)
  elseif k == "Unary" then
    self:resolveExpr(e.operand)
  elseif k == "Paren" then
    self:resolveExpr(e.expr)
  elseif k == "Function" then
    self:pushScope("function")
    for _, p in ipairs(e.params or {}) do self:define(p, "param", e) end
    self:resolveBlock(e.body)
    self:popScope()
  elseif k == "Table" then
    for _, f in ipairs(e.fields or {}) do
      if f.key then self:resolveExpr(f.key) end
      self:resolveExpr(f.value)
    end
  end
  -- Number, String, Bool, Nil, Vararg: leaf nodes
end

return { Resolver = Resolver }
