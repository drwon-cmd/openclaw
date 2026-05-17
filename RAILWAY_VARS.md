# Railway 배포용 환경변수 가이드

> drwon-cmd/openclaw fork — Personal assistant (원대표)
> Plan v0.3 (2026-05-17) §5 Phase 2 기준
> 실제 secrets는 Railway 대시보드 → Variables 탭에 직접 입력

## Volume mount (Railway 단일 volume 제약)

Railway는 service당 단일 volume만 지원. render.yaml 패턴 차용해서 모든 openclaw 데이터를 `/data` 안에 격리:

```
/data/
├── .openclaw/           ← OPENCLAW_STATE_DIR + CONFIG_DIR (config, openclaw.json)
├── workspace/           ← OPENCLAW_WORKSPACE_DIR (SOUL.md/USER.md/skills/memory)
└── .openclaw-secrets/   ← OPENCLAW_AUTH_PROFILE_SECRET_DIR (encryption keys)
```

**Railway 대시보드 설정**:
- Service Settings → Volumes → New Volume
- Mount path: `/data`
- Size: **5GB** (Hobby plan max — Plan §4 Q1 결정)

## Phase 2 필수 환경변수 (첫 배포)

| Variable | Value | 근거 |
|----------|-------|------|
| `OPENCLAW_GATEWAY_TOKEN` | (랜덤 32바이트) | 필수. `openssl rand -hex 32` 또는 Railway "generateValue" 사용 |
| `OPENCLAW_GATEWAY_PORT` | `8080` | render.yaml L651 패턴, Railway 관례 |
| `OPENCLAW_TZ` | `Asia/Singapore` | drwon-advisory와 동일 |
| `OPENCLAW_STATE_DIR` | `/data/.openclaw` | render.yaml L652 |
| `OPENCLAW_CONFIG_DIR` | `/data/.openclaw` | docker-compose.yml L496 |
| `OPENCLAW_CONFIG_PATH` | `/data/.openclaw/openclaw.json` | docker-compose.yml L495 |
| `OPENCLAW_WORKSPACE_DIR` | `/data/workspace` | render.yaml L654 |
| `OPENCLAW_AUTH_PROFILE_SECRET_DIR` | `/data/.openclaw-secrets` | docker-compose.yml L520 |
| `HOME` | `/home/node` | docker-compose.yml L485 |
| `OPENCLAW_HOME` | `/home/node` | docker-compose.yml L486 |
| `DOCKER_BUILDKIT` | `1` | Dockerfile cache mount 사용 |
| `NODE_OPTIONS` | `--max-old-space-size=2048` | Dockerfile L78 |
| `NODE_ENV` | `production` | fly.toml L617 |

## Phase 3 환경변수 (Telegram channel — 배포 후 추가)

```
TELEGRAM_BOT_TOKEN=<BotFather에서 /newbot로 발급>
```

BotFather (@BotFather Telegram) → `/newbot` → 봇 이름·username 설정 → 토큰 발급 → Railway env에 추가.

## Phase 4 환경변수 (OpenRouter — 모델 라우팅)

```
OPENROUTER_API_KEY=sk-or-...
```

발급: https://openrouter.ai/keys
**Plan §4 Q3 결정**: 일일 hard limit **$2** (OpenRouter 대시보드 Settings → Limits)

(선택) Anthropic 직접 사용 시 — OpenRouter 5% 수수료 회피:
```
ANTHROPIC_API_KEY=sk-ant-...
```

## Phase 5 환경변수 (Security/Observability — 선택)

```
OTEL_EXPORTER_OTLP_ENDPOINT=<없으면 미설정>
OTEL_SERVICE_NAME=openclaw-drwon-personal
```

## 참고 — railway.json (이 repo root)

- `build.builder=DOCKERFILE` + `dockerfilePath=Dockerfile`
- `deploy.startCommand`: `node dist/index.js gateway --allow-unconfigured --port 8080 --bind lan`
  - `--allow-unconfigured`: fly.toml L624 패턴 (초기 setup 없이 gateway 띄움)
  - `--port 8080`: Railway proxy가 EXPOSE PORT 사용
  - `--bind lan`: docker-compose.yml L550 default
- `deploy.healthcheckPath`: `/healthz` (openclaw docker-compose.yml L558)
- `deploy.healthcheckTimeout`: 300초 (Railway default)
- `deploy.restartPolicyType`: `ON_FAILURE`, max 5회 (무한 재시작 방지)
