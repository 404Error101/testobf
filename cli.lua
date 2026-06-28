-- cli.lua: Command-line interface for the Lua obfuscator
-- Usage: lua cli.lua input.lua [options]

-- Adjust package path so relative requires work
package.path = package.path .. ";./?.lua;./?/init.lua"

local obfMod = require("src.obfuscator")
local Obfuscator = obfMod.Obfuscator
local PRESETS = obfMod.PRESETS

-- ── Help ──────────────────────────────────────────────────────────────────
local HELP = [[
LuaObf - Lua/Luau Source Code Obfuscator
Usage: lua cli.lua <input> [options]

Options:
  --output, -o <file>    Output file (default: <input>.obf.lua)
  --preset <name>        Preset: light | balanced | heavy | maximum
  --seed <n>             RNG seed (for reproducible output)
  --no-rename            Disable identifier renaming
  --no-strings           Disable string encryption
  --no-numbers           Disable number obfuscation
  --no-junk              Disable junk code injection
  --no-flow              Disable control flow flattening
  --no-proxy             Disable global proxying
  --no-wrap              Disable IIFE wrapping
  --wrap-layers <n>      Number of IIFE wrap layers (default: 1)
  --junk-density <f>     Junk injection density 0.0-1.0 (default: 0.25)
  --watermark <text>     Embed forensic watermark
  --minify               Minify output
  --preserve <n1,n2,...> Comma-separated names to never rename
  --stdout               Print to stdout instead of file
  --stats                Show processing statistics
  --help, -h             Show this help

Examples:
  lua cli.lua game.lua --preset maximum --watermark "MyGame_v1"
  lua cli.lua script.lua --preset balanced --output out.lua --stats
  lua cli.lua module.lua --seed 12345 --no-junk --wrap-layers 2
]]

-- ── Argument parser ────────────────────────────────────────────────────────
local function parseArgs(args)
  local opts = {
    input      = nil,
    output     = nil,
    stdout     = false,
    showStats  = false,
    config     = {},
  }

  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--help" or a == "-h" then
      io.write(HELP); os.exit(0)
    elseif a == "--output" or a == "-o" then
      i = i + 1; opts.output = args[i]
    elseif a == "--preset" then
      i = i + 1; opts.config.preset = args[i]
    elseif a == "--seed" then
      i = i + 1; opts.config.seed = tonumber(args[i])
    elseif a == "--no-rename" then
      opts.config.renameVars = false
    elseif a == "--no-strings" then
      opts.config.encryptStrings = false
    elseif a == "--no-numbers" then
      opts.config.obfuscateNumbers = false
    elseif a == "--no-junk" then
      opts.config.injectJunk = false
    elseif a == "--no-flow" then
      opts.config.flattenFlow = false
    elseif a == "--no-proxy" then
      opts.config.proxyGlobals = false
    elseif a == "--no-wrap" then
      opts.config.wrapInFunction = false
      opts.config.wrapLayers = 0
    elseif a == "--wrap-layers" then
      i = i + 1
      opts.config.wrapLayers = tonumber(args[i]) or 1
      opts.config.wrapInFunction = true
    elseif a == "--junk-density" then
      i = i + 1; opts.config.junkDensity = tonumber(args[i])
    elseif a == "--watermark" then
      i = i + 1; opts.config.watermark = args[i]
    elseif a == "--minify" then
      opts.config.minify = true
    elseif a == "--preserve" then
      i = i + 1
      opts.config.preserve = {}
      for name in args[i]:gmatch("[^,]+") do
        opts.config.preserve[#opts.config.preserve+1] = name:match("^%s*(.-)%s*$")
      end
    elseif a == "--stdout" then
      opts.stdout = true
    elseif a == "--stats" then
      opts.showStats = true
    elseif not a:match("^%-") then
      if not opts.input then opts.input = a
      elseif not opts.output then opts.output = a end
    else
      io.stderr:write("Unknown option: " .. a .. "\n")
    end
    i = i + 1
  end

  return opts
end

-- ── File I/O ──────────────────────────────────────────────────────────────
local function readFile(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local content = f:read("*a")
  f:close()
  return content
end

local function writeFile(path, content)
  local f, err = io.open(path, "wb")
  if not f then return false, err end
  f:write(content)
  f:close()
  return true
end

local function defaultOutput(input)
  local base = input:match("^(.+)%.%w+$") or input
  return base .. ".obf.lua"
end

-- ── Stats display ─────────────────────────────────────────────────────────
local function printStats(stats)
  io.stderr:write("\n┌─ Obfuscation Statistics ─────────────────┐\n")
  io.stderr:write(string.format("│  Seed:         %-27d │\n", stats.seed))
  io.stderr:write(string.format("│  Time:         %-24.3fs │\n", stats.time))
  io.stderr:write(string.format("│  Input size:   %-20d bytes │\n", stats.inputSize))
  io.stderr:write(string.format("│  Output size:  %-20d bytes │\n", stats.outputSize))
  io.stderr:write(string.format("│  Size ratio:   %-27s │\n", stats.sizeRatio))
  io.stderr:write(string.format("│  Input lines:  %-27d │\n", stats.inputLines))
  io.stderr:write(string.format("│  Output lines: %-27d │\n", stats.outputLines))
  io.stderr:write("│  Features:                               │\n")
  for _, f in ipairs(stats.features) do
    io.stderr:write(string.format("│    ✓ %-37s │\n", f))
  end
  if #stats.errors > 0 then
    io.stderr:write("│  Warnings:                               │\n")
    for _, e in ipairs(stats.errors) do
      local short = e:sub(1, 36)
      io.stderr:write(string.format("│    ! %-37s │\n", short))
    end
  end
  io.stderr:write("└──────────────────────────────────────────┘\n\n")
end

-- ── Main ──────────────────────────────────────────────────────────────────
local function main(args)
  if #args == 0 then
    io.write(HELP); os.exit(0)
  end

  local opts = parseArgs(args)

  if not opts.input then
    io.stderr:write("Error: No input file specified.\n")
    io.stderr:write("Run 'lua cli.lua --help' for usage.\n")
    os.exit(1)
  end

  -- Read source
  local source, err = readFile(opts.input)
  if not source then
    io.stderr:write("Error reading '" .. opts.input .. "': " .. (err or "unknown") .. "\n")
    os.exit(1)
  end

  io.stderr:write(string.format("[LuaObf] Processing: %s\n", opts.input))
  if opts.config.preset then
    io.stderr:write(string.format("[LuaObf] Preset: %s\n", opts.config.preset))
  end

  -- Run obfuscator
  local ok, result, stats = pcall(function()
    local obf = Obfuscator.new(opts.config)
    return obf:run(source)
  end)

  if not ok then
    io.stderr:write("Error during obfuscation:\n" .. tostring(result) .. "\n")
    os.exit(1)
  end

  local code = result

  -- Show stats
  if opts.showStats and stats then
    printStats(stats)
  end

  -- Output
  if opts.stdout then
    io.write(code)
  else
    local outPath = opts.output or defaultOutput(opts.input)
    local written, werr = writeFile(outPath, code)
    if not written then
      io.stderr:write("Error writing output: " .. (werr or "unknown") .. "\n")
      os.exit(1)
    end
    io.stderr:write(string.format("[LuaObf] Output written: %s\n", outPath))
    if stats then
      io.stderr:write(string.format("[LuaObf] Done in %.3fs | %d → %d bytes (%s)\n",
        stats.time, stats.inputSize, stats.outputSize, stats.sizeRatio))
    end
  end
end

main(arg or {})
