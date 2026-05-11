# CultivLab — Architecture

**Current state: Sprint 1 — foundation deployed (Caddy, LiteLLM, Postgres on a single GCP VM).**
Update this document every sprint as new components are added.

---

## Current state diagram (Sprint 1)

```
                        Internet
                           │
              ┌────────────┴────────────┐
              │  api.${DOMAIN}          │
              │  admin.${DOMAIN}        │
              └────────────┬────────────┘
                           │
    ┌─────────────────────▼──────────────────────────┐
    │           GCP VM (e2-small, Ubuntu 24.04)       │
    │           Static external IP                    │
    │                                                 │
    │  ┌─────────────────────────────────────────┐   │
    │  │         Caddy (reverse proxy / TLS)     │   │
    │  │   api.*  admin.*                        │   │
    │  │   admin.* IP-locked via FOUNDER_ALLOWED_IP │ │
    │  └──────────────┬──────────────────────────┘   │
    │                 │                              │
    │  ┌──────────────▼──────────────────────────┐   │
    │  │  cultivlab-net (internal bridge)         │   │
    │  │                                          │   │
    │  │  ┌──────────────────────────────────┐   │   │
    │  │  │       LiteLLM Proxy :4000        │   │   │
    │  │  │  three providers wired in:       │   │   │
    │  │  │  Anthropic, OpenAI, Vertex AI    │   │   │
    │  │  │  Slack alerts → 5 channels       │   │   │
    │  │  └──────────────┬──────────────────┘   │   │
    │  │                 │                       │   │
    │  │  ┌──────────────▼─────────────────┐   │   │
    │  │  │    Postgres :5432              │   │   │
    │  │  │  LiteLLM_SpendLogs (auto-migrated)│ │   │
    │  │  └────────────────────────────────┘   │   │
    │  │  ┌──────────────────────────────────┐ │   │
    │  │  │  postgres-init (one-shot anchor) │ │   │
    │  │  └──────────────────────────────────┘ │   │
    │  └──────────────────────────────────────┘    │
    └─────────────────────────────────────────────────┘
                           │
              ┌────────────┴────────────┐
              │    LLM Providers        │
              │  (via LiteLLM only)     │
              │                         │
    ┌─────────▼──────┐  ┌──────▼───┐  ┌▼──────────────┐
    │  Anthropic API │  │OpenAI API│  │ Vertex AI     │
    │  (Claude)      │  │  (GPT)   │  │ (Gemini)      │
    └────────────────┘  └──────────┘  └───────────────┘
```

Open WebUI, Founder Console, and Firebase Hosting are not yet deployed — those land in Sprints 3,
5.5, and 4 respectively. The target architecture diagram below shows the end state.

---

## Target architecture (end of Sprint 5.5)

```
                        Internet
                           │
              ┌────────────┴────────────┐
              │       ${DOMAIN}         │
              │                         │
    ┌─────────▼──────────┐  ┌──────────▼──────────┐
    │  chat.${DOMAIN}    │  │  <slug>.${DOMAIN}   │
    │  (Open WebUI)      │  │  (Firebase Hosting) │
    └─────────┬──────────┘  └─────────────────────┘
              │                  12 student sites
              │                  HTTPS via Firebase
    ┌─────────▼──────────────────────────────────────┐
    │           GCP VM (e2-small, Ubuntu 24.04)       │
    │           Static external IP                    │
    │                                                 │
    │  ┌─────────────────────────────────────────┐   │
    │  │         Caddy (reverse proxy / TLS)     │   │
    │  │   chat.*  api.*  admin.*  founder.*     │   │
    │  └──────────────┬──────────────────────────┘   │
    │                 │ internal routing              │
    │  ┌──────────────▼──────────────────────────┐   │
    │  │  Docker Compose Network (cultivlab-net) │   │
    │  │                                         │   │
    │  │  ┌─────────────┐  ┌────────────────┐   │   │
    │  │  │  Open WebUI │  │ Founder Console│   │   │
    │  │  │  :3000      │  │ (FastAPI+HTMX) │   │   │
    │  │  │             │  │ :8080          │   │   │
    │  │  └──────┬──────┘  └───────┬────────┘   │   │
    │  │         │                 │             │   │
    │  │  ┌──────▼─────────────────▼────────┐   │   │
    │  │  │       LiteLLM Proxy :4000       │   │   │
    │  │  │  virtual keys · budgets ·       │   │   │
    │  │  │  spend logs · alerting          │   │   │
    │  │  └──────────────┬─────────────────┘   │   │
    │  │                 │                      │   │
    │  │  ┌──────────────▼─────────────────┐   │   │
    │  │  │    Postgres :5432              │   │   │
    │  │  │  LiteLLM tables · OpenWebUI    │   │   │
    │  │  │  tables · Founder Console audit│   │   │
    │  │  │  log · (pgvector Sprint 4+)    │   │   │
    │  │  └────────────────────────────────┘   │   │
    │  └─────────────────────────────────────────┘   │
    └─────────────────────────────────────────────────┘
                           │
              ┌────────────┴────────────┐
              │    LLM Providers        │
              │  (via LiteLLM only)     │
              │                         │
    ┌─────────▼──────┐  ┌──────▼───┐  ┌▼──────────────┐
    │  Anthropic API │  │OpenAI API│  │ Vertex AI     │
    │  (Claude)      │  │  (GPT)   │  │ (Gemini)      │
    └────────────────┘  └──────────┘  └───────────────┘
```

---

## Component inventory

| Component           | Purpose                                                                                                               | Deployed in Sprint                    | Status                                                   |
| ------------------- | --------------------------------------------------------------------------------------------------------------------- | ------------------------------------- | -------------------------------------------------------- |
| GCP VM (e2-small)   | Hosts core Docker Compose stack                                                                                       | Sprint 1                              | **Built**                                                |
| Caddy               | TLS termination, reverse proxy                                                                                        | Sprint 1                              | **Built**                                                |
| LiteLLM Proxy       | Unified LLM gateway, virtual keys, budgets                                                                            | Sprint 1 (deployed) / Sprint 2 (keys) | **Built**                                                |
| LiteLLM cohort team | Logical grouping in LiteLLM carrying `COHORT_MAX_BUDGET` / `COHORT_SOFT_BUDGET`; per-student virtual keys are members | Sprint 2                              | **Built** (provisioned by `scripts/provision-cohort.sh`) |
| Postgres            | Shared database for all services                                                                                      | Sprint 1                              | **Built**                                                |
| postgres-init       | One-shot anchor; future hook for extensions                                                                           | Sprint 1                              | **Built** (no-op)                                        |
| Open WebUI          | Student-facing chat interface                                                                                         | Sprint 3                              | Live ✅ (v0.3.0) at chat.${DOMAIN}                       |
| Founder Console     | Operator command center (FastAPI + HTMX)                                                                              | Sprint 5.5                            | Not built                                                |
| Firebase Hosting    | Student static site hosting                                                                                           | Sprint 4                              | Not built                                                |
| Langfuse            | Observability, tracing, evals                                                                                         | Sprint 4                              | Not built                                                |
| pgvector            | Vector storage for RAG                                                                                                | Sprint 4                              | Not built                                                |

---

## Network and DNS model

```
DNS registrar
  chat.${DOMAIN}     →  A  →  VM static IP
  api.${DOMAIN}      →  A  →  VM static IP
  admin.${DOMAIN}    →  A  →  VM static IP
  founder.${DOMAIN}  →  A  →  VM static IP

  <slug>.${DOMAIN}   →  CNAME  →  Firebase Hosting
                                   (one record per student)
```

Caddy handles TLS for the VM subdomains (Let's Encrypt HTTP-01 challenge). Firebase handles TLS for
student subdomains automatically.

---

## Access control model

| Subdomain           | Accessible by                      | Auth mechanism                            |
| ------------------- | ---------------------------------- | ----------------------------------------- |
| `chat.${DOMAIN}`    | Students (logged-in accounts only) | Open WebUI session                        |
| `api.${DOMAIN}`     | Students (via Continue.dev)        | LiteLLM virtual key                       |
| `admin.${DOMAIN}`   | Operator only                      | IP allowlist (Caddy) + LiteLLM master key |
| `founder.${DOMAIN}` | Operator only                      | IP allowlist (Caddy) + bcrypt password    |
| `<slug>.${DOMAIN}`  | Public (read-only)                 | None — static public site                 |

---

## Data flow — student chat request

```
Student browser
    │  HTTPS POST /api/chat/completions
    ▼
Open WebUI (chat.${DOMAIN})
    │  OpenAI-compatible POST to LiteLLM
    │  Header: Authorization: Bearer <cohort-shared-key>
    │  Body: { user: "<student-id>", messages: [...] }
    ▼
LiteLLM Proxy (api.${DOMAIN} or internal http://litellm:4000)
    │  Validates key, checks budgets (daily/weekly/total)
    │  Logs request to LiteLLM_SpendLogs
    │  Routes to provider based on model name
    ▼
Provider (Anthropic / OpenAI / Vertex AI)
    │  Response
    ▼
LiteLLM  →  Open WebUI  →  Student browser
```

---

## Data flow — student VS Code / Continue.dev

```
VS Code + Continue.dev
    │  OpenAI-compatible POST
    │  Header: Authorization: Bearer <student-virtual-key>
    ▼
LiteLLM Proxy (api.${DOMAIN})
    │  Key is student-specific → per-student budget enforced
    │  Logs with student metadata
    ▼
Provider
```

---

## Deferred components

These are explicitly NOT in the current build scope. They are captured here so architectural
thinking is not lost. Do not build any of these without a new PRD entry.

| Component                   | What it would do                           | Triggers for revisiting        |
| --------------------------- | ------------------------------------------ | ------------------------------ |
| pgvector + RAG              | Document-grounded Q&A per tenant           | SMB demand emerges post-cohort |
| Open WebUI Workspaces       | Per-tenant isolation in chat UI            | Multi-tenant demand emerges    |
| Postgres Row-Level Security | Hard DB-level tenant isolation             | Multi-tenant demand emerges    |
| Cloud Run tool services     | Per-tenant live data tools (CRM, calendar) | After RAG is validated         |
| Langfuse                    | Full observability and dataset-based evals | Sprint 4 / iteration 4         |
| Promptfoo eval suites       | Systematic model comparison                | After Langfuse is running      |
| Vertex AI fine-tuning       | Custom-tuned per-tenant models             | After evals validate need      |
| Stripe billing              | Automated tenant payments                  | At 10+ paying tenants          |
| AWS / Azure infra           | Cloud portability                          | If non-GCP operators appear    |
| Status page                 | Public uptime visibility for parents       | After first cohort             |

---

## Architecture decision records

All architecture decisions are recorded in `docs/DECISION_LOG.md`.

Summary:

- ADR-001: LiteLLM is the only LLM gateway
- ADR-002: Single VM + Docker Compose (not Kubernetes)
- ADR-003: Postgres is the only database
- ADR-004: Caddy for HTTPS
- ADR-005: Firebase Hosting for student sites (SUPERSEDED by ADR-013 — Caddy + VM filesystem with
  slot-based subdomains)
- ADR-006: Open WebUI for chat UI
- ADR-007: Continue.dev as in-IDE student AI
- ADR-008: Custom Founder Console for cohort operations
- ADR-009: Three-layer budget caps
- ADR-010: Slack as primary alerting channel
