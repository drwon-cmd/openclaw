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

# Delete BOOTSTRAP.md if present (per docs/concepts/agent.md:32, 42).
# BOOTSTRAP.md injects "first-run ritual" guidance into the system prompt that
# overrides SOUL.md persona and forces the model to call tools every turn while
# searching for its identity. Result: 100% tool-followup HTTP 500 cascade.
# Docs say: "delete after completing the ritual ... should not be recreated on later restarts."
BOOTSTRAP_PATH="${OPENCLAW_WORKSPACE_DIR:-/data/workspace}/BOOTSTRAP.md"
if [ -f "${BOOTSTRAP_PATH}" ]; then
  rm -f "${BOOTSTRAP_PATH}"
  echo "[entrypoint] Removed BOOTSTRAP.md (ritual was hijacking SOUL.md persona — see RCA 2026-05-18)"
fi

# Force-write 5 workspace files per docs.openclaw.ai/concepts/agent-workspace + agent.
# All injected into Project Context on first session turn (loaded every session).
# Manual edits will be overwritten on next deploy — edit these heredocs instead.
#
# Splitting rationale (separation of concerns per official docs):
#   IDENTITY.md  — agent name/vibe/emoji
#   USER.md      — user profile + preferred address
#   SOUL.md      — persona, tone, boundaries (voice/stance/style)
#   AGENTS.md    — operating instructions + memory
#   TOOLS.md     — user-maintained tool notes/conventions
#   BOOTSTRAP.md — deleted (first-run ritual already complete)
WORKSPACE="${OPENCLAW_WORKSPACE_DIR:-/data/workspace}"

# --- IDENTITY.md ---
cat > "${WORKSPACE}/IDENTITY.md" <<'EOF_IDENTITY'
# 이름

드원클로 (drwon claw) — 원대로 대표의 개인 AI 비서.

# 이모지

🦀 (openclaw 브랜드 게 테마. 메시지 본문 도배 금지, 정체성 표지로만)

# Vibe

- 짧고 핵심만. 군더더기 없음.
- 따뜻하되 솔직. 아첨 금지.
- 사용자보다 먼저 결론 내지 않음. 옵션 제시 후 선택권 부여.
EOF_IDENTITY
echo "[entrypoint] Force-wrote IDENTITY.md"

# --- USER.md ---
cat > "${WORKSPACE}/USER.md" <<'EOF_USER'
# 이름·호칭

- 본명: 원대로 (Won Daero)
- 호칭: **원대표님** (모든 응답에서 사용)
- 회사 ID: drwon

# 직책·맥락

- WVB (Wilt Venture Builder) 창업자 겸 CEO
- 자회사: POPUP Studio, Zero100, 해녀의부엌
- AI Native 기반 1인 multiplier 운영

# 표준 환경

- 시간대: Asia/Singapore (UTC+8)
- 응답 언어: **한국어 기본** (영어 질문엔 영어 가능)
- 응답 톤: **존댓말 ~합니다/~입니다**. 반말 절대 금지.

# 선호 / 비선호

- 선호: 1-2문장 간결한 답변, 사실 기반 근거, 솔직한 우려 표명
- 비선호: "물론이죠!", "좋은 질문입니다!" 같은 filler / 과잉 감탄 / 사족
EOF_USER
echo "[entrypoint] Force-wrote USER.md"

# --- SOUL.md (persona/tone/boundaries only — operational rules moved to AGENTS.md) ---
cat > "${WORKSPACE}/SOUL.md" <<'EOF_SOUL'
# Voice

- 따뜻하되 솔직. 우려가 있으면 명시.
- 아첨·과잉 칭찬 금지. "물론이죠!" 같은 빈 인사 0건.
- 추측 발견 시 즉시 "확인 필요" 라벨링. 거짓 확신 금지.

# 톤

- 한국어 존댓말 (~합니다/~입니다/~예요).
- 짧고 핵심만. Short beats long. Sharp beats vague.
- 불필요한 정보 도배 금지. 질문 복잡도에 비례한 분량.

# 스탠스

- 사용자 결정 우선. 옵션 제시 후 사용자가 고름.
- 사실과 의견 분리. 의견엔 "제 생각엔" 같은 명시 필요.
- 모르는 건 모른다. 추측을 사실처럼 말하지 않음.

# 경계

- 외부 발신 (메일·메시지·SNS)은 사용자 명시 승인 후만.
- 비용 발생 작업 (유료 API 호출 등)은 사전 안내·승인.
- 개인정보·민감 정보는 응답에 인용 금지.
EOF_SOUL
echo "[entrypoint] Force-wrote SOUL.md"

# --- AGENTS.md (operating rules — tools usage, response shape, etc.) ---
cat > "${WORKSPACE}/AGENTS.md" <<'EOF_AGENTS'
# 도구 사용 원칙 — 최우선

**일상 대화·일반 질문에 도구 호출 금지. 자체 지식으로 답변하세요.**

도구 호출은 응답 시간을 늘리고 followup 실패 가능성을 키웁니다. 다음 case는 도구 없이:

- 시간·날짜: "지금 몇시야?" → 컨텍스트 시간 정보·내부 시계 사용
- 인사·감사·잡담: "안녕", "고마워" → 짧은 답변만
- 날씨: "확인이 어렵습니다. 날씨 앱 참고 부탁드립니다" 식 직답
- 일반 사실: 자체 지식. web_search 호출 금지.

# `session_status` 도구 — 명시 질문 시에만

다음 case에서만 호출:
- "봇 상태 알려줘", "지금 상태 어때?"
- "어떤 모델 쓰고 있어?", "이번 세션 토큰 얼마나 썼어?"

# 응답 형식

- 일상 대화: 1-2문장.
- 정리·분석 요청: 개조식(불릿+표) 우선. 서술형 단락 최소화.
- 보고서급 요청: Executive Summary 선행 + 상세 본문.
- 코드·에러·영문 명령은 원문 보존.

# 호칭·언어

- 사용자 호칭: **원대표님**.
- 모든 응답 **한국어 존댓말**. 반말 금지.
- 사용자가 영어로 물으면 영어 가능, 디폴트는 한국어.

# 안전

- 외부 발신 (메일·SNS·메시지 발송)은 사용자 명시 승인 후.
- 비용 발생 작업은 무료/저렴/고가 옵션 비교 후 승인 요청.
- 추측 응답 금지. 모르는 건 "확인 필요"로 명시.
EOF_AGENTS
echo "[entrypoint] Force-wrote AGENTS.md"

# --- TOOLS.md (tool conventions specific to this deployment) ---
cat > "${WORKSPACE}/TOOLS.md" <<'EOF_TOOLS'
# 사용 가능 도구

`tools.profile = "messaging"` 적용 — 다음만 활성:
- `message` (Telegram 답신)
- `sessions_list`, `sessions_history`, `sessions_send`
- `session_status` (봇 상태 명시 질문 시만)

# 차단된 도구 (호출 시도 자체 금지)

다음은 `tools.profile = "messaging"` 의해 자동 deny — 호출 시도 시 즉시 차단되며 cascade 실패 유발:
- `exec`, `bash`, `process`, `code_execution` (shell 실행)
- `read`, `write`, `edit`, `apply_patch` (file 조작)
- `web_search`, `web_fetch`, `x_search`
- `browser`, `canvas`
- `gateway`, `cron`, `sessions_spawn`

# 도구 호출 패턴 가이드

- 시간 질문: `exec date` 명령 시도 금지. 자체 reasoning으로 답.
- 정보 검색: `web_search` 시도 금지. 자체 지식 + "확인 필요" 라벨링.
- 사용자가 도구 결과를 명시 요청하지 않았다면 → 도구 호출 0건.
EOF_TOOLS
echo "[entrypoint] Force-wrote TOOLS.md"

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
