# LuaObf — Lua/Luau Source Code Obfuscator + Discord Bot

A production-grade Lua/Luau obfuscator written in pure Lua, with a Python Discord bot frontend.

## Features

- **Full AST pipeline**: Lexer → Parser → Resolver → Transforms → Code Generator
- **Identifier renaming**: High-entropy random names
- **String encryption**: XOR + rotation with runtime decryptor
- **Number obfuscation**: Mixed Boolean Arithmetic (MBA) expressions
- **Junk code injection**: Dead branches, opaque predicates, bogus computations
- **Control flow flattening**: State-machine dispatcher loops
- **Global proxy tables**: Indirection through shuffled key tables
- **IIFE wrapping**: 1–3 nested immediately-invoked function layers
- **Watermarking**: Forensic identifiers embedded in dead code
- **Configurable presets**: `light`, `balanced`, `heavy`, `maximum`
- **Discord bot**: Slash + prefix commands, file upload, stats embed
- **Docker ready**: Single Dockerfile + docker-compose

## Quick Start

### Obfuscator (CLI)

```bash
# Light rename only
lua cli.lua script.lua --preset light

# Full maximum obfuscation with watermark
lua cli.lua script.lua --preset maximum --watermark "MyProject_v1" --stats

# Custom options
lua cli.lua script.lua --no-junk --wrap-layers 2 --seed 12345 --output out.lua

# Print to stdout
lua cli.lua script.lua --preset balanced --stdout
```

### Presets

| Preset     | Rename | Strings | Numbers | Junk | CFF | Proxy | Wrap |
|------------|--------|---------|---------|------|-----|-------|------|
| `light`    | ✅     | ❌      | ❌      | ❌   | ❌  | ❌    | ❌   |
| `balanced` | ✅     | ✅      | ✅      | ✅   | ❌  | ✅    | 1    |
| `heavy`    | ✅     | ✅      | ✅      | ✅   | ✅  | ✅    | 2    |
| `maximum`  | ✅     | ✅      | ✅      | ✅   | ✅  | ✅    | 3    |

### CLI Options

```
--output, -o <file>      Output file path
--preset <name>          light | balanced | heavy | maximum
--seed <n>               RNG seed for reproducible output
--no-rename              Disable identifier renaming
--no-strings             Disable string encryption
--no-numbers             Disable number obfuscation
--no-junk                Disable junk injection
--no-flow                Disable control flow flattening
--no-proxy               Disable global proxy table
--no-wrap                Disable IIFE wrapping
--wrap-layers <n>        IIFE wrap depth (default: 1)
--junk-density <f>       Junk density 0.0–1.0 (default: 0.25)
--watermark <text>       Embed forensic watermark
--minify                 Minify output
--preserve <n1,n2,...>   Names to never rename
--stdout                 Output to stdout
--stats                  Show processing statistics
--help                   Show help
```

## Discord Bot

### Setup

1. Create a Discord application and bot at https://discord.com/developers
2. Copy your bot token
3. Copy `.env.example` to `.env` and fill in your token
4. Install dependencies: `pip install -r bot/requirements.txt`
5. Run: `python bot/bot.py`

### Bot Commands

| Command | Description |
|---------|-------------|
| `!obfuscate [preset] [seed]` | Obfuscate attached file |
| `!help` | Show help |
| `!stats` | Show bot statistics |
| `!presets` | List presets |
| `/obfuscate` | Slash command with full options |
| `/help` | Slash help |

### Docker

```bash
cd docker
cp ../.env.example ../.env  # fill in DISCORD_TOKEN
docker-compose up -d
```

### Render.com Deployment

1. Connect your GitHub repo to Render
2. Set `DISCORD_TOKEN` environment variable
3. Set build command: `pip install -r bot/requirements.txt`
4. Set start command: `python bot/bot.py`

## Running Tests

```bash
cd luaobf
lua tests/test_obfuscator.lua
```

## Project Structure

```
luaobf/
├── cli.lua                     # CLI entry point
├── src/
│   ├── obfuscator.lua          # Main pipeline orchestrator
│   ├── lexer/lexer.lua         # Lua/Luau lexer
│   ├── parser/parser.lua       # Recursive-descent parser
│   ├── ast/resolver.lua        # Scope/symbol resolver
│   ├── transforms/
│   │   ├── renamer.lua         # Identifier renaming
│   │   ├── string_encrypt.lua  # String encryption
│   │   ├── number_obfuscate.lua# Number → MBA
│   │   ├── control_flow.lua    # Control flow flattening
│   │   ├── junk_inject.lua     # Junk code injection
│   │   ├── proxy.lua           # Global proxy tables
│   │   ├── watermark.lua       # Forensic watermarking
│   │   └── wrapper.lua         # IIFE wrapping
│   └── codegen/codegen.lua     # Code generator
├── presets/maximum.lua
├── bot/
│   ├── bot.py                  # Discord bot
│   └── requirements.txt
├── docker/
│   ├── Dockerfile
│   └── docker-compose.yml
├── tests/test_obfuscator.lua
├── examples/example.lua
├── .env.example
└── README.md
```

## Supported Input Formats

- `.lua` — Standard Lua 5.1–5.4
- `.luau` — Roblox Luau (compound assignments, type annotations stripped)
- `.txt` — Treated as Lua source

## Requirements

- **Obfuscator**: Lua 5.2+ (uses bitwise operators) or LuaJIT
- **Bot**: Python 3.12+, discord.py 2.3+
- **Docker**: Docker 20+, docker-compose 1.29+

## License

MIT License — see LICENSE file.
