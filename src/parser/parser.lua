-- parser.lua: Recursive-descent Lua/Luau parser → AST
local lexerMod = require("src.lexer.lexer")
local TT = lexerMod.TokenType

local Parser = {}
Parser.__index = Parser

local function node(kind, data)
  data = data or {}
  data.kind = kind
  return data
end

function Parser.new(tokens)
  return setmetatable({ tokens = tokens, pos = 1, errors = {} }, Parser)
end

function Parser:peek(offset)
  local i = self.pos + (offset or 0)
  return self.tokens[i] or { type = TT.EOF, value = "" }
end

function Parser:advance()
  local t = self.tokens[self.pos]
  if self.pos <= #self.tokens then self.pos = self.pos + 1 end
  return t
end

function Parser:check(tt)
  return self:peek().type == tt
end

function Parser:match(...)
  for _, tt in ipairs({...}) do
    if self:check(tt) then return self:advance() end
  end
  return nil
end

function Parser:expect(tt, msg)
  if self:check(tt) then return self:advance() end
  local tok = self:peek()
  table.insert(self.errors, (msg or ("Expected "..tt.." got "..tok.type)).." at line "..tok.line)
  return { type = tt, value = "", line = tok.line }
end

function Parser:expectName(msg)
  return self:expect(TT.NAME, msg or "Expected name")
end

-- ── Block ──────────────────────────────────────────────────────────────────
function Parser:parseBlock()
  local stmts = {}
  while true do
    local t = self:peek().type
    if t == TT.EOF or t == TT.END or t == TT.ELSE
      or t == TT.ELSEIF or t == TT.UNTIL then break end
    local s = self:parseStatement()
    if s then stmts[#stmts+1] = s end
    self:match(TT.SEMI)
  end
  return node("Block", { body = stmts })
end

function Parser:parseStatement()
  local t = self:peek()
  if t.type == TT.IF then return self:parseIf()
  elseif t.type == TT.WHILE then return self:parseWhile()
  elseif t.type == TT.DO then return self:parseDo()
  elseif t.type == TT.FOR then return self:parseFor()
  elseif t.type == TT.REPEAT then return self:parseRepeat()
  elseif t.type == TT.FUNCTION then return self:parseFunctionStat()
  elseif t.type == TT.LOCAL then return self:parseLocal()
  elseif t.type == TT.RETURN then return self:parseReturn()
  elseif t.type == TT.BREAK then self:advance(); return node("Break", {line=t.line})
  elseif t.type == TT.CONTINUE then self:advance(); return node("Continue", {line=t.line})
  elseif t.type == TT.GOTO then
    self:advance()
    local name = self:expectName()
    return node("Goto", { label = name.value, line = t.line })
  elseif t.type == TT.DCOLON then
    self:advance()
    local name = self:expectName()
    self:expect(TT.DCOLON)
    return node("Label", { name = name.value, line = t.line })
  elseif t.type == TT.TYPE and self:peek(1).type == TT.NAME then
    return self:parseTypeAlias()
  else
    return self:parseExprStat()
  end
end

function Parser:parseIf()
  local line = self:peek().line
  self:expect(TT.IF)
  local cond = self:parseExpr()
  self:expect(TT.THEN)
  local body = self:parseBlock()
  local elseifs, elseBody = {}, nil
  while self:check(TT.ELSEIF) do
    self:advance()
    local ec = self:parseExpr()
    self:expect(TT.THEN)
    local eb = self:parseBlock()
    elseifs[#elseifs+1] = { cond = ec, body = eb }
  end
  if self:match(TT.ELSE) then elseBody = self:parseBlock() end
  self:expect(TT.END)
  return node("If", { cond=cond, body=body, elseifs=elseifs, elseBody=elseBody, line=line })
end

function Parser:parseWhile()
  local line = self:peek().line
  self:expect(TT.WHILE)
  local cond = self:parseExpr()
  self:expect(TT.DO)
  local body = self:parseBlock()
  self:expect(TT.END)
  return node("While", { cond=cond, body=body, line=line })
end

function Parser:parseDo()
  local line = self:peek().line
  self:expect(TT.DO)
  local body = self:parseBlock()
  self:expect(TT.END)
  return node("Do", { body=body, line=line })
end

function Parser:parseFor()
  local line = self:peek().line
  self:expect(TT.FOR)
  local first = self:expectName()
  if self:match(TT.ASSIGN) then
    -- numeric for
    local start = self:parseExpr()
    self:expect(TT.COMMA)
    local limit = self:parseExpr()
    local step = nil
    if self:match(TT.COMMA) then step = self:parseExpr() end
    self:expect(TT.DO)
    local body = self:parseBlock()
    self:expect(TT.END)
    return node("NumericFor", { var=first.value, start=start, limit=limit, step=step, body=body, line=line })
  else
    -- generic for
    local vars = { first.value }
    while self:match(TT.COMMA) do vars[#vars+1] = self:expectName().value end
    self:expect(TT.IN)
    local iters = self:parseExprList()
    self:expect(TT.DO)
    local body = self:parseBlock()
    self:expect(TT.END)
    return node("GenericFor", { vars=vars, iters=iters, body=body, line=line })
  end
end

function Parser:parseRepeat()
  local line = self:peek().line
  self:expect(TT.REPEAT)
  local body = self:parseBlock()
  self:expect(TT.UNTIL)
  local cond = self:parseExpr()
  return node("Repeat", { body=body, cond=cond, line=line })
end

function Parser:parseFunctionStat()
  local line = self:peek().line
  self:expect(TT.FUNCTION)
  local name = self:expectName().value
  local path = { name }
  local isMethod = false
  while self:match(TT.DOT) do path[#path+1] = self:expectName().value end
  if self:match(TT.COLON) then
    path[#path+1] = self:expectName().value
    isMethod = true
  end
  local func = self:parseFuncBody(isMethod, line)
  return node("FunctionStat", { path=path, func=func, line=line })
end

function Parser:parseLocal()
  local line = self:peek().line
  self:expect(TT.LOCAL)
  if self:check(TT.FUNCTION) then
    self:advance()
    local name = self:expectName().value
    local func = self:parseFuncBody(false, line)
    return node("LocalFunction", { name=name, func=func, line=line })
  end
  local names, attribs = {}, {}
  names[1] = self:expectName().value
  attribs[1] = self:parseAttrib()
  while self:match(TT.COMMA) do
    names[#names+1] = self:expectName().value
    attribs[#attribs+1] = self:parseAttrib()
  end
  local values = {}
  if self:match(TT.ASSIGN) then values = self:parseExprList() end
  return node("Local", { names=names, attribs=attribs, values=values, line=line })
end

function Parser:parseAttrib()
  if self:match(TT.LT) then
    local a = self:expectName().value
    self:expect(TT.GT)
    return a
  end
  return nil
end

function Parser:parseReturn()
  local line = self:peek().line
  self:expect(TT.RETURN)
  local vals = {}
  local t = self:peek().type
  if t ~= TT.END and t ~= TT.ELSE and t ~= TT.ELSEIF
    and t ~= TT.UNTIL and t ~= TT.EOF and t ~= TT.SEMI then
    vals = self:parseExprList()
  end
  self:match(TT.SEMI)
  return node("Return", { values=vals, line=line })
end

function Parser:parseTypeAlias()
  local line = self:peek().line
  self:advance() -- type
  local name = self:expectName().value
  self:expect(TT.ASSIGN)
  -- skip the type expression (consume until end of line loosely)
  local typeStr = {}
  while not self:check(TT.SEMI) and not self:check(TT.EOF)
    and self:peek().line == line do
    typeStr[#typeStr+1] = self:advance().value
  end
  self:match(TT.SEMI)
  return node("TypeAlias", { name=name, typeStr=table.concat(typeStr," "), line=line })
end

function Parser:parseExprStat()
  local line = self:peek().line
  local exprs = { self:parseSuffixedExpr() }
  -- compound assignment (Luau)
  local compound = {
    [TT.PLUS_ASSIGN]="+", [TT.MINUS_ASSIGN]="-", [TT.STAR_ASSIGN]="*",
    [TT.SLASH_ASSIGN]="/", [TT.PERCENT_ASSIGN]="%", [TT.CARET_ASSIGN]="^",
    [TT.DSLASH_ASSIGN]="//", [TT.DOTDOT_ASSIGN]="..="
  }
  local ct = self:peek().type
  if compound[ct] then
    local op = compound[ct]
    self:advance()
    local val = self:parseExpr()
    return node("CompoundAssign", { target=exprs[1], op=op, value=val, line=line })
  end
  -- multiple assignment
  while self:match(TT.COMMA) do exprs[#exprs+1] = self:parseSuffixedExpr() end
  if self:match(TT.ASSIGN) then
    local vals = self:parseExprList()
    return node("Assign", { targets=exprs, values=vals, line=line })
  end
  -- call statement
  if exprs[1] and (exprs[1].kind == "Call" or exprs[1].kind == "MethodCall") then
    return node("CallStat", { expr=exprs[1], line=line })
  end
  table.insert(self.errors, "Unexpected expression statement at line "..line)
  return nil
end

-- ── Expressions ────────────────────────────────────────────────────────────
function Parser:parseExprList()
  local list = { self:parseExpr() }
  while self:match(TT.COMMA) do list[#list+1] = self:parseExpr() end
  return list
end

local UNARY_OPS = { [TT.MINUS]="-", [TT.NOT]="not", [TT.HASH]="#", [TT.TILDE]="~" }
local BINARY_PRIO = {
  ["or"]={1,1}, ["and"]={2,2},
  ["<"]={3,3}, [">"]={3,3}, ["<="]={3,3}, [">="]={3,3}, ["=="]={3,3}, ["~="]={3,3},
  ["|"]={4,4}, ["~"]={5,5}, ["&"]={6,6},
  ["<<"]={7,7}, [">>"]={7,7},
  [".."]={8,9}, -- right assoc
  ["+"]={10,10}, ["-"]={10,10},
  ["*"]={11,11}, ["/"]={11,11}, ["//"]={11,11}, ["%"]={11,11},
  ["^"]={13,12}, -- right assoc
}
local BIN_OPS = {
  [TT.OR]="or", [TT.AND]="and",
  [TT.LT]="<", [TT.GT]=">", [TT.LEQ]="<=", [TT.GEQ]=">=",
  [TT.EQ]="==", [TT.NEQ]="~=",
  [TT.PIPE]="|", [TT.TILDE]="~", [TT.AMPERSAND]="&",
  [TT.LSHIFT]="<<", [TT.RSHIFT]=">>",
  [TT.DOTDOT]="..",
  [TT.PLUS]="+", [TT.MINUS]="-",
  [TT.STAR]="*", [TT.SLASH]="/", [TT.DSLASH]="//", [TT.PERCENT]="%",
  [TT.CARET]="^",
}

function Parser:parseExpr(minPrio)
  minPrio = minPrio or 0
  local line = self:peek().line
  local lhs

  local unOp = UNARY_OPS[self:peek().type]
  if unOp then
    self:advance()
    local operand = self:parseExpr(12) -- unary prio
    lhs = node("Unary", { op=unOp, operand=operand, line=line })
  else
    lhs = self:parseSimpleExpr()
  end

  while true do
    local tt = self:peek().type
    local op = BIN_OPS[tt]
    if not op then break end
    local prio = BINARY_PRIO[op]
    if not prio or prio[1] <= minPrio then break end
    self:advance()
    local rhs = self:parseExpr(prio[2])
    lhs = node("Binary", { op=op, left=lhs, right=rhs, line=line })
  end

  return lhs
end

function Parser:parseSimpleExpr()
  local t = self:peek()
  if t.type == TT.NUMBER then
    self:advance()
    return node("Number", { value=t.value, line=t.line })
  elseif t.type == TT.STRING then
    self:advance()
    return node("String", { value=t.value, line=t.line })
  elseif t.type == TT.TRUE then self:advance(); return node("Bool",{value=true,line=t.line})
  elseif t.type == TT.FALSE then self:advance(); return node("Bool",{value=false,line=t.line})
  elseif t.type == TT.NIL then self:advance(); return node("Nil",{line=t.line})
  elseif t.type == TT.DOTDOTDOT then self:advance(); return node("Vararg",{line=t.line})
  elseif t.type == TT.FUNCTION then
    self:advance()
    return self:parseFuncBody(false, t.line)
  elseif t.type == TT.LBRACE then
    return self:parseTableConstructor()
  else
    return self:parseSuffixedExpr()
  end
end

function Parser:parseSuffixedExpr()
  local line = self:peek().line
  local base = self:parsePrimaryExpr()
  while true do
    local t = self:peek()
    if t.type == TT.DOT then
      self:advance()
      local field = self:expectName()
      base = node("Index", { base=base, key=node("String",{value=field.value}), dot=true, line=t.line })
    elseif t.type == TT.LBRACKET then
      self:advance()
      local key = self:parseExpr()
      self:expect(TT.RBRACKET)
      base = node("Index", { base=base, key=key, line=t.line })
    elseif t.type == TT.COLON then
      self:advance()
      local method = self:expectName()
      local args = self:parseCallArgs()
      base = node("MethodCall", { base=base, method=method.value, args=args, line=t.line })
    elseif t.type == TT.LPAREN or t.type == TT.LBRACE or t.type == TT.STRING then
      local args = self:parseCallArgs()
      base = node("Call", { base=base, args=args, line=t.line })
    else break end
  end
  return base
end

function Parser:parsePrimaryExpr()
  local t = self:peek()
  if t.type == TT.NAME then
    self:advance()
    return node("Name", { name=t.value, line=t.line })
  elseif t.type == TT.LPAREN then
    self:advance()
    local e = self:parseExpr()
    self:expect(TT.RPAREN)
    return node("Paren", { expr=e, line=t.line })
  else
    table.insert(self.errors, "Unexpected token "..t.type.." '"..t.value.."' at line "..t.line)
    self:advance()
    return node("Name", { name="_err_", line=t.line })
  end
end

function Parser:parseCallArgs()
  local t = self:peek()
  if t.type == TT.LPAREN then
    self:advance()
    local args = {}
    if not self:check(TT.RPAREN) then args = self:parseExprList() end
    self:expect(TT.RPAREN)
    return args
  elseif t.type == TT.LBRACE then
    return { self:parseTableConstructor() }
  elseif t.type == TT.STRING then
    self:advance()
    return { node("String", { value=t.value, line=t.line }) }
  else
    table.insert(self.errors, "Expected function arguments at line "..t.line)
    return {}
  end
end

function Parser:parseFuncBody(isMethod, line)
  self:expect(TT.LPAREN)
  local params = {}
  local hasVararg = false
  if isMethod then params[1] = "self" end
  if not self:check(TT.RPAREN) then
    if self:check(TT.DOTDOTDOT) then
      self:advance(); hasVararg = true
    else
      params[#params+1] = self:expectName().value
      while self:match(TT.COMMA) do
        if self:check(TT.DOTDOTDOT) then
          self:advance(); hasVararg = true; break
        end
        params[#params+1] = self:expectName().value
      end
    end
  end
  self:expect(TT.RPAREN)
  -- optional Luau return type annotation
  if self:match(TT.COLON) then
    -- consume return type
    local depth = 0
    while true do
      local tt = self:peek().type
      if tt == TT.LPAREN or tt == TT.LBRACE then depth=depth+1
      elseif tt == TT.RPAREN or tt == TT.RBRACE then
        if depth == 0 then break end
        depth = depth - 1
      elseif tt == TT.DO or tt == TT.EOF then break end
      self:advance()
    end
  end
  local body = self:parseBlock()
  self:expect(TT.END)
  return node("Function", { params=params, hasVararg=hasVararg, body=body, line=line })
end

function Parser:parseTableConstructor()
  local line = self:peek().line
  self:expect(TT.LBRACE)
  local fields = {}
  while not self:check(TT.RBRACE) and not self:check(TT.EOF) do
    if self:check(TT.LBRACKET) then
      self:advance()
      local key = self:parseExpr()
      self:expect(TT.RBRACKET)
      self:expect(TT.ASSIGN)
      local val = self:parseExpr()
      fields[#fields+1] = node("TableField", { key=key, value=val, computed=true })
    elseif self:check(TT.NAME) and self:peek(1).type == TT.ASSIGN then
      local k = self:advance().value
      self:advance() -- =
      local val = self:parseExpr()
      fields[#fields+1] = node("TableField", { key=node("String",{value=k}), value=val, named=true })
    else
      local val = self:parseExpr()
      fields[#fields+1] = node("TableField", { value=val })
    end
    if not self:match(TT.COMMA) then self:match(TT.SEMI) end
    if self:check(TT.RBRACE) then break end
  end
  self:expect(TT.RBRACE)
  return node("Table", { fields=fields, line=line })
end

function Parser:parse()
  local block = self:parseBlock()
  self:expect(TT.EOF)
  return node("Chunk", { body=block, errors=self.errors })
end

return { Parser = Parser }
