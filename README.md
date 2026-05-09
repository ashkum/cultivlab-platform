# CultivLab Platform

A self-deployable, multi-tenant AI platform. The first use case is a **kids' AI literacy lab**:
a 3-week cohort for ages 8–12 where students chat with frontier LLMs, write code with AI
assistance, and deploy static websites to their own public URLs.

Any operator with a GCP account, a domain, and provider API keys can run their own instance.

---

## What students do

1. Chat with Claude, ChatGPT, or Gemini at `https://chat.${DOMAIN}`
2. Install VS Code + Continue.dev locally and configure it with their virtual API key
3. Edit a starter web project (HTML, CSS, JS) on their own laptop
4. Preview locally with Live Server
5. Deploy their site with `./deploy.sh` — live at `https://<their-slug>.${DOMAIN}`
6. Iterate over 3 weeks, demo on the last day

## What the operator does

Stand up the platform, provision student accounts and budgets, monitor daily usage, top up
budgets as needed, and run the cohort cleanup at the end. The Founder Console at
`https://founder.${DOMAIN}` provides a single-page view with pause/resume/top-up controls
for every student.

---

## Architecture (Sprint 0 — nothing built yet)

```
chat.${DOMAIN}      → Open WebUI       (student chat UI)
api.${DOMAIN}       → LiteLLM proxy    (virtual keys, budgets, all LLM calls)
admin.${DOMAIN}     → LiteLLM admin    (operator, IP-locked)
founder.${DOMAIN}   → Founder Console  (operator, IP-locked)
<slug>.${DOMAIN}    → Firebase Hosting (12 student static sites)
```

All services run as Docker Compose containers on a single GCP e2-small VM. Caddy handles
HTTPS automatically. Postgres is the single database for LiteLLM, Open WebUI, and the
Founder Console.

See `docs/architecture.md` for the current state diagram and decision log.

---

## 5-minute quickstart (placeholder — real steps in Sprint 1)

> **Sprint 0 only — no infrastructure exists yet.** The quickstart below is the intended
> flow; actual scripts are built in Sprint 1.

```bash
# 1. Clone and configure
git clone <repo-url>
cd cultivlab-platform
cp .env.example .env
# Edit .env — fill in REQUIRED values

# 2. Install pre-commit hooks
pre-commit install

# 3. (Sprint 1+) Provision GCP infrastructure
# ./scripts/gcp-bootstrap.sh

# 4. (Sprint 1+) Bootstrap the VM
# ./scripts/bootstrap.sh

# 5. (Sprint 3+) Provision a student cohort
# ./scripts/provision-cohort.sh --dry-run
# ./scripts/provision-cohort.sh
```

Full step-by-step instructions: `docs/install.md`

---

## Repository layout

```
cultivlab-platform/
├── README.md                    # this file
├── CLAUDE.md                    # AI agent context (read every session)
├── .env.example                 # all env vars, every sprint
├── docs/
│   ├── PROJECT_BRIEF.md         # live project state (update each sprint)
│   ├── DECISION_LOG.md          # architecture decision records (ADR-001–010)
│   ├── install.md               # full operator deployment guide
│   ├── architecture.md          # current state diagram
│   ├── operations.md            # backup, restore, upgrade runbook
│   ├── student-onboarding.md    # what students do on their laptops
│   └── security.md              # secrets, consent, moderation, retention
├── infra/                       # Docker Compose, Caddy, LiteLLM config (Sprint 1+)
├── scripts/                     # bootstrap, provision, cleanup scripts (Sprint 1+)
├── services/                    # Founder Console and other services (Sprint 5.5+)
├── student-starter/             # starter project distributed to students (Sprint 4+)
├── templates/                   # onboarding card, consent letter, curriculum
├── tests/                       # smoke tests and isolation tests
└── .github/workflows/           # CI: lint, secret scan
```

---

## Current version

**v0.0.1** — Sprint 0 (repository scaffold only). Nothing runs yet.

Next: Sprint 1 — GCP foundation, VM provisioning, Caddy, Postgres, LiteLLM.

See `CHANGELOG.md` for full version history.

---

## Cost

| Phase | Monthly cost |
|---|---|
| Platform idle (no students) | ~$20–25 |
| During a 12-student cohort | ~$50–150 |

Hard budget controls are enforced at three layers: per-student, cohort-wide, and per provider
master account. See `docs/operations.md` for the cost control runbook.

---

## License

Apache 2.0 — see `LICENSE`.
