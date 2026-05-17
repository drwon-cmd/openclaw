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
# Model IDs verified against https://openrouter.ai/api/v1/models (2026-05-17, re-fetched)
#
# CHAIN RATIONALE (2026-05-18 — Railway log diagnosis, runId 2a9cc7ed/a0cd9d28/d2e52cc7):
#   Previous chain (v4-pro primary) produced 100% failure across 4 user messages:
#     - openrouter/deepseek/deepseek-v4-pro: HTTP 500 × 4 retries (OpenRouter routing
#       broken for Pro as of 2026-05-17 evening)
#     - openrouter/deepseek/deepseek-v4-flash:free: reasoning-only × 2 retries
#       (default thinking=high consumed budget without visible content)
#     - openrouter/deepseek/deepseek-v4-flash (paid): 500 intermittent (1 success
#       at 15:40:55, otherwise 500). When it works, it works.
#
# NEW CHAIN — flash(paid) primary:
#   1. deepseek-v4-flash (paid) — proven to succeed. $0.112/M in, $0.224/M out.
#      Plan §4 Q3 $2/day still allows ~17M input or ~8M output tokens daily.
#   2. deepseek-v4-flash:free — FREE backup. With thinkingDefault=medium below,
#      reasoning-only risk reduced.
#   3. deepseek-v4-pro — last resort. Currently 500ing but OpenRouter may restore.
#      Once flash works, this is never tried (no delay impact in happy path).
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
  MODEL_BLOCK='"model": {
        "primary": "openrouter/deepseek/deepseek-v4-flash",
        "fallbacks": [
          "openrouter/deepseek/deepseek-v4-flash:free",
          "openrouter/deepseek/deepseek-v4-pro"
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
      "thinkingDefault": "medium",
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
