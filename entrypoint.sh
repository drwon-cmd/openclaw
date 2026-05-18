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

# 🚨 CRITICAL: openclaw process가 env var을 inherit하려면 *export* 필수.
# shell `${VAR:-default}` 패턴은 shell variable만 set, child process는 못 봄.
# Source: src/agents/workspace-default.ts:7-13
#   env.OPENCLAW_WORKSPACE_DIR?.trim() || path.join(home, ".openclaw", "workspace")
# Docker base node:24-bookworm-slim의 root user HOME=/root → default /root/.openclaw/workspace
# 우리는 /data/workspace에 workspace 파일 force-write → export로 openclaw에 알려야 함
export OPENCLAW_WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-/data/workspace}"

# Sandbox mode default: off (Railway/PaaS containers have no Docker CLI for nested sandboxing)
# Reference: docker-compose.yml comment "Sandbox isolation requires Docker CLI in the image
#            (build with --build-arg OPENCLAW_INSTALL_DOCKER_CLI=1)"
# Override: set OPENCLAW_SANDBOX_MODE=non-main|all only when running on self-hosted with docker.sock
SANDBOX_MODE="${OPENCLAW_SANDBOX_MODE:-off}"

mkdir -p "${CONFIG_DIR}"
mkdir -p "${OPENCLAW_WORKSPACE_DIR}"
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
# 도구 사용 원칙 — 적극 활용

**openclaw의 full agent 활용도를 살리기 위해 도구를 적극 사용합니다.**
`tools.profile = "full"` + Elevated allowlist [drwon] 적용 — 모든 빌트인 도구
사용 가능하며 exec 계열 위험 도구는 자동으로 사용자 승인 단계 거칩니다.

# 활용 권장 — 도구 호출이 응답 품질을 높이는 case

- 시간·날짜·정확한 정보: `exec date`, web_search 등 활용
- 웹 정보 조회: web_search, web_fetch — 최신·구체 사실 필요 시
- 파일·문서 처리: read/write/edit — 사용자가 파일 공유·요청 시
- 이미지 생성: image_generate — 사용자가 명시 요청 시
- 코드 실행: exec, bash — *Elevated 승인 후* 사용
- 봇 자기 상태: session_status — 명시 질문 시
- 세션 히스토리: sessions_history, sessions_list — 사용자 요청 시
- 음성·이미지·파일 첨부 처리: Telegram 채널이 자동 처리

# Elevated (위험 도구) 사용 패턴

- exec/bash 등 호스트 실행 도구는 `tools.elevated.enabled = true` +
  `allowFrom.telegram = [drwon]` 안전망 적용됨
- Telegram에서 `/elevated on` 으로 세션 단위 허용 가능,
  `/elevated ask` 로 매번 확인 가능
- Railway 환경에선 sandbox=off (Docker CLI 부재) — Elevated 승인이 유일 안전망

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
- exec 계열 호출 시 Elevated 승인 자동 트리거 — 의도 명시.
EOF_AGENTS
echo "[entrypoint] Force-wrote AGENTS.md"

# --- TOOLS.md (tool conventions specific to this deployment) ---
cat > "${WORKSPACE}/TOOLS.md" <<'EOF_TOOLS'
# 활성 도구 — `tools.profile = "full"` (No restriction)

openclaw 모든 빌트인 도구 사용 가능. docs.openclaw.ai 공식 권장 = power user
profile. Railway 환경 + Elevated allowlist [drwon] 안전망으로 운용.

# 도구 그룹 (full profile)

- `group:messaging` — Telegram 답신, send, 채널 인터랙션
- `group:sessions` — sessions_list, sessions_history, sessions_send, sessions_spawn
- `group:memory` — memory_search, memory_get, memory write
- `group:fs` — read, write, edit, apply_patch (파일 조작)
- `group:runtime` — exec, bash, process, code_execution (호스트 실행 ⚠️ Elevated 필요)
- `group:web` — web_search, web_fetch, x_search (웹 조회)
- `cron` — 정기 작업 스케줄링
- `image`, `image_generate`, `video_generate` — 멀티미디어 생성
- `session_status` — 봇 상태 조회

# Elevated 안전망 (Railway sandbox=off 보완)

Railway 컨테이너는 Docker CLI 없어 sandbox=all 불가 → exec 시도는 호스트에서
직접 실행됨. 그 위험을 `tools.elevated`로 보완:

- `tools.elevated.enabled = true`
- `tools.elevated.allowFrom.telegram = ["${OPENCLAW_DRWON_TELEGRAM_ID}"]`
- → drwon 외 발신자는 exec 시도해도 거부됨
- → drwon이라도 exec 시점에 confirmation 단계 거침 (`/elevated ask` 모드)

# Telegram 슬래시 명령 (docs 명시)

- `/elevated on|off|ask|full` — 세션 단위 elevated 상태 토글
- `/activation always|mention` — 그룹 채팅 trigger 모드 (DM은 기본 always)
- `/pair` — device-pair 플러그인 (현재 차단 안 됨)
- `/new` — 새 세션 시작 (세션 컨텍스트 리셋)

# 도구 호출 가이드

- 정확한 정보 필요 시 web_search·exec date 등 적극 활용
- 사용자가 파일·이미지 공유하면 자동 처리 (file-transfer, image)
- 음성 메시지는 talk-voice 플러그인이 자동 전사 (untrusted text로 framing)
- exec 시도 시 사용자 명시 의도 확인 — "혹시 호스트에서 이 명령 실행할까요?" 식
EOF_TOOLS
echo "[entrypoint] Force-wrote TOOLS.md"

# --- MEMORY.md (force-write baseline — prevents auto-distilled cruft override) ---
# Reason (2026-05-18 RCA):
#   openclaw memory-core dreaming sweep auto-writes MEMORY.md based on conversation.
#   docs.openclaw.ai/concepts/memory.md: "Dreaming promotes only qualified items into
#   long-term memory (MEMORY.md)" + "OpenClaw runs a silent turn that reminds the agent
#   to save important context to memory files" before compaction.
#   MEMORY.md is loaded as 8th (last) Project Context file per
#   docs.openclaw.ai/concepts/system-prompt.md — meaning it can override IDENTITY/SOUL.
#
#   When workspace was incomplete (pre-8b59b19c), agent saved "user persona undefined"
#   state to MEMORY.md (1435 bytes, 2026-05-18 03:30). This evergreen file then
#   overrode IDENTITY.md/SOUL.md on every subsequent session → bot kept asking
#   "what is my name?" in BOOTSTRAP-style ritual even after persona files were seeded.
#
#   Fix: force-write MEMORY.md to compact baseline on every boot. Agent may still
#   append via silent-save during a session, but next boot resets to baseline.
#   Trade-off: long-term memory accumulation is wiped per deploy (acceptable until
#   dreaming behavior is tuned — see follow-up).

# Log previous MEMORY.md content for RCA archaeology (force-write below overwrites)
if [ -f "${WORKSPACE}/MEMORY.md" ]; then
  echo "[entrypoint] [RCA] MEMORY.md content BEFORE force-write reset:"
  sed 's/^/  PREV: /' "${WORKSPACE}/MEMORY.md"
  echo "[entrypoint] [RCA] /PREV end"
fi

cat > "${WORKSPACE}/MEMORY.md" <<'EOF_MEMORY'
# Project Context (baseline — entrypoint.sh가 매 boot 초기화)

본 파일은 매 deploy boot 시 force-write됩니다. 자동 누적 메모리가 IDENTITY/SOUL을
override해서 페르소나 혼란 유발하는 사고 방지 (RCA 2026-05-18: BOOTSTRAP-style 응답).

## 사용자
- 호칭: **원대표님** (본명 원대로 / 회사 ID drwon) — WVB CEO
- 응답 언어: **한국어 존댓말** (~합니다/~입니다/~예요). 반말 절대 금지.
- Timezone: Asia/Singapore (UTC+8)

## 에이전트
- 이름: **드원클로** (drwon claw) — 원대표 개인 AI 비서
- 시그니처 이모지: 🦀 (정체성 표지. 메시지 본문 도배 금지)
- Vibe: 짧고 핵심만. 아첨·과잉 칭찬 0건. 추측 시 "확인 필요" 라벨링.

## 운영 룰
- `tools.profile = "full"` — 모든 빌트인 도구 활성 (web/fs/exec/image/cron 등).
- exec 계열은 `tools.elevated.allowFrom.telegram = [drwon]` 안전망 + confirmation 필요.
- 외부 발신·비용 발생 작업·exec 실행은 사용자 명시 승인 후에만.
- 정확한 정보 필요 시 web_search·exec date 등 적극 활용.
EOF_MEMORY
echo "[entrypoint] Force-wrote MEMORY.md (baseline reset — RCA 2026-05-18)"

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
# FINAL CHAIN v2 — multi-vendor resilience (2026-05-18):
#   1. deepseek/deepseek-chat (V3) — primary. $0.32/M in, $0.89/M out.
#      Stable global #2 pick rate. Separate infra from V4 (which had 500 cascade).
#   2. qwen/qwen3-235b-a22b-2507 — Qwen3 latest 235B. $0.07/M in, $0.10/M out.
#      Best open-weight tool-calling, extremely cheap.
#   3. google/gemini-3.1-flash-lite — proven safety net. $0.25/M in, $1.5/M out.
#   4. qwen/qwen3-coder:free — FREE last resort. 1M context.
#
#   Replaces V4-only chain that had full 500 cascade (all 3 DeepSeek V4 models
#   returning HTTP 500 simultaneously on OpenRouter, 2026-05-18).
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
  MODEL_BLOCK='"model": {
        "primary": "openrouter/deepseek/deepseek-chat",
        "fallbacks": [
          "openrouter/qwen/qwen3-235b-a22b-2507",
          "openrouter/google/gemini-3.1-flash-lite",
          "openrouter/qwen/qwen3-coder:free"
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

# Build tools.elevated block (Railway sandbox=off → exec confirmation via Elevated)
# Reference: docs.openclaw.ai/gateway/sandbox-vs-tool-policy-vs-elevated.md
#   "Elevated is an exec-only escape hatch" + allowFrom.<provider>=[user_id_strings]
# Reference: docs.openclaw.ai/gateway/config-tools.md
#   tools.profile = "full" → "No restriction (same as unset)"
# Reason (2026-05-18 사용자 B' 결정): messaging profile은 openclaw의 본래 의도
#   (full agent platform with 8 plugins)를 1/4로 축소했음. 사용자 명시 결정으로
#   full + Elevated [drwon] 안전망 구성으로 전환. Railway Docker CLI 부재로
#   sandbox=all 불가 → Elevated가 유일 안전망.
if [ -n "${OPENCLAW_DRWON_TELEGRAM_ID:-}" ]; then
  ELEVATED_BLOCK='"elevated": {
      "enabled": true,
      "allowFrom": {
        "telegram": ["'"${OPENCLAW_DRWON_TELEGRAM_ID}"'"]
      }
    }'
else
  # Telegram ID 미설정 시 elevated 비활성 — 안전 디폴트
  ELEVATED_BLOCK='"elevated": {
      "enabled": false
    }'
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
    "profile": "full",
    ${ELEVATED_BLOCK}
  }
}
EOF

echo "[entrypoint] Generated openclaw.json at ${CONFIG_PATH}"
echo "[entrypoint] Telegram channel: $([ -n "${TELEGRAM_BOT_TOKEN:-}" ] && echo enabled || echo disabled)"
echo "[entrypoint] OpenRouter: $([ -n "${OPENROUTER_API_KEY:-}" ] && echo enabled || echo disabled)"
echo "[entrypoint] DM policy: $([ -n "${OPENCLAW_DRWON_TELEGRAM_ID:-}" ] && echo allowlist || echo pairing)"
echo "[entrypoint] Sandbox mode: ${SANDBOX_MODE}"
echo "[entrypoint] OPENCLAW_WORKSPACE_DIR=${OPENCLAW_WORKSPACE_DIR} (exported)"
echo "[entrypoint] workspace contents:"
ls -la "${OPENCLAW_WORKSPACE_DIR}" 2>&1 | sed 's/^/  /'

# 🔬 DIAGNOSTIC (2026-05-18) — MEMORY.md 자동 생성 추정. 내용 확인 후 제거 예정.
# Reason: workspace에 entrypoint가 만들지 않은 MEMORY.md 1435 bytes 존재 (timestamp 03:30,
# deploy 03:51보다 앞섬). docs.openclaw.ai/concepts/system-prompt.md에 따르면 MEMORY.md는
# Project Context 8번째 (마지막) 적재 = IDENTITY/SOUL override 가능.
if [ -f "${OPENCLAW_WORKSPACE_DIR}/MEMORY.md" ]; then
  echo "[entrypoint] [DIAG] MEMORY.md content (auto-generated, investigating):"
  sed 's/^/  MEMORY: /' "${OPENCLAW_WORKSPACE_DIR}/MEMORY.md"
  echo "[entrypoint] [DIAG] MEMORY.md end"
else
  echo "[entrypoint] [DIAG] MEMORY.md not present"
fi

exec "$@"
