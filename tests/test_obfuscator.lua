-- tests/test_obfuscator.lua
-- Basic test suite for LuaObf components

package.path = package.path .. ";../?.lua;../?/init.lua"

local passed = 0
local failed = 0
local errors = {}

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    io.write("  [PASS] " .. name .. "\n")
    passed = passed + 1
  else
    io.write("  [FAIL] " .. name .. "\n")
    io.write("         " .. tostring(err) .. "\n")
    failed = failed + 1
    errors[#errors+1] = {name=name, err=err}
  end
end

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "assertion failed") .. ": expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

local function assert_contains(s, pattern, msg)
  if not tostring(s):find(pattern, 1, true) then
    error((msg or "string does not contain expected pattern") .. ": '" .. pattern .. "' not in '" .. tostring(s):sub(1,100) .. "'")
  end
end

local function assert_not_contains(s, pattern, msg)
  if tostring(s):find(pattern, 1, true) then
    error((msg or "string should not contain pattern") .. ": '" .. pattern .. "' found")
  end
end

-- ── Lexer tests ────────────────────────────────────────────────────────────
io.write("\n[Lexer Tests]\n")

local lexMod = require("src.lexer.lexer")
local Lexer = lexMod.Lexer
local TT = lexMod.TokenType

test("Lexer: basic tokens", function()
  local L = Lexer.new("local x = 42")
  local toks = L:tokenize()
  assert_eq(toks[1].type, TT.LOCAL)
  assert_eq(toks[2].type, TT.NAME)
  assert_eq(toks[2].value, "x")
  assert_eq(toks[3].type, TT.ASSIGN)
  assert_eq(toks[4].type, TT.NUMBER)
  assert_eq(toks[4].value, "42")
end)

test("Lexer: string literals", function()
  local L = Lexer.new([["hello world"]])
  local toks = L:tokenize()
  assert_eq(toks[1].type, TT.STRING)
  assert_eq(toks[1].value, "hello world")
end)

test("Lexer: long string", function()
  local L = Lexer.new("[[hello\nworld]]")
  local toks = L:tokenize()
  assert_eq(toks[1].type, TT.STRING)
  assert_contains(toks[1].value, "world")
end)

test("Lexer: operators", function()
  local L = Lexer.new("+ - * / // % ^ .. ... == ~= <= >=")
  local toks = L:tokenize()
  local types = {}
  for _, t in ipairs(toks) do
    if t.type ~= TT.EOF then types[#types+1] = t.type end
  end
  assert_eq(types[1], TT.PLUS)
  assert_eq(types[7], TT.CARET)
  assert_eq(types[9], TT.DOTDOTDOT)
end)

test("Lexer: hex numbers", function()
  local L = Lexer.new("0xFF 0xDEAD")
  local toks = L:tokenize()
  assert_eq(toks[1].type, TT.NUMBER)
  assert_contains(toks[1].value, "0xFF")
end)

test("Lexer: keywords", function()
  local L = Lexer.new("if then else elseif end while do for in repeat until return function local")
  local toks = L:tokenize()
  assert_eq(toks[1].type, TT.IF)
  assert_eq(toks[2].type, TT.THEN)
  assert_eq(toks[5].type, TT.END)
end)

test("Lexer: comments skipped", function()
  local L = Lexer.new("local x -- this is a comment\nlocal y")
  local toks = L:tokenize()
  -- should be: local, x, local, y, EOF
  assert_eq(toks[1].type, TT.LOCAL)
  assert_eq(toks[2].type, TT.NAME)
  assert_eq(toks[3].type, TT.LOCAL)
  assert_eq(toks[4].type, TT.NAME)
  assert_eq(toks[4].value, "y")
end)

-- ── Parser tests ───────────────────────────────────────────────────────────
io.write("\n[Parser Tests]\n")

local parMod = require("src.parser.parser")
local Parser = parMod.Parser

local function lex_parse(src)
  local L = Lexer.new(src)
  local toks = L:tokenize()
  local P = Parser.new(toks)
  return P:parse(), P.errors
end

test("Parser: local assignment", function()
  local ast, errs = lex_parse("local x = 1")
  assert_eq(#errs, 0, "no errors")
  assert_eq(ast.body.body[1].kind, "Local")
  assert_eq(ast.body.body[1].names[1], "x")
end)

test("Parser: function declaration", function()
  local ast, errs = lex_parse("function foo(a, b) return a + b end")
  assert_eq(#errs, 0, "no errors")
  assert_eq(ast.body.body[1].kind, "FunctionStat")
end)

test("Parser: if/else", function()
  local ast, errs = lex_parse("if x > 0 then print(x) else print(-x) end")
  assert_eq(#errs, 0)
  assert_eq(ast.body.body[1].kind, "If")
end)

test("Parser: for loop", function()
  local ast, errs = lex_parse("for i = 1, 10 do print(i) end")
  assert_eq(#errs, 0)
  assert_eq(ast.body.body[1].kind, "NumericFor")
end)

test("Parser: generic for", function()
  local ast, errs = lex_parse("for k, v in pairs(t) do end")
  assert_eq(#errs, 0)
  assert_eq(ast.body.body[1].kind, "GenericFor")
end)

test("Parser: table constructor", function()
  local ast, errs = lex_parse("local t = {1, 2, key='val'}")
  assert_eq(#errs, 0)
end)

test("Parser: method call", function()
  local ast, errs = lex_parse("obj:method(a, b)")
  assert_eq(#errs, 0)
  local stmt = ast.body.body[1]
  assert_eq(stmt.kind, "CallStat")
  assert_eq(stmt.expr.kind, "MethodCall")
end)

-- ── Renamer tests ──────────────────────────────────────────────────────────
io.write("\n[Renamer Tests]\n")

local renMod = require("src.transforms.renamer")
local Renamer = renMod.Renamer

test("Renamer: generates unique names", function()
  local r = Renamer.new({}, 12345)
  local names = {}
  local seen = {}
  for i = 1, 100 do
    local n = r:unique()
    if seen[n] then error("Duplicate name: " .. n) end
    seen[n] = true
    names[i] = n
  end
  assert_eq(#names, 100)
end)

test("Renamer: first char is valid", function()
  local r = Renamer.new({}, 99999)
  for i = 1, 50 do
    local n = r:unique()
    if not n:sub(1,1):match("[%a_]") then
      error("Invalid first char in: " .. n)
    end
  end
end)

test("Renamer: minimum length", function()
  local r = Renamer.new({}, 42)
  for i = 1, 20 do
    local n = r:unique(8, 20)
    if #n < 8 then error("Name too short: " .. n .. " (" .. #n .. ")") end
  end
end)

-- ── String encryption tests ─────────────────────────────────────────────────
io.write("\n[String Encryption Tests]\n")

local seMod = require("src.transforms.string_encrypt")
local SE = seMod.StringEncrypt

test("StringEncrypt: roundtrip (XOR)", function()
  local se = SE.new({})
  local key = "testkey"
  local s = "Hello, World!"
  local enc = se:xorEncrypt(s, key)
  local dec = se:xorEncrypt(enc, key)  -- XOR is its own inverse
  assert_eq(dec, s, "XOR roundtrip")
end)

test("StringEncrypt: roundtrip (rotation)", function()
  local se = SE.new({})
  local s = "Hello, World!"
  local rot = 42
  local enc = se:rotate(s, rot)
  local dec = se:rotate(enc, 256 - rot)
  assert_eq(dec, s, "rotation roundtrip")
end)

test("StringEncrypt: generates valid Lua expression", function()
  local se = SE.new({})
  local expr = se:encryptString("test string", "_decrypt", 13)
  assert_contains(expr, "_decrypt(")
end)

test("StringEncrypt: empty string", function()
  local se = SE.new({})
  local expr = se:encryptString("", "_d", 5)
  assert_eq(expr, '""')
end)

-- ── Number obfuscation tests ────────────────────────────────────────────────
io.write("\n[Number Obfuscation Tests]\n")

local noMod = require("src.transforms.number_obfuscate")
local NO = noMod.NumberObf

test("NumberObf: XOR identity", function()
  local no = NO.new({})
  -- Test the XOR split: (n ~ k) ~ k == n
  for _, n in ipairs({0, 1, 42, 255, 1000, -5, 100}) do
    local expr = no:obfuscate(n)
    -- Eval the expression
    local fn, err = load("return " .. expr)
    if fn then
      local result = fn()
      if result ~= n then
        error(string.format("MBA failed for %d: expr=%s result=%s", n, expr, tostring(result)))
      end
    end
  end
end)

test("NumberObf: float handling", function()
  local no = NO.new({})
  local expr = no:obfuscate(3.14)
  assert(expr, "should return expression")
  local fn = load("return " .. expr)
  if fn then
    local result = fn()
    -- Allow small floating point error
    if math.abs(result - 3.14) > 0.0001 then
      error("Float obf error: " .. tostring(result) .. " vs 3.14")
    end
  end
end)

test("NumberObf: special values", function()
  local no = NO.new({})
  assert_eq(no:obfuscate(0/0), "(0/0)")
  assert_eq(no:obfuscate(math.huge), "(1/0)")
  assert_eq(no:obfuscate(-math.huge), "(-1/0)")
end)

-- ── Full pipeline test ─────────────────────────────────────────────────────
io.write("\n[Pipeline Tests]\n")

local obfMod = require("src.obfuscator")
local Obfuscator = obfMod.Obfuscator

local SIMPLE_SCRIPT = [[
local x = 42
local y = "hello"
local function add(a, b) return a + b end
print(add(x, 10))
]]

test("Pipeline: light preset produces output", function()
  local obf = Obfuscator.new({ preset="light", seed=1 })
  local code, stats = obf:run(SIMPLE_SCRIPT)
  assert(code and #code > 0, "Should produce output")
  assert(stats, "Should produce stats")
  assert(stats.outputSize > 0, "Output size > 0")
end)

test("Pipeline: balanced preset", function()
  local obf = Obfuscator.new({ preset="balanced", seed=2 })
  local code, stats = obf:run(SIMPLE_SCRIPT)
  assert(code and #code > 0)
  -- Should have more features
  assert(#stats.features >= 3, "Balanced should have 3+ features, got " .. #stats.features)
end)

test("Pipeline: heavy preset", function()
  local obf = Obfuscator.new({ preset="heavy", seed=3 })
  local code, stats = obf:run(SIMPLE_SCRIPT)
  assert(code and #code > 0)
end)

test("Pipeline: maximum preset", function()
  local obf = Obfuscator.new({ preset="maximum", seed=4 })
  local code, stats = obf:run(SIMPLE_SCRIPT)
  assert(code and #code > 0)
  -- Output should be larger due to junk + wrapping
  assert(stats.outputSize > stats.inputSize, "Maximum output should be larger than input")
end)

test("Pipeline: seed reproducibility", function()
  local obf1 = Obfuscator.new({ preset="balanced", seed=12345 })
  local code1 = obf1:run(SIMPLE_SCRIPT)
  local obf2 = Obfuscator.new({ preset="balanced", seed=12345 })
  local code2 = obf2:run(SIMPLE_SCRIPT)
  assert_eq(code1, code2, "Same seed should produce same output")
end)

test("Pipeline: different seeds produce different output", function()
  local obf1 = Obfuscator.new({ preset="balanced", seed=1 })
  local code1 = obf1:run(SIMPLE_SCRIPT)
  local obf2 = Obfuscator.new({ preset="balanced", seed=2 })
  local code2 = obf2:run(SIMPLE_SCRIPT)
  assert(code1 ~= code2, "Different seeds should (very likely) produce different output")
end)

test("Pipeline: watermark embedded", function()
  local obf = Obfuscator.new({ preset="light", seed=1, watermark="TEST_MARK_XYZ" })
  local code = obf:run(SIMPLE_SCRIPT)
  -- Watermark comment should appear in output
  assert_contains(code, "TEST_MARK_XYZ", "Watermark should appear in output")
end)

test("Pipeline: string encryption flag", function()
  local obf = Obfuscator.new({
    renameVars=false,
    encryptStrings=true,
    obfuscateNumbers=false,
    injectJunk=false,
    flattenFlow=false,
    proxyGlobals=false,
    wrapInFunction=false,
    seed=1
  })
  local code = obf:run(SIMPLE_SCRIPT)
  -- Original string "hello" should not appear literally
  assert_not_contains(code, '"hello"', "Encrypted string should not appear literally")
end)

test("Pipeline: wrap layers", function()
  local obf = Obfuscator.new({
    preset="light",
    wrapInFunction=true,
    wrapLayers=2,
    seed=1
  })
  local code = obf:run(SIMPLE_SCRIPT)
  -- Should contain (function(
  assert_contains(code, "(function(", "Should contain IIFE wrapper")
end)

test("Pipeline: complex script", function()
  local complex = [[
local M = {}

function M.new(name, value)
  local self = setmetatable({}, {__index = M})
  self.name = name
  self.value = value
  self.data = {}
  return self
end

function M:process(factor)
  local result = self.value * factor
  for i = 1, 5 do
    result = result + i * 2
    if result > 100 then
      result = result % 100
    end
  end
  return result
end

function M:toString()
  return self.name .. "=" .. tostring(self:process(3))
end

local obj = M.new("test", 42)
print(obj:toString())

return M
]]
  local obf = Obfuscator.new({ preset="balanced", seed=999 })
  local code, stats = obf:run(complex)
  assert(code and #code > 0, "Complex script should obfuscate")
  assert(not stats.errors or #stats.errors == 0,
    "Complex script should have no fatal errors, got: " ..
    (#(stats.errors or {}) > 0 and stats.errors[1] or "none"))
end)

-- ── Summary ────────────────────────────────────────────────────────────────
io.write(string.format("\n══════════════════════════════════════\n"))
io.write(string.format("Results: %d passed, %d failed\n", passed, failed))
if #errors > 0 then
  io.write("Failed tests:\n")
  for _, e in ipairs(errors) do
    io.write("  - " .. e.name .. ": " .. tostring(e.err) .. "\n")
  end
end
io.write("══════════════════════════════════════\n")

if failed > 0 then os.exit(1) end
