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

# Force-write SOUL.md on every boot (workspace persona — Korean tone + session_status guard).
# Per docs/concepts/agent-workspace.md: "Persona, tone, and boundaries. Loaded every session."
#
# 2026-05-18: Switched from idempotent to force-overwrite per Railway log RCA.
# Diagnosis: OpenRouter activity CSV proved 500 errors = session_status tool followup
# failure, NOT OpenRouter instability. The model was calling session_status for daily
# questions (time/greetings) because the previously-preserved SOUL.md had no guard.
# Manual edits to SOUL.md will be overwritten on next deploy — edit this heredoc instead.
SOUL_PATH="${OPENCLAW_WORKSPACE_DIR:-/data/workspace}/SOUL.md"
cat > "${SOUL_PATH}" <<'SOUL_EOF'
# 페르소나

- 응답 언어: 한국어 (사용자가 영어로 물으면 영어 가능, 기본은 한국어)
- 톤: 따뜻하되 솔직, 존댓말 (~합니다/~입니다). 반말 금지
- 빈 인사 금지: "물론이죠!", "좋은 질문입니다!" 등 filler 제거
- 사용자: 원대로 (Won Daero)
- 표준 시간대: Asia/Singapore (UTC+8)

# 도구 사용 원칙 — 최우선 규칙

**일상 대화·일반 질문에는 어떤 도구도 호출하지 마세요. 자체 지식으로 직접 답변하세요.**

도구 호출은 모델 응답 시간을 늘리고 실패 가능성을 키웁니다. 다음 case는 도구 없이 답변:

## 도구 호출 절대 금지 case

- 시간·날짜: "지금 몇시야?" → 컨텍스트의 시간 정보·내부 시계 사용. **`exec`/`bash`/`run`/`date` 명령 호출 금지**
- 인사·감사: "안녕", "고마워" → 짧은 인사 답변만
- 날씨: "오늘 날씨" → "확인이 어렵습니다. 날씨 앱을 참고하세요" 식 직답
- 일반 사실: 모델 자체 지식으로 답변. **`web_search` 호출 금지**
- 잡담: 가벼운 대화 그대로 진행

## `session_status` 도구만 예외적으로 허용

다음 case에서만 `session_status` 호출:
- "봇 상태 알려줘", "지금 상태 어때?"
- "어떤 모델 쓰고 있어?"
- "이번 세션 토큰 얼마나 썼어?", "비용 얼마야?"
- "세션 ID 알려줘"

# 응답 스타일

- 일상 대화는 1-2문장으로 간결히
- 보고서·정리·분석 요청 시 개조식(불릿+표) 우선, 서술형 단락 최소화
- 추측은 명시: "정확히 모름" 보다 "확인 필요"로
- 응답 길이는 질문 복잡도에 비례 (짧은 질문 = 짧은 답)
SOUL_EOF
echo "[entrypoint] Force-wrote SOUL.md at ${SOUL_PATH} (overwrites every boot)"

# Build telegram channel block conditionally on TELEGRAM_BOT_TOKEN presence
# streaming.progress.label fixed to "생각 중..." (was random pick from default crab-themed
# pool: Thinking/Shelling/Scuttling/Clawing/.../Nautiling/etc per
# src/plugin-sdk/channel-streaming.ts:92-113 + docs/concepts/progress-drafts.md:113)
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  if [ -n "${OPENCLAW_DRWON_TELEGRAM_ID:-}" ]; then
    # allowlist mode — user ID pre-registered, pairing not needed
    TELEGRAM_BLOCK='"telegram": {
      "enabled": true,
      "botToken": "'"${TELEGRAM_BOT_TOKEN}"'",
      "dmPolicy": "allowlist",
      "allowFrom": ["'"${OPENCLAW_DRWON_TELEGRAM_ID}"'"],
      "streaming": {
        "mode": "progress",
        "progress": {
          "label": "생각 중..."
        }
      }
    }'
  else
    # pairing mode (fallback) — first message returns pairing code
    TELEGRAM_BLOCK='"telegram": {
      "enabled": true,
      "botToken": "'"${TELEGRAM_BOT_TOKEN}"'",
      "dmPolicy": "pairing",
      "streaming": {
        "mode": "progress",
        "progress": {
          "label": "생각 중..."
        }
      }
    }'
  fi
else
  TELEGRAM_BLOCK=''
fi

# Build agents.defaults.model block from OPENROUTER_API_KEY presence
# Model IDs verified against https://openrouter.ai/api/v1/models (2026-05-17, re-fetched)
#
# CHAIN RATIONALE (2026-05-18 — Railway log diagnosis after first fix, runId 9d323d45):
#   Even with v4-flash primary, full chain cascade ~60s wait observed:
#     stage 1: v4-flash HTTP 500 × 4 retries (~24s)
#     stage 2: v4-flash:free reasoning-only × 2 retries (~10s)
#     stage 3: v4-pro succeeded after ~16s
#   OpenRouter DeepSeek is intermittently unstable across the entire family.
#
# FINAL CHAIN — DeepSeek 3 + Anthropic safety net:
#   1. deepseek-v4-flash (paid) — primary. $0.112/M in, $0.224/M out.
#   2. deepseek-v4-flash:free — FREE backup. thinkingDefault=medium limits
#      reasoning-only risk.
#   3. deepseek-v4-pro — last DeepSeek. Recovered at 16:18:47 in latest log.
#   4. anthropic/claude-haiku-4.5 — safety net. Triggered ONLY when all 3
#      DeepSeek fail. $1/M in, $5/M out (verified via OpenRouter /api/v1/models
#      2026-05-18). 200K context, version-pinned (not router). Cost impact
#      near-zero in happy path; protects user from full-cascade ~60s wait.
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
  MODEL_BLOCK='"model": {
        "primary": "openrouter/deepseek/deepseek-v4-flash",
        "fallbacks": [
          "openrouter/deepseek/deepseek-v4-flash:free",
          "openrouter/deepseek/deepseek-v4-pro",
          "openrouter/anthropic/claude-haiku-4.5"
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
    "profile": "messaging"
  }
}
EOF

echo "[entrypoint] Generated openclaw.json at ${CONFIG_PATH}"
echo "[entrypoint] Telegram channel: $([ -n "${TELEGRAM_BOT_TOKEN:-}" ] && echo enabled || echo disabled)"
echo "[entrypoint] OpenRouter: $([ -n "${OPENROUTER_API_KEY:-}" ] && echo enabled || echo disabled)"
echo "[entrypoint] DM policy: $([ -n "${OPENCLAW_DRWON_TELEGRAM_ID:-}" ] && echo allowlist || echo pairing)"
echo "[entrypoint] Sandbox mode: ${SANDBOX_MODE}"

exec "$@"
