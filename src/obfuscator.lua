-- obfuscator.lua: Main pipeline orchestrator
local lexerMod  = require("src.lexer.lexer")
local parserMod = require("src.parser.parser")
local resolverMod = require("src.ast.resolver")
local renamerMod  = require("src.transforms.renamer")
local seMod    = require("src.transforms.string_encrypt")
local noMod    = require("src.transforms.number_obfuscate")
local cffMod   = require("src.transforms.control_flow")
local jiMod    = require("src.transforms.junk_inject")
local proxyMod = require("src.transforms.proxy")
local wmMod    = require("src.transforms.watermark")
local wrapMod  = require("src.transforms.wrapper")
local codegenMod = require("src.codegen.codegen")

local Obfuscator = {}
Obfuscator.__index = Obfuscator

-- Default configuration
local DEFAULTS = {
  renameVars     = true,
  encryptStrings = true,
  obfuscateNumbers = true,
  injectJunk     = true,
  junkDensity    = 0.25,
  flattenFlow    = true,
  proxyGlobals   = true,
  watermark      = nil,   -- string or nil
  wrapInFunction = true,
  wrapLayers     = 1,
  minify         = false,
  seed           = nil,   -- nil = random
  preserve       = {},    -- names to never rename
  renameGlobals  = false,
}

-- Preset configurations
local PRESETS = {
  light = {
    renameVars=true, encryptStrings=false, obfuscateNumbers=false,
    injectJunk=false, flattenFlow=false, proxyGlobals=false,
    wrapInFunction=false, wrapLayers=0,
  },
  balanced = {
    renameVars=true, encryptStrings=true, obfuscateNumbers=true,
    injectJunk=true, junkDensity=0.15, flattenFlow=false,
    proxyGlobals=true, wrapInFunction=true, wrapLayers=1,
  },
  heavy = {
    renameVars=true, encryptStrings=true, obfuscateNumbers=true,
    injectJunk=true, junkDensity=0.3, flattenFlow=true,
    proxyGlobals=true, wrapInFunction=true, wrapLayers=2,
  },
  maximum = {
    renameVars=true, encryptStrings=true, obfuscateNumbers=true,
    injectJunk=true, junkDensity=0.5, flattenFlow=true,
    proxyGlobals=true, wrapInFunction=true, wrapLayers=3,
    renameGlobals=false,
  },
}

function Obfuscator.new(config)
  config = config or {}

  -- Apply preset if specified
  if config.preset then
    local preset = PRESETS[config.preset]
    if preset then
      for k, v in pairs(preset) do
        if config[k] == nil then config[k] = v end
      end
    end
  end

  -- Fill defaults
  for k, v in pairs(DEFAULTS) do
    if config[k] == nil then config[k] = v end
  end

  local seed = config.seed or os.time()
  math.randomseed(seed)

  -- Shared RNG
  local _seed = seed
  local function rand(lo, hi)
    _seed = ((_seed * 1664525 + 1013904223) & 0xFFFFFFFF)
    local v = _seed & 0x7FFFFFFF
    if lo and hi then return math.floor((v/0x7FFFFFFF)*(hi-lo+1))+lo end
    return v/0x7FFFFFFF
  end

  return setmetatable({
    config = config,
    seed   = seed,
    rand   = rand,
    stats  = {},
  }, Obfuscator)
end

function Obfuscator:run(source)
  local t0 = os.clock()
  local stats = {
    seed = self.seed,
    inputSize = #source,
    inputLines = 0,
    outputSize = 0,
    outputLines = 0,
    features = {},
    errors = {},
    time = 0,
  }
  for _ in source:gmatch("\n") do stats.inputLines = stats.inputLines + 1 end
  stats.inputLines = stats.inputLines + 1

  -- ── 1. Lex ──────────────────────────────────────────────────────────────
  local lexer = lexerMod.Lexer.new(source)
  local tokens = lexer:tokenize()
  if #lexer.errors > 0 then
    for _, e in ipairs(lexer.errors) do stats.errors[#stats.errors+1] = "Lex: " .. e end
  end

  -- ── 2. Parse ────────────────────────────────────────────────────────────
  local parser = parserMod.Parser.new(tokens)
  local ast = parser:parse()
  if #parser.errors > 0 then
    for _, e in ipairs(parser.errors) do stats.errors[#stats.errors+1] = "Parse: " .. e end
  end

  -- ── 3. Resolve ──────────────────────────────────────────────────────────
  local resolver = resolverMod.Resolver.new()
  resolver:resolve(ast)

  -- ── 4. Rename identifiers ───────────────────────────────────────────────
  local renamer = renamerMod.Renamer.new(self.config, self.seed)
  if self.config.renameVars then
    renamer:renameAll(resolver, self.config)
    stats.features[#stats.features+1] = "identifier-renaming"
  end

  -- Apply renames to AST Name nodes
  for _, sym in ipairs(resolver.symbols) do
    if sym.obfName then
      for _, ref in ipairs(sym.refs) do
        ref._obfName = sym.obfName
      end
      -- Also patch the definition node's name references
      if sym.node then
        -- The codegen will look up .symbol.obfName on Name nodes
      end
    end
  end

  -- ── 5. String encryption ────────────────────────────────────────────────
  local decFuncName, decFuncCode, rot
  if self.config.encryptStrings then
    local se = seMod.StringEncrypt.new(self.config, self.rand)
    decFuncName = "_d" .. tostring(self.rand(1000,9999))
    rot = self.rand(1, 200)
    _, rot, decFuncCode = se:makeDecryptorCode(decFuncName, rot)
    se:transform(ast, decFuncName, rot)
    stats.features[#stats.features+1] = "string-encryption"
  end

  -- ── 6. Number obfuscation ───────────────────────────────────────────────
  if self.config.obfuscateNumbers then
    local no = noMod.NumberObf.new(self.config, self.rand)
    no:transform(ast)
    stats.features[#stats.features+1] = "number-obfuscation"
  end

  -- ── 7. Control flow flattening ──────────────────────────────────────────
  if self.config.flattenFlow then
    local cff = cffMod.CFF.new(self.config, self.rand)
    cff:transform(ast)
    stats.features[#stats.features+1] = "control-flow-flattening"
  end

  -- ── 8. Junk injection ───────────────────────────────────────────────────
  if self.config.injectJunk then
    local ji = jiMod.JunkInject.new(self.config, self.rand)
    ji:transform(ast, self.config.junkDensity)
    stats.features[#stats.features+1] = "junk-injection"
  end

  -- ── 9. Build preamble ───────────────────────────────────────────────────
  local preamble = {}

  -- Proxy globals
  local proxy, proxyLines
  if self.config.proxyGlobals then
    proxy = proxyMod.Proxy.new(self.config, self.rand)
    local pVarName = "_p" .. tostring(self.rand(1000,9999))
    proxyLines = proxy:generateCode(pVarName)
    stats.features[#stats.features+1] = "proxy-globals"
  end

  -- Watermark
  local wmLines
  if self.config.watermark then
    local wm = wmMod.Watermark.new(self.config, self.rand)
    wmLines = wm:generateCode(self.config.watermark)
    stats.features[#stats.features+1] = "watermark"
  end

  -- String decryptor
  if decFuncCode then
    preamble[#preamble+1] = decFuncCode
  end
  if wmLines then
    for _, ln in ipairs(wmLines) do preamble[#preamble+1] = ln end
  end
  if proxyLines then
    for _, ln in ipairs(proxyLines) do preamble[#preamble+1] = ln end
  end

  -- ── 10. Code generation ─────────────────────────────────────────────────
  local cg = codegenMod.CodeGen.new(self.config, renamer)
  local code = cg:generate(ast, preamble)

  -- ── 11. Wrap in function ────────────────────────────────────────────────
  if self.config.wrapInFunction and (self.config.wrapLayers or 0) > 0 then
    local wrapper = wrapMod.Wrapper.new(self.config, self.rand)
    local codeLines = {}
    for ln in (code.."\n"):gmatch("([^\n]*)\n") do
      codeLines[#codeLines+1] = ln
    end
    local wrapped = wrapper:generate(codeLines)
    code = table.concat(wrapped, "\n")
    stats.features[#stats.features+1] = "iife-wrapper(layers=" .. (self.config.wrapLayers) .. ")"
  end

  -- ── 12. Minify (optional) ───────────────────────────────────────────────
  if self.config.minify then
    -- Simple minification: remove blank lines and leading spaces where safe
    local minLines = {}
    for ln in (code.."\n"):gmatch("([^\n]*)\n") do
      local trimmed = ln:match("^%s*(.-)%s*$")
      if trimmed and #trimmed > 0 then
        minLines[#minLines+1] = trimmed
      end
    end
    code = table.concat(minLines, " ")
    stats.features[#stats.features+1] = "minify"
  end

  stats.outputSize = #code
  for _ in code:gmatch("\n") do stats.outputLines = stats.outputLines + 1 end
  stats.outputLines = stats.outputLines + 1
  stats.time = os.clock() - t0
  stats.sizeRatio = string.format("%.1f%%", (stats.outputSize / math.max(1, stats.inputSize)) * 100)

  return code, stats
end

return { Obfuscator = Obfuscator, PRESETS = PRESETS }
