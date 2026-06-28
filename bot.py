""" bot.py: Discord bot frontend for LuaObf Handles commands, file uploads, and spawns the Lua obfuscator as a subprocess. Never implements any obfuscation logic itself. """
import asyncio
import io
import json
import logging
import os
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Optional
import discord
from discord import app_commands
from discord.ext import commands

# Keep-alive web server
from flask import Flask
from threading import Thread

# Configuration
DISCORD_TOKEN = os.environ.get("DISCORD_TOKEN", "")
LUA_EXECUTABLE = os.environ.get("LUA_BIN", "lua")
CLI_PATH = os.environ.get("CLI_PATH", "./cli.lua")
MAX_FILE_SIZE = int(os.environ.get("MAX_FILE_SIZE", str(512 * 1024))) # 512 KB
MAX_OUTPUT_SIZE = int(os.environ.get("MAX_OUTPUT_SIZE", str(8 * 1024 * 1024))) # 8 MB
MAX_TIMEOUT = int(os.environ.get("TIMEOUT", "60"))
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO")
ALLOWED_GUILD_IDS = [int(x) for x in os.environ.get("ALLOWED_GUILDS", "").split(",") if x.strip()]
QUEUE_MAX = int(os.environ.get("QUEUE_MAX", "10"))
PREFIX = os.environ.get("PREFIX", "!")

# Logging
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL.upper(), logging.INFO),
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("luaobf-bot")

# Allowed file extensions
ALLOWED_EXT = {".lua", ".luau", ".txt"}
VALID_PRESETS = {"light", "balanced", "heavy", "maximum"}

# Job queue
class JobQueue:
    def __init__(self, max_size: int):
        self._sem = asyncio.Semaphore(max_size)
        self.total = 0
        self.succeeded = 0
        self.failed = 0
        self._lock = asyncio.Lock()

    async def acquire(self) -> bool:
        try:
            await asyncio.wait_for(self._sem.acquire(), timeout=5.0)
            return True
        except asyncio.TimeoutError:
            return False

    def release(self):
        self._sem.release()

    async def record(self, success: bool):
        async with self._lock:
            self.total += 1
            if success:
                self.succeeded += 1
            else:
                self.failed += 1

# Bot setup
intents = discord.Intents.default()
intents.message_content = True
bot = commands.Bot(command_prefix=PREFIX, intents=intents, help_command=None)
queue = JobQueue(QUEUE_MAX)
start_time = time.time()

# Keep-alive server
app = Flask(__name__)

@app.route('/')
def home():
    return "LuaObf Discord Bot is running!"

def run_flask():
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port, debug=False)

# Helpers
def validate_attachment(attachment: discord.Attachment) -> Optional[str]:
    """Return error string or None if valid."""
    ext = Path(attachment.filename).suffix.lower()
    if ext not in ALLOWED_EXT:
        return f"❌ Invalid file type `{ext}`. Allowed: {', '.join(sorted(ALLOWED_EXT))}"
    if attachment.size > MAX_FILE_SIZE:
        return f"❌ File too large ({attachment.size:,} bytes). Max: {MAX_FILE_SIZE:,} bytes."
    return None

def build_cli_args(preset: str, seed: Optional[int], options: dict) -> list:
    """Build CLI argument list from options."""
    args = [LUA_EXECUTABLE, CLI_PATH]
    if preset:
        args += ["--preset", preset]
    if seed is not None:
        args += ["--seed", str(seed)]
    if options.get("no_rename"):
        args.append("--no-rename")
    if options.get("no_strings"):
        args.append("--no-strings")
    if options.get("no_numbers"):
        args.append("--no-numbers")
    if options.get("no_junk"):
        args.append("--no-junk")
    if options.get("no_flow"):
        args.append("--no-flow")
    if options.get("no_proxy"):
        args.append("--no-proxy")
    if options.get("minify"):
        args.append("--minify")
    if options.get("watermark"):
        args += ["--watermark", options["watermark"]]
    if options.get("wrap_layers") is not None:
        args += ["--wrap-layers", str(options["wrap_layers"])]
    if options.get("junk_density") is not None:
        args += ["--junk-density", str(options["junk_density"])]
    if options.get("preserve"):
        args += ["--preserve", options["preserve"]]
    args.append("--stats")
    return args

async def run_obfuscator(
    source_bytes: bytes,
    filename: str,
    preset: str,
    seed: Optional[int],
    options: dict,
) -> tuple[Optional[bytes], Optional[str], Optional[dict]]:
    """ Run the Lua obfuscator subprocess. Returns (output_bytes, error_str, stats_dict). """
    suffix = Path(filename).suffix or ".lua"
    with tempfile.TemporaryDirectory(prefix="luaobf_") as tmpdir:
        input_path = Path(tmpdir) / f"input{suffix}"
        output_path = Path(tmpdir) / f"output{suffix}"
        input_path.write_bytes(source_bytes)
        args = build_cli_args(preset, seed, options)
        args += ["--output", str(output_path), str(input_path)]
        log.info("Running: %s", " ".join(str(a) for a in args))
        try:
            proc = await asyncio.create_subprocess_exec(
                *args,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=Path(CLI_PATH).parent.resolve(),
            )
            stdout, stderr = await asyncio.wait_for(
                proc.communicate(),
                timeout=MAX_TIMEOUT
            )
        except asyncio.TimeoutError:
            try:
                proc.kill()
            except Exception:
                pass
            return None, f"❌ Obfuscation timed out after {MAX_TIMEOUT}s.", None
        except FileNotFoundError:
            return None, f"❌ Lua interpreter not found at `{LUA_EXECUTABLE}`.", None
        except Exception as exc:
            return None, f"❌ Subprocess error: {exc}", None

        stderr_text = stderr.decode("utf-8", errors="replace")
        log.debug("STDERR: %s", stderr_text)
        if proc.returncode != 0:
            short = stderr_text[-800:] if len(stderr_text) > 800 else stderr_text
            return None, f"❌ Obfuscator failed (exit {proc.returncode}):\n```\n{short}\n```", None
        if not output_path.exists():
            return None, "❌ Obfuscator produced no output file.", None
        output_bytes = output_path.read_bytes()
        if len(output_bytes) > MAX_OUTPUT_SIZE:
            return None, f"❌ Output too large ({len(output_bytes):,} bytes).", None
        # Parse stats from stderr
        stats = parse_stats(stderr_text, source_bytes, output_bytes)
        return output_bytes, None, stats

def parse_stats(stderr: str, input_bytes: bytes, output_bytes: bytes) -> dict:
    """Extract stats from CLI stderr output."""
    stats = {
        "input_size": len(input_bytes),
        "output_size": len(output_bytes),
        "ratio": f"{len(output_bytes)/max(1,len(input_bytes))*100:.1f}%",
        "time": "?",
        "features": [],
    }
    for line in stderr.splitlines():
        if "Done in" in line:
            t = line.split("Done in")[-1].split("s")[0].strip()
            stats["time"] = t + "s"
        if "✅" in line or "[+]" in line:
            feat = line.strip().lstrip("✅ ").lstrip("[+] ")
            if feat:
                stats["features"].append(feat)
    return stats

def make_stats_embed(filename: str, stats: dict, seed: Optional[int], preset: str) -> discord.Embed:
    """Build a rich embed for the stats display."""
    embed = discord.Embed(
        title="🔒 Obfuscation Complete",
        color=0x5865F2,
    )
    embed.add_field(name="File", value=f"`{filename}`", inline=True)
    embed.add_field(name="Preset", value=f"`{preset or 'custom'}`", inline=True)
    if seed is not None:
        embed.add_field(name="Seed", value=f"`{seed}`", inline=True)
    embed.add_field(
        name="Size",
        value=f"`{stats['input_size']:,}` → `{stats['output_size']:,}` bytes ({stats['ratio']})",
        inline=False,
    )
    embed.add_field(name="Time", value=f"`{stats['time']}`", inline=True)
    if stats["features"]:
        embed.add_field(
            name="Features",
            value="\n".join(f"✅ {f}" for f in stats["features"]),
            inline=False,
        )
    embed.set_footer(text="LuaObf • Lua/Luau Source Obfuscator")
    return embed

# Prefix commands
@bot.command(name="obfuscate", aliases=["obf", "o"])
async def obfuscate_prefix(ctx: commands.Context, preset: str = "balanced", seed: Optional[int] = None):
    """ Obfuscate a Lua file. Usage: !obfuscate [preset] [seed] Attach a .lua / .luau / .txt file. """
    if not ctx.message.attachments:
        await ctx.send("❌ Please attach a `.lua`, `.luau`, or `.txt` file.")
        return
    attachment = ctx.message.attachments[0]
    err = validate_attachment(attachment)
    if err:
        await ctx.send(err)
        return
    preset = preset.lower()
    if preset not in VALID_PRESETS:
        await ctx.send(f"❌ Invalid preset `{preset}`. Choose: {', '.join(sorted(VALID_PRESETS))}")
        return
    if not await queue.acquire():
        await ctx.send("⏳ Server is busy. Please try again in a moment.")
        return
    async with ctx.typing():
        try:
            source = await attachment.read()
            output, error, stats = await run_obfuscator(
                source, attachment.filename, preset, seed, {}
            )
            await queue.record(output is not None)
            if error:
                await ctx.send(error)
                return
            out_filename = Path(attachment.filename).stem + ".obf" + Path(attachment.filename).suffix
            file = discord.File(io.BytesIO(output), filename=out_filename)
            embed = make_stats_embed(attachment.filename, stats, seed, preset)
            await ctx.send(file=file, embed=embed)
        except Exception as exc:
            log.exception("Unhandled error in !obfuscate")
            await ctx.send(f"❌ Internal error: {exc}")
        finally:
            queue.release()

@bot.command(name="help", aliases=["h"])
async def help_cmd(ctx: commands.Context):
    embed = discord.Embed(title="🔒 LuaObf Help", color=0x5865F2)
    embed.add_field(
        name="Commands",
        value=(
            "`!obfuscate [preset] [seed]` — Attach a Lua file to obfuscate\n"
            "`!stats` — Show bot statistics\n"
            "`!presets` — List available presets\n"
            "`/obfuscate` — Slash command with full options\n"
        ),
        inline=False,
    )
    embed.add_field(
        name="Presets",
        value=(
            "`light` — Rename only, fast\n"
            "`balanced` — Rename + encrypt strings + numbers\n"
            "`heavy` — Full obfuscation + CFF + proxy\n"
            "`maximum` — Maximum protection, densest output\n"
        ),
        inline=False,
    )
    embed.add_field(
        name="Supported Formats",
        value="`.lua` `.luau` `.txt`",
        inline=False,
    )
    embed.set_footer(text="LuaObf • Lua/Luau Source Obfuscator")
    await ctx.send(embed=embed)

@bot.command(name="stats")
async def stats_cmd(ctx: commands.Context):
    uptime = time.time() - start_time
    hours, rem = divmod(int(uptime), 3600)
    mins, secs = divmod(rem, 60)
    embed = discord.Embed(title="📊 Bot Statistics", color=0x5865F2)
    embed.add_field(name="Uptime", value=f"`{hours:02d}h {mins:02d}m {secs:02d}s`", inline=True)
    embed.add_field(name="Jobs Run", value=f"`{queue.total}`", inline=True)
    embed.add_field(name="Succeeded", value=f"`{queue.succeeded}`", inline=True)
    embed.add_field(name="Failed", value=f"`{queue.failed}`", inline=True)
    embed.add_field(name="Lua Bin", value=f"`{LUA_EXECUTABLE}`", inline=True)
    await ctx.send(embed=embed)

@bot.command(name="presets")
async def presets_cmd(ctx: commands.Context):
    embed = discord.Embed(title="📋 Available Presets", color=0x5865F2)
    descriptions = {
        "light": "Identifier renaming only. Fast, minimal size increase.",
        "balanced": "Rename + string encryption + number MBA. Good default.",
        "heavy": "All of balanced + control flow flattening + proxy globals + 2 wrap layers.",
        "maximum": "Everything enabled. Densest junk, 3 IIFE layers. Largest output.",
    }
    for name, desc in descriptions.items():
        embed.add_field(name=f"`{name}`", value=desc, inline=False)
    await ctx.send(embed=embed)

# Slash commands
@bot.tree.command(name="obfuscate", description="Obfuscate a Lua/Luau source file")
@app_commands.describe(
    file="The .lua / .luau / .txt file to obfuscate",
    preset="Obfuscation preset (default: balanced)",
    seed="RNG seed for reproducible output",
    watermark="Embed a forensic watermark string",
    wrap_layers="Number of IIFE wrapper layers (0-3)",
    junk_density="Junk code density 0.0-1.0",
    minify="Minify the output",
    no_rename="Disable identifier renaming",
    no_strings="Disable string encryption",
    no_numbers="Disable number obfuscation",
    no_junk="Disable junk injection",
    no_flow="Disable control flow flattening",
    no_proxy="Disable global proxy table",
)
@app_commands.choices(preset=[
    app_commands.Choice(name="light", value="light"),
    app_commands.Choice(name="balanced", value="balanced"),
    app_commands.Choice(name="heavy", value="heavy"),
    app_commands.Choice(name="maximum", value="maximum"),
])
async def obfuscate_slash(
    interaction: discord.Interaction,
    file: discord.Attachment,
    preset: app_commands.Choice[str] = None,
    seed: Optional[int] = None,
    watermark: Optional[str] = None,
    wrap_layers: Optional[int] = None,
    junk_density: Optional[float] = None,
    minify: bool = False,
    no_rename: bool = False,
    no_strings: bool = False,
    no_numbers: bool = False,
    no_junk: bool = False,
    no_flow: bool = False,
    no_proxy: bool = False,
):
    err = validate_attachment(file)
    if err:
        await interaction.response.send_message(err, ephemeral=True)
        return
    chosen_preset = preset.value if preset else "balanced"
    if not await queue.acquire():
        await interaction.response.send_message(
            "⏳ Server is busy. Please try again shortly.", ephemeral=True
        )
        return
    await interaction.response.defer(thinking=True)
    try:
        source = await file.read()
        options = {
            "no_rename": no_rename,
            "no_strings": no_strings,
            "no_numbers": no_numbers,
            "no_junk": no_junk,
            "no_flow": no_flow,
            "no_proxy": no_proxy,
            "minify": minify,
            "watermark": watermark,
            "wrap_layers": wrap_layers,
            "junk_density": junk_density,
        }
        output, error, stats = await run_obfuscator(
            source, file.filename, chosen_preset, seed, options
        )
        await queue.record(output is not None)
        if error:
            await interaction.followup.send(error)
            return
        out_filename = Path(file.filename).stem + ".obf" + Path(file.filename).suffix
        disc_file = discord.File(io.BytesIO(output), filename=out_filename)
        embed = make_stats_embed(file.filename, stats, seed, chosen_preset)
        await interaction.followup.send(file=disc_file, embed=embed)
    except Exception as exc:
        log.exception("Unhandled error in /obfuscate")
        await interaction.followup.send(f"❌ Internal error: {exc}")
    finally:
        queue.release()

@bot.tree.command(name="help", description="Show LuaObf help")
async def help_slash(interaction: discord.Interaction):
    embed = discord.Embed(title="🔒 LuaObf Help", color=0x5865F2)
    embed.add_field(
        name="Usage",
        value=(
            "Use `/obfuscate` with a file attachment and options.\n"
            "Or `!obfuscate [preset] [seed]` with an attached file."
        ),
        inline=False,
    )
    embed.add_field(
        name="Presets",
        value="`light` `balanced` `heavy` `maximum`",
        inline=False,
    )
    await interaction.response.send_message(embed=embed, ephemeral=True)

# Events
@bot.event
async def on_ready():
    log.info("Logged in as %s (ID: %s)", bot.user, bot.user.id)
    try:
        if ALLOWED_GUILD_IDS:
            for gid in ALLOWED_GUILD_IDS:
                guild = discord.Object(id=gid)
                bot.tree.copy_global_to(guild=guild)
                await bot.tree.sync(guild=guild)
            log.info("Slash commands synced to %d guild(s)", len(ALLOWED_GUILD_IDS))
        else:
            await bot.tree.sync()
            log.info("Slash commands synced globally")
    except Exception as exc:
        log.error("Failed to sync commands: %s", exc)
    await bot.change_presence(
        activity=discord.Activity(
            type=discord.ActivityType.watching,
            name="Lua scripts | !help"
        )
    )

@bot.event
async def on_command_error(ctx: commands.Context, error: commands.CommandError):
    if isinstance(error, commands.CommandNotFound):
        return
    if isinstance(error, commands.MissingRequiredArgument):
        await ctx.send(f"❌ Missing argument: `{error.param.name}`")
        return
    log.error("Command error in %s: %s", ctx.command, error)
    await ctx.send(f"❌ Error: {error}")

# Entry
if __name__ == "__main__":
    if not DISCORD_TOKEN:
        log.error("DISCORD_TOKEN environment variable is not set!")
        raise SystemExit(1)

    # Start keep-alive server in background thread
    Thread(target=run_flask, daemon=True).start()

    bot.run(DISCORD_TOKEN, log_handler=None)
