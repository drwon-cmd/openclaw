#!/bin/sh
# Railway entrypoint — generate openclaw.json from env vars before starting gateway
# Plan v0.3 Phase 3.2 (2026-05-17)
#
# Why: Railway containers have no SSH access and no file browser. openclaw.json
# must be created in the persistent volume (/data/.openclaw/) before gateway starts.
# This script regenerates openclaw.json on every boot from current env vars, so
# users can toggle channels/models by editing Railway Variables alone.
#
# References:
#   - openclaw docs §Configuration (JSON5 schema, hot reload)
#   - openclaw docs §Telegram channel (botToken, dmPolicy, allowFrom)
#   - .env.example L52-L74 (provider/channel env vars)

set -e

CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-/data/.openclaw}"
CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-${CONFIG_DIR}/openclaw.json}"

# Sandbox mode default: off (Railway/PaaS containers have no Docker CLI for nested sandboxing)
# Reference: docker-compose.yml comment "Sandbox isolation requires Docker CLI in the image
#            (build with --build-arg OPENCLAW_INSTALL_DOCKER_CLI=1)"
# Override: set OPENCLAW_SANDBOX_MODE=non-main|all only when running on self-hosted with docker.sock
SANDBOX_MODE="${OPENCLAW_SANDBOX_MODE:-off}"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${OPENCLAW_WORKSPACE_DIR:-/data/workspace}"
mkdir -p "${OPENCLAW_AUTH_PROFILE_SECRET_DIR:-/data/.openclaw-secrets}"

# Build telegram channel block conditionally on TELEGRAM_BOT_TOKEN presence
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  if [ -n "${OPENCLAW_DRWON_TELEGRAM_ID:-}" ]; then
    # allowlist mode — user ID pre-registered, pairing not needed
    TELEGRAM_BLOCK='"telegram": {
      "enabled": true,
      "botToken": "'"${TELEGRAM_BOT_TOKEN}"'",
      "dmPolicy": "allowlist",
      "allowFrom": ["'"${OPENCLAW_DRWON_TELEGRAM_ID}"'"]
    }'
  else
    # pairing mode (fallback) — first message returns pairing code
    TELEGRAM_BLOCK='"telegram": {
      "enabled": true,
      "botToken": "'"${TELEGRAM_BOT_TOKEN}"'",
      "dmPolicy": "pairing"
    }'
  fi
else
  TELEGRAM_BLOCK=''
fi

# Build agents.defaults.model block from OPENROUTER_API_KEY presence
# Model IDs verified against https://openrouter.ai/api/v1/models (2026-05-17)
# All chain members are :free to protect Plan §4 Q3 ($2/day OpenRouter hard limit).
# Claude must be invoked manually: /model openrouter/anthropic/claude-sonnet-4.6
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
  MODEL_BLOCK='"model": {
        "primary": "openrouter/deepseek/deepseek-v4-flash:free",
        "fallbacks": [
          "openrouter/qwen/qwen3-next-80b-a3b-instruct:free",
          "openrouter/meta-llama/llama-3.3-70b-instruct:free"
        ]
      },'
else
  # Default openai/gpt-5.5 used if not set (matches first deploy logs)
  MODEL_BLOCK=''
fi

# Channels object — only include telegram if token present
if [ -n "${TELEGRAM_BLOCK}" ]; then
  CHANNELS_OBJ='"channels": {
    '"${TELEGRAM_BLOCK}"'
  },'
else
  CHANNELS_OBJ=''
fi

cat > "${CONFIG_PATH}" <<EOF
{
  "\$schema": "https://docs.openclaw.ai/schemas/openclaw.schema.json",
  ${CHANNELS_OBJ}
  "agents": {
    "defaults": {
      ${MODEL_BLOCK}
      "sandbox": {
        "mode": "${SANDBOX_MODE}"
      }
    }
  },
  "tools": {
    "deny": ["gateway", "cron", "sessions_spawn"]
  }
}
EOF

echo "[entrypoint] Generated openclaw.json at ${CONFIG_PATH}"
echo "[entrypoint] Telegram channel: $([ -n "${TELEGRAM_BOT_TOKEN:-}" ] && echo enabled || echo disabled)"
echo "[entrypoint] OpenRouter: $([ -n "${OPENROUTER_API_KEY:-}" ] && echo enabled || echo disabled)"
echo "[entrypoint] DM policy: $([ -n "${OPENCLAW_DRWON_TELEGRAM_ID:-}" ] && echo allowlist || echo pairing)"
echo "[entrypoint] Sandbox mode: ${SANDBOX_MODE}"

exec "$@"
