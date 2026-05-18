#!/bin/sh
# Railway entrypoint — generate openclaw.json from env vars before starting gateway
# v0.4 (2026-05-18) — docs.openclaw.ai 전수 audit 반영 (P0+P1+P2 일괄 적용)
#
# Why: Railway containers have no SSH access and no file browser. openclaw.json
# must be created in the persistent volume (/data/.openclaw/) before gateway starts.
# This script regenerates openclaw.json on every boot from current env vars.
#
# v0.4 changes (docs.openclaw.ai full audit RCA):
#   - workspace: MEMORY.md 신규 추가 (long-term curated facts auto-load)
#   - agents.defaults: userTimezone / envelopeTimezone / timeFormat / heartbeat=0m
#   - session: dmScope / threadBindings 명시
#   - tools: fs.workspaceOnly / exec.security=deny / elevated.enabled=false 명시
#   - gateway: 미명시 (Dockerfile CMD `--allow-unconfigured --bind lan`이 처리.
#     entrypoint.sh에서 auth.mode=none 명시 시 explicit security violation 거부 발생,
#     2026-05-18 commit 655aea1d deploy 실패 RCA)
#   - logging: redactSensitive=tools
#   - cron / hooks: 명시 disable (Hermes 외부 처리 중)
#   - update: checkOnStart=false (Railway redeploy마다 의미 없음)
#   - channels.telegram: errorPolicy / errorCooldownMs / historyLimit / commands.native
#   - mcp: placeholder (servers: {}) — 향후 Google Workspace + MS Office 365 통합 예정
#     상세 가이드: wiki/projects/openclaw-personal-bot.md §MCP 추가 가이드
#
# References (verified 2026-05-18):
#   - docs.openclaw.ai/gateway/configuration-reference
#   - docs.openclaw.ai/concepts/timezone
#   - docs.openclaw.ai/gateway/heartbeat
#   - docs.openclaw.ai/concepts/agent-workspace
#   - docs.openclaw.ai/concepts/memory
#   - docs.openclaw.ai/channels/telegram

set -e

CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-/data/.openclaw}"
CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-${CONFIG_DIR}/openclaw.json}"

# Sandbox mode default: off (Railway/PaaS containers have no Docker CLI for nested sandboxing)
SANDBOX_MODE="${OPENCLAW_SANDBOX_MODE:-off}"

# mDNS/Bonjour discovery disabled — Railway 환경에서 불필요 (외부 노출 0)
export OPENCLAW_DISABLE_BONJOUR=1

mkdir -p "${CONFIG_DIR}"
mkdir -p "${OPENCLAW_WORKSPACE_DIR:-/data/workspace}"
mkdir -p "${OPENCLAW_AUTH_PROFILE_SECRET_DIR:-/data/.openclaw-secrets}"

# Delete BOOTSTRAP.md if present (per docs/concepts/agent.md).
# BOOTSTRAP.md is a one-time first-run ritual — should be deleted after completion.
BOOTSTRAP_PATH="${OPENCLAW_WORKSPACE_DIR:-/data/workspace}/BOOTSTRAP.md"
if [ -f "${BOOTSTRAP_PATH}" ]; then
  rm -f "${BOOTSTRAP_PATH}"
  echo "[entrypoint] Removed BOOTSTRAP.md (one-time ritual completed)"
fi

# Force-write 6 workspace files per docs.openclaw.ai/concepts/agent-workspace.
# All injected into Project Context on first session turn (loaded every session).
# Manual edits will be overwritten on next deploy — edit these heredocs instead.
#
# Native parse per docs (concepts/agent-workspace):
#   IDENTITY.md  — agent name/vibe/emoji
#   USER.md      — user profile + preferred address
#   SOUL.md      — persona, tone, boundaries
#   AGENTS.md    — operating instructions
#   TOOLS.md     — user-maintained tool notes/conventions
#   MEMORY.md    — long-term curated facts (auto-load on main session start)
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

# --- SOUL.md (persona/tone/boundaries) ---
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

# --- AGENTS.md (operating rules) ---
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

다음은 `tools.profile = "messaging"` + 추가 deny 정책으로 자동 차단:
- `exec`, `bash`, `process`, `code_execution` (shell 실행 — `tools.exec.security: "deny"`)
- `read`, `write`, `edit`, `apply_patch` (file 조작 — `tools.fs.workspaceOnly: true`)
- `web_search`, `web_fetch`, `x_search`
- `browser`, `canvas`
- `gateway`, `cron`, `sessions_spawn`

# 도구 호출 패턴 가이드

- 시간 질문: `exec date` 명령 시도 금지. 자체 reasoning으로 답.
- 정보 검색: `web_search` 시도 금지. 자체 지식 + "확인 필요" 라벨링.
- 사용자가 도구 결과를 명시 요청하지 않았다면 → 도구 호출 0건.
EOF_TOOLS
echo "[entrypoint] Force-wrote TOOLS.md"

# --- MEMORY.md (long-term curated facts, auto-load on main session start) ---
# Per docs.openclaw.ai/concepts/memory: "MEMORY.md — Curated long-term memory, loads at every session start"
cat > "${WORKSPACE}/MEMORY.md" <<'EOF_MEMORY'
# 영구 사실 (Long-term Facts)

## 사용자

- 본명: 원대로 (Won Daero) — 영문 표기 Won Daero / drwon
- 호칭: **원대표님** (모든 응답에 사용)
- 시간대: Asia/Singapore (UTC+8)
- 응답 언어: 한국어 (존댓말 ~합니다/~입니다)

## 조직

- 회사: WVB (Wilt Venture Builder Pte. Ltd, 싱가포르 법인)
- 직책: Founder & CEO
- 자회사: POPUP Studio, Zero100, 해녀의부엌(제주 F&B)
- 운영 모델: AI Native 기반 1인 multiplier

## 비서·에이전트 컨텍스트

- 본 비서 (드원클로 / drwon claw): 개인 Telegram bot, openclaw framework + OpenRouter + Railway 배포
- 별도 비서 (김실장 / Chief of Staff): 사내 운영·biz list·캘린더·이메일 통합 (별도 시스템)
- 두 비서는 분리 — 본 비서는 *개인 Telegram 대화* 전용

## 의사결정 선호

- Trusted Advisor 톤: 따뜻하되 솔직, 우려 명시
- 아첨 금지: "물론이죠!" / "좋은 질문!" / 과잉 감탄 0건
- 답변 형식: 1-2문장 간결 우선, 보고서급 요청 시 Executive Summary 선행
- 옵션 제시 후 사용자가 결정. 먼저 결론 내지 않음.

## 환경 사실

- 배포: Railway PaaS (openclaw-personal-bot-production.up.railway.app)
- 모델 chain: OpenRouter 경유 — DeepSeek V4 Flash(primary) → Flash:free → V4 Pro → Anthropic Haiku 4.5
- Heartbeat: disabled (every: "0m")
- Tools profile: messaging (shell/fs/web 차단)
EOF_MEMORY
echo "[entrypoint] Force-wrote MEMORY.md"

# Build telegram channel block conditionally on TELEGRAM_BOT_TOKEN presence
# Includes: errorPolicy, errorCooldownMs, historyLimit, commands.native (P1 audit additions)
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
          "label": "생각 중...",
          "toolProgress": false
        }
      },
      "errorPolicy": "reply",
      "errorCooldownMs": 60000,
      "historyLimit": 50,
      "dmHistoryLimit": 50,
      "commands": {
        "native": "auto"
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
          "label": "생각 중...",
          "toolProgress": false
        }
      },
      "errorPolicy": "reply",
      "errorCooldownMs": 60000,
      "historyLimit": 50,
      "dmHistoryLimit": 50,
      "commands": {
        "native": "auto"
      }
    }'
  fi
else
  TELEGRAM_BLOCK=''
fi

# Build agents.defaults.model block from OPENROUTER_API_KEY presence
# CHAIN: deepseek-v4-flash → :free → v4-pro → anthropic/claude-haiku-4.5
# Verified 2026-05-17 against https://openrouter.ai/api/v1/models
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

# Full openclaw.json with P0+P1+P2 audit results applied
# Schema reference: https://docs.openclaw.ai/gateway/configuration-reference
cat > "${CONFIG_PATH}" <<EOF
{
  "\$schema": "https://docs.openclaw.ai/schemas/openclaw.schema.json",
  ${CHANNELS_OBJ}
  "agents": {
    "defaults": {
      ${MODEL_BLOCK}
      "thinkingDefault": "medium",
      "userTimezone": "Asia/Singapore",
      "envelopeTimezone": "Asia/Singapore",
      "timeFormat": "24h",
      "heartbeat": {
        "every": "0m"
      },
      "sandbox": {
        "mode": "${SANDBOX_MODE}"
      }
    }
  },
  "session": {
    "dmScope": "per-channel-peer",
    "threadBindings": {
      "enabled": true,
      "idleHours": 24
    }
  },
  "tools": {
    "profile": "messaging",
    "fs": {
      "workspaceOnly": true
    },
    "exec": {
      "security": "deny",
      "ask": "always"
    },
    "elevated": {
      "enabled": false
    }
  },
  "logging": {
    "level": "info",
    "redactSensitive": "tools"
  },
  "cron": {
    "enabled": false
  },
  "hooks": {
    "enabled": false
  },
  "update": {
    "checkOnStart": false
  },
  "mcp": {
    "sessionIdleTtlMs": 600000,
    "servers": {}
  }
}
EOF

echo "[entrypoint] Generated openclaw.json at ${CONFIG_PATH}"
echo "[entrypoint] Telegram channel: $([ -n "${TELEGRAM_BOT_TOKEN:-}" ] && echo enabled || echo disabled)"
echo "[entrypoint] OpenRouter: $([ -n "${OPENROUTER_API_KEY:-}" ] && echo enabled || echo disabled)"
echo "[entrypoint] DM policy: $([ -n "${OPENCLAW_DRWON_TELEGRAM_ID:-}" ] && echo allowlist || echo pairing)"
echo "[entrypoint] Sandbox mode: ${SANDBOX_MODE}"
echo "[entrypoint] Heartbeat: disabled (every=0m)"
echo "[entrypoint] Timezone: Asia/Singapore"
echo "[entrypoint] mDNS/Bonjour: disabled"
echo "[entrypoint] MCP: ready (servers: empty — add Google Workspace / MS365 via mcp.servers in this script)"

exec "$@"
