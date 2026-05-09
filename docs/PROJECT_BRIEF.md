# CultivLab Platform — Project Brief

**Living document. Update at the start of every sprint.**
Last updated: Sprint 1 — v0.1.0

---

## What it is

CultivLab is a self-deployable, multi-tenant AI platform. The first use case is a 3-week AI
literacy cohort for ages 8–12. Students chat with frontier LLMs (Claude, ChatGPT, Gemini),
write code with AI assistance in VS Code, and deploy static websites to personal subdomains.

Any operator with a GCP account, a domain, and provider API keys can clone this repo and run
their own instance.

---

## Live URLs

Sprint 1 deploys two of the five subdomains. The rest land in Sprints 3, 4, and 5.5.

| Subdomain | Service | Status |
|---|---|---|
| `chat.${DOMAIN}` | Open WebUI | Not deployed (Sprint 3) |
| `api.${DOMAIN}` | LiteLLM proxy | **Deployed** |
| `admin.${DOMAIN}` | LiteLLM admin UI | **Deployed** (IP-locked) |
| `founder.${DOMAIN}` | Founder Console | Not deployed (Sprint 5.5) |
| `<slug>.${DOMAIN}` | Student static sites | Not deployed (Sprint 4) |

---

## Stack

| Layer | Technology | Version | Sprint |
|---|---|---|---|
| Cloud | GCP (Compute Engine, Firebase Hosting) | — | Sprint 1 / 4 |
| VM | e2-small, Ubuntu 24.04 | — | Sprint 1 |
| Reverse proxy / TLS | Caddy | `${CADDY_VERSION}` | Sprint 1 |
| LLM gateway | LiteLLM Proxy | `${LITELLM_VERSION}` | Sprint 2 |
| Chat UI | Open WebUI | `${OPENWEBUI_VERSION}` | Sprint 3 |
| Database | Postgres (+ pgvector Sprint 4+) | `${POSTGRES_VERSION}` | Sprint 1 |
| Operator console | Founder Console (FastAPI + HTMX) | internal | Sprint 5.5 |
| Observability | Langfuse | `${LANGFUSE_VERSION}` | Sprint 4 |
| Container orchestration | Docker Compose (single VM) | — | Sprint 1 |
| LLM providers | Anthropic · OpenAI · Vertex AI Gemini | — | Sprint 2 |
| Student site hosting | Firebase Hosting | — | Sprint 4 |
| IDE AI assistant | Continue.dev (OpenAI-compatible) | — | Sprint 4 |

---

## Folder structure

```
cultivlab-platform/
├── CLAUDE.md                    # AI agent context
├── .env.example                 # all env vars, all sprints
├── docs/                        # documentation
│   ├── PROJECT_BRIEF.md         # this file
│   ├── DECISION_LOG.md          # ADRs
│   ├── CLAUDE_SYSTEM_PROMPT.md  # master session prompt
│   ├── SESSION_STARTER.md       # per-task context template
│   ├── install.md               # operator deployment guide
│   ├── architecture.md          # system diagrams
│   ├── operations.md            # backup/restore/upgrade
│   ├── student-onboarding.md    # student laptop setup
│   ├── security.md              # threat model, secrets
│   ├── runbooks/                # ops procedures
│   └── sprint-reports/          # per-sprint completion notes
├── infra/                       # Docker Compose, Caddy, LiteLLM (Sprint 1+)
├── scripts/                     # bootstrap, provision, cleanup (Sprint 1+)
├── services/                    # Founder Console, tool services (Sprint 5.5+)
├── student-starter/             # starter project for students (Sprint 4+)
├── templates/                   # onboarding card, consent letter, curriculum
├── tests/                       # smoke and isolation tests
└── .github/workflows/           # CI: lint, secret scan
```

---

## Data model

Nothing exists yet. Data model is introduced in Sprint 1 (Postgres schema) and Sprint 2
(LiteLLM virtual keys and spend logs).

Key tables (Sprint 1+):
- `LiteLLM_SpendLogs` — every LLM request with cost, model, user
- `LiteLLM_VerificationToken` — virtual keys with budgets and metadata
- `LiteLLM_TeamTable` — cohort-level team budget
- Open WebUI user and conversation tables (managed by Open WebUI)

---

## API routes

Nothing deployed yet. Expected routes (Sprint 2+):

| Route | Service | Auth |
|---|---|---|
| `GET /health` | LiteLLM | None |
| `POST /v1/chat/completions` | LiteLLM | Virtual key |
| `GET /v1/models` | LiteLLM | Virtual key |
| `POST /key/generate` | LiteLLM admin API | Master key |
| `POST /key/block` | LiteLLM admin API | Master key |
| `POST /key/update` | LiteLLM admin API | Master key |
| `GET /api/cohort/summary` | Founder Console | Founder auth |
| `POST /api/students/<slug>/pause` | Founder Console | Founder auth |

---

## Env vars

All env vars are documented in `.env.example` with REQUIRED/OPTIONAL markers and comments.
Reference that file — it is the single source of truth.

Core required vars: `DOMAIN`, `GCP_PROJECT_ID`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
`LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, `POSTGRES_PASSWORD`, `FOUNDER_ADMIN_EMAIL`,
`FOUNDER_ALLOWED_IP`, and five `SLACK_WEBHOOK_*` variables.

---

## Current version

**v0.1.0** — Sprint 1

Foundation deployed: GCP VM with static IP, Docker Compose stack of Caddy + LiteLLM +
Postgres + postgres-init, three providers wired (Anthropic, OpenAI, Vertex AI),
five Slack alert channels routed, IP-locked admin UI. No virtual keys, no Open WebUI,
no students yet — those land in Sprints 2 and 3.

---

## Version history

| Version | Sprint | Date | Summary |
|---|---|---|---|
| v0.0.1 | Sprint 0 | 2026-05-08 | Repository scaffold, all docs, 10 ADRs, CI baseline |
| v0.1.0 | Sprint 1 | 2026-05-09 | GCP VM + Caddy + LiteLLM + Postgres deployed; api.${DOMAIN}/health returns 200 |

---

## Known issues

None at Sprint 0. Issues are tracked in GitHub Issues.

---

## Next up — Sprint 2

**Goal:** Per-student virtual keys, three-layer budget caps wired in LiteLLM, daily/weekly
spend reports flowing to Slack. The platform shifts from "foundation up" to "ready to
take real traffic with budget protection."

Sprint 2 deliverables (preview — formal task brief at sprint start):
- `scripts/provision-cohort.sh` — generates virtual keys per student from `students.csv`
- LiteLLM team budgets configured (`COHORT_MAX_BUDGET`)
- Provider master-cap setup documented in `docs/install.md` §6
- Slack alert smoke test (one fake budget breach per channel)
- Sprint 2 sprint report
