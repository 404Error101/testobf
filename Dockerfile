FROM python:3.12-slim

# Install Lua
RUN apt-get update && apt-get install -y --no-install-recommends \
    lua5.4 \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy Lua obfuscator source
COPY cli.lua ./
COPY src/ ./src/
COPY presets/ ./presets/
COPY config/ ./config/

# Copy Python bot
COPY bot/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY bot/bot.py ./

# Environment defaults
ENV LUA_BIN=lua5.4
ENV CLI_PATH=/app/cli.lua
ENV LOG_LEVEL=INFO
ENV MAX_FILE_SIZE=524288
ENV TIMEOUT=60
ENV QUEUE_MAX=10
ENV PREFIX=!

# Health check (bot is a long-running process; we just check it started)
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD python -c "import discord; print('ok')" || exit 1

CMD ["python", "bot.py"]
