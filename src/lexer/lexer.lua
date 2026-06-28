-- lexer.lua: Full Lua/Luau Lexer
local Lexer = {}
Lexer.__index = Lexer

local TokenType = {
  -- Literals
  NUMBER = "NUMBER", STRING = "STRING", NAME = "NAME",
  -- Keywords
  AND="AND", BREAK="BREAK", DO="DO", ELSE="ELSE", ELSEIF="ELSEIF",
  END="END", FALSE="FALSE", FOR="FOR", FUNCTION="FUNCTION", IF="IF",
  IN="IN", LOCAL="LOCAL", NIL="NIL", NOT="NOT", OR="OR",
  REPEAT="REPEAT", RETURN="RETURN", THEN="THEN", TRUE="TRUE",
  UNTIL="UNTIL", WHILE="WHILE",
  -- Luau
  CONTINUE="CONTINUE", TYPE="TYPE", EXPORT="EXPORT",
  -- Symbols
  PLUS="+", MINUS="-", STAR="*", SLASH="/", PERCENT="%",
  CARET="^", HASH="#", AMPERSAND="&", TILDE="~", PIPE="|",
  LSHIFT="<<", RSHIFT=">>", DSLASH="//", EQ="==", NEQ="~=",
  LT="<", GT=">", LEQ="<=", GEQ=">=", ASSIGN="=",
  LPAREN="(", RPAREN=")", LBRACE="{", RBRACE="}",
  LBRACKET="[", RBRACKET="]", DCOLON="::", SEMI=";",
  COLON=":", COMMA=",", DOT=".", DOTDOT="..", DOTDOTDOT="...",
  -- Luau compound
  PLUS_ASSIGN="+=", MINUS_ASSIGN="-=", STAR_ASSIGN="*=",
  SLASH_ASSIGN="/=", PERCENT_ASSIGN="%=", CARET_ASSIGN="^=",
  DSLASH_ASSIGN="//=", DOTDOT_ASSIGN="..=",
  -- Special
  EOF="EOF", COMMENT="COMMENT",
}

local KEYWORDS = {
  ["and"]=TokenType.AND, ["break"]=TokenType.BREAK, ["do"]=TokenType.DO,
  ["else"]=TokenType.ELSE, ["elseif"]=TokenType.ELSEIF, ["end"]=TokenType.END,
  ["false"]=TokenType.FALSE, ["for"]=TokenType.FOR, ["function"]=TokenType.FUNCTION,
  ["if"]=TokenType.IF, ["in"]=TokenType.IN, ["local"]=TokenType.LOCAL,
  ["nil"]=TokenType.NIL, ["not"]=TokenType.NOT, ["or"]=TokenType.OR,
  ["repeat"]=TokenType.REPEAT, ["return"]=TokenType.RETURN, ["then"]=TokenType.THEN,
  ["true"]=TokenType.TRUE, ["until"]=TokenType.UNTIL, ["while"]=TokenType.WHILE,
  ["continue"]=TokenType.CONTINUE, ["type"]=TokenType.TYPE, ["export"]=TokenType.EXPORT,
}

function Lexer.new(source)
  return setmetatable({
    src = source, pos = 1, line = 1, col = 1,
    tokens = {}, errors = {}
  }, Lexer)
end

function Lexer:peek(offset)
  return self.src:sub(self.pos + (offset or 0), self.pos + (offset or 0))
end

function Lexer:advance()
  local c = self.src:sub(self.pos, self.pos)
  self.pos = self.pos + 1
  if c == "\n" then self.line = self.line + 1; self.col = 1
  else self.col = self.col + 1 end
  return c
end

function Lexer:match(c)
  if self.src:sub(self.pos, self.pos) == c then
    self:advance(); return true
  end
  return false
end

function Lexer:skipWhitespace()
  while self.pos <= #self.src do
    local c = self:peek()
    if c == " " or c == "\t" or c == "\r" or c == "\n" then
      self:advance()
    elseif c == "-" and self:peek(1) == "-" then
      self:skipComment()
    else break end
  end
end

function Lexer:skipComment()
  self:advance(); self:advance() -- skip --
  if self:peek() == "[" then
    local level = self:checkLongBracket()
    if level >= 0 then
      self:readLongString(level); return
    end
  end
  while self.pos <= #self.src and self:peek() ~= "\n" do
    self:advance()
  end
end

function Lexer:checkLongBracket()
  local save = self.pos
  if self:peek() ~= "[" then return -1 end
  local level = 0
  local i = self.pos + 1
  while i <= #self.src and self.src:sub(i,i) == "=" do
    level = level + 1; i = i + 1
  end
  if self.src:sub(i,i) == "[" then return level end
  return -1
end

function Lexer:readLongString(level)
  self:advance() -- [
  for _=1,level do self:advance() end -- =...
  self:advance() -- [
  if self:peek() == "\n" then self:advance() end
  local result = {}
  local closing = "]" .. ("="):rep(level) .. "]"
  while self.pos <= #self.src do
    local seg = self.src:sub(self.pos, self.pos + #closing - 1)
    if seg == closing then
      for _=1,#closing do self:advance() end
      return table.concat(result)
    end
    result[#result+1] = self:advance()
  end
  table.insert(self.errors, "Unfinished long string")
  return table.concat(result)
end

function Lexer:readString(delim)
  self:advance() -- opening quote
  local result = {}
  while self.pos <= #self.src do
    local c = self:peek()
    if c == delim then self:advance(); break
    elseif c == "\\" then
      self:advance()
      local e = self:advance()
      local esc = {n="\n",t="\t",r="\r",["\\"]="\\",["'"]="'", ['"']='"',
                   a="\a",b="\b",f="\f",v="\v",["0"]="\0"}
      if esc[e] then result[#result+1] = esc[e]
      elseif e == "x" then
        local h = self:advance()..self:advance()
        result[#result+1] = string.char(tonumber(h,16) or 0)
      elseif e == "u" then
        self:advance() -- {
        local hex = {}
        while self:peek() ~= "}" do hex[#hex+1]=self:advance() end
        self:advance()
        result[#result+1] = utf8 and utf8.char(tonumber(table.concat(hex),16)) or "?"
      elseif e:match("%d") then
        local n = e
        if self:peek():match("%d") then n=n..self:advance() end
        if self:peek():match("%d") then n=n..self:advance() end
        result[#result+1] = string.char(tonumber(n))
      else result[#result+1] = e end
    elseif c == "\n" then
      table.insert(self.errors, "Unfinished string at line "..self.line)
      break
    else result[#result+1] = self:advance() end
  end
  return table.concat(result)
end

function Lexer:readNumber()
  local start = self.pos
  if self:peek() == "0" and (self:peek(1) == "x" or self:peek(1) == "X") then
    self:advance(); self:advance()
    while self:peek():match("[%x_]") do self:advance() end
    if self:peek() == "." then
      self:advance()
      while self:peek():match("[%x_]") do self:advance() end
    end
    if self:peek():match("[pP]") then
      self:advance()
      if self:peek():match("[+-]") then self:advance() end
      while self:peek():match("%d") do self:advance() end
    end
  elseif self:peek() == "0" and (self:peek(1) == "b" or self:peek(1) == "B") then
    self:advance(); self:advance()
    while self:peek():match("[01_]") do self:advance() end
  else
    while self:peek():match("[%d_]") do self:advance() end
    if self:peek() == "." and self:peek(1):match("%d") then
      self:advance()
      while self:peek():match("[%d_]") do self:advance() end
    end
    if self:peek():match("[eE]") then
      self:advance()
      if self:peek():match("[+-]") then self:advance() end
      while self:peek():match("%d") do self:advance() end
    end
  end
  return self.src:sub(start, self.pos-1):gsub("_","")
end

function Lexer:tokenize()
  while true do
    self:skipWhitespace()
    if self.pos > #self.src then
      table.insert(self.tokens, {type=TokenType.EOF, value="", line=self.line})
      break
    end
    local line = self.line
    local c = self:peek()
    -- Numbers
    if c:match("%d") or (c == "." and self:peek(1):match("%d")) then
      local n = self:readNumber()
      table.insert(self.tokens, {type=TokenType.NUMBER, value=n, line=line})
    -- Strings
    elseif c == '"' or c == "'" then
      local s = self:readString(c)
      table.insert(self.tokens, {type=TokenType.STRING, value=s, line=line})
    -- Long strings
    elseif c == "[" then
      local level = self:checkLongBracket()
      if level >= 0 then
        local s = self:readLongString(level)
        table.insert(self.tokens, {type=TokenType.STRING, value=s, line=line})
      else
        self:advance()
        table.insert(self.tokens, {type=TokenType.LBRACKET, value="[", line=line})
      end
    -- Identifiers / keywords
    elseif c:match("[%a_]") then
      local start = self.pos
      while self:peek():match("[%w_]") do self:advance() end
      local word = self.src:sub(start, self.pos-1)
      local kw = KEYWORDS[word]
      table.insert(self.tokens, {type=kw or TokenType.NAME, value=word, line=line})
    -- Symbols
    elseif c == "+" then
      self:advance()
      if self:match("=") then table.insert(self.tokens,{type=TokenType.PLUS_ASSIGN,value="+=",line=line})
      else table.insert(self.tokens,{type=TokenType.PLUS,value="+",line=line}) end
    elseif c == "-" then
      self:advance()
      if self:match("=") then table.insert(self.tokens,{type=TokenType.MINUS_ASSIGN,value="-=",line=line})
      else table.insert(self.tokens,{type=TokenType.MINUS,value="-",line=line}) end
    elseif c == "*" then
      self:advance()
      if self:match("=") then table.insert(self.tokens,{type=TokenType.STAR_ASSIGN,value="*=",line=line})
      else table.insert(self.tokens,{type=TokenType.STAR,value="*",line=line}) end
    elseif c == "/" then
      self:advance()
      if self:match("/") then
        if self:match("=") then table.insert(self.tokens,{type=TokenType.DSLASH_ASSIGN,value="//=",line=line})
        else table.insert(self.tokens,{type=TokenType.DSLASH,value="//",line=line}) end
      elseif self:match("=") then table.insert(self.tokens,{type=TokenType.SLASH_ASSIGN,value="/=",line=line})
      else table.insert(self.tokens,{type=TokenType.SLASH,value="/",line=line}) end
    elseif c == "%" then
      self:advance()
      if self:match("=") then table.insert(self.tokens,{type=TokenType.PERCENT_ASSIGN,value="%=",line=line})
      else table.insert(self.tokens,{type=TokenType.PERCENT,value="%",line=line}) end
    elseif c == "^" then
      self:advance()
      if self:match("=") then table.insert(self.tokens,{type=TokenType.CARET_ASSIGN,value="^=",line=line})
      else table.insert(self.tokens,{type=TokenType.CARET,value="^",line=line}) end
    elseif c == "#" then self:advance(); table.insert(self.tokens,{type=TokenType.HASH,value="#",line=line})
    elseif c == "&" then self:advance(); table.insert(self.tokens,{type=TokenType.AMPERSAND,value="&",line=line})
    elseif c == "|" then self:advance(); table.insert(self.tokens,{type=TokenType.PIPE,value="|",line=line})
    elseif c == "~" then
      self:advance()
      if self:match("=") then table.insert(self.tokens,{type=TokenType.NEQ,value="~=",line=line})
      else table.insert(self.tokens,{type=TokenType.TILDE,value="~",line=line}) end
    elseif c == "<" then
      self:advance()
      if self:match("<") then table.insert(self.tokens,{type=TokenType.LSHIFT,value="<<",line=line})
      elseif self:match("=") then table.insert(self.tokens,{type=TokenType.LEQ,value="<=",line=line})
      else table.insert(self.tokens,{type=TokenType.LT,value="<",line=line}) end
    elseif c == ">" then
      self:advance()
      if self:match(">") then table.insert(self.tokens,{type=TokenType.RSHIFT,value=">>",line=line})
      elseif self:match("=") then table.insert(self.tokens,{type=TokenType.GEQ,value=">=",line=line})
      else table.insert(self.tokens,{type=TokenType.GT,value=">",line=line}) end
    elseif c == "=" then
      self:advance()
      if self:match("=") then table.insert(self.tokens,{type=TokenType.EQ,value="==",line=line})
      else table.insert(self.tokens,{type=TokenType.ASSIGN,value="=",line=line}) end
    elseif c == "." then
      self:advance()
      if self:peek() == "." then
        self:advance()
        if self:peek() == "." then
          self:advance(); table.insert(self.tokens,{type=TokenType.DOTDOTDOT,value="...",line=line})
        elseif self:match("=") then table.insert(self.tokens,{type=TokenType.DOTDOT_ASSIGN,value="..=",line=line})
        else table.insert(self.tokens,{type=TokenType.DOTDOT,value="..",line=line}) end
      else table.insert(self.tokens,{type=TokenType.DOT,value=".",line=line}) end
    elseif c == ":" then
      self:advance()
      if self:match(":") then table.insert(self.tokens,{type=TokenType.DCOLON,value="::",line=line})
      else table.insert(self.tokens,{type=TokenType.COLON,value=":",line=line}) end
    elseif c == "(" then self:advance(); table.insert(self.tokens,{type=TokenType.LPAREN,value="(",line=line})
    elseif c == ")" then self:advance(); table.insert(self.tokens,{type=TokenType.RPAREN,value=")",line=line})
    elseif c == "{" then self:advance(); table.insert(self.tokens,{type=TokenType.LBRACE,value="{",line=line})
    elseif c == "}" then self:advance(); table.insert(self.tokens,{type=TokenType.RBRACE,value="}",line=line})
    elseif c == "]" then self:advance(); table.insert(self.tokens,{type=TokenType.RBRACKET,value="]",line=line})
    elseif c == ";" then self:advance(); table.insert(self.tokens,{type=TokenType.SEMI,value=";",line=line})
    elseif c == "," then self:advance(); table.insert(self.tokens,{type=TokenType.COMMA,value=",",line=line})
    else
      table.insert(self.errors, "Unknown character '"..c.."' at line "..self.line)
      self:advance()
    end
  end
  return self.tokens
end

return { Lexer = Lexer, TokenType = TokenType, KEYWORDS = KEYWORDS }
