# Sprint 0 — Completion Report

**Date:** 2026-05-08
**Version:** v0.0.1
**Status:** Complete

---

## Objective

Stand up the empty, well-organised GitHub repo with the complete engineering OS in place.
No infrastructure. No Docker. No cloud resources. Just the scaffold, documentation,
AI-agent configuration, and CI baseline. Anyone can clone this repo, read the full plan,
and understand exactly what gets built next.

---

## Every file created

### Repository root

| File | Purpose |
|---|---|
| `README.md` | Project overview, student/operator flow, architecture summary, quickstart placeholder |
| `LICENSE` | Apache 2.0 |
| `CONTRIBUTING.md` | Dev environment prerequisites, branch naming, commit format, code standards |
| `CHANGELOG.md` | `[Unreleased] — Sprint 0` entry with all ADRs listed |
| `.env.example` | 60+ variables across all 7 sprints, every one marked REQUIRED/OPTIONAL with comments |
| `.gitignore` | Python, Node, OS, IDE, secrets, cohort data patterns |
| `.pre-commit-config.yaml` | gitleaks v8.18.4, shellcheck, shfmt v3.8.0, prettier v3 (pinned) |
| `CLAUDE.md` | 113-line project-specific AI agent context (engineering rules, architecture, quick reference) |
| `session.sh` | Mac clipboard context generator — wraps CLAUDE.md + PROJECT_BRIEF.md + specified files in XML tags, estimates tokens via pbcopy |

### `.claude/` directory

| File | Purpose |
|---|---|
| `.claude/settings.json` | PreToolUse hooks: block writes to .env/secrets/.git, block destructive bash without --dry-run. PostToolUse hooks: prettier on .md, shfmt on .sh |
| `.claude/settings.local.json` | Gitignored local override template |
| `.claude/hooks/block-sensitive-writes.sh` | Blocks Write/Edit to .env, .env.local, secrets/, .git/ |
| `.claude/hooks/block-destructive-bash.sh` | Blocks rm -rf /, dropdb, gcloud projects delete, DROP DATABASE unless --dry-run present |
| `.claude/hooks/format-on-save.sh` | Auto-runs prettier on .md and shfmt on .sh after edits |
| `.claude/commands/project-review.md` | `/project:review` — lint, secret scan, standards check, .env.example sync, CHANGELOG check |
| `.claude/commands/project-fix-issue.md` | `/project:fix-issue <N>` — fetch issue → plan → implement → review → PR workflow |
| `.claude/commands/project-deploy.md` | `/project:deploy` — pre-deploy checklist + smoke test stubs (real steps added per sprint) |
| `.claude/skills/.gitkeep` | Placeholder — sprint-specific skills added as needed |

### `docs/` directory

| File | Purpose |
|---|---|
| `docs/PROJECT_BRIEF.md` | Living state document: URLs, stack table, folder layout, data model, API routes, version history, next sprint |
| `docs/CLAUDE_SYSTEM_PROMPT.md` | Paste-ready master engineering standards prompt for every Claude session |
| `docs/SESSION_STARTER.md` | Per-task context template with filled example |
| `docs/DECISION_LOG.md` | All 10 ADRs fully written (context / decision / alternatives / consequences / binding rules) |
| `docs/architecture.md` | ASCII system diagram (current = nothing, target = full stack), component inventory, network/DNS model, two data flow walkthroughs, deferred components table |
| `docs/install.md` | Skeleton — 11 sections with sprint attribution |
| `docs/operations.md` | Skeleton — 9 sections (daily, weekly, backup, restore, containers, upgrade, cohort start/end, incident, cost) |
| `docs/student-onboarding.md` | Skeleton — 10-step student laptop setup guide |
| `docs/security.md` | Skeleton — 7 sections (threat model, secrets, consent, moderation, retention, audit logs, hardening) |
| `docs/runbooks/.gitkeep` | Placeholder — runbooks added Sprint 5/6 |
| `docs/sprint-reports/sprint-0.md` | This file |

### CI — `.github/workflows/`

| File | Purpose |
|---|---|
| `.github/workflows/lint.yml` | prettier + shellcheck + shfmt on push/PR; `.env.example` sync check fails if a referenced `${VAR}` is not documented |
| `.github/workflows/secrets.yml` | gitleaks full-history scan on every push/PR via Action and binary |

### Tests

| File | Purpose |
|---|---|
| `tests/bootstrap/.gitkeep` | Placeholder — CI bootstrap test added Sprint 1 |
| `tests/smoke/smoke-test.sh` | Sprint 0: verifies scaffold completeness (file existence, CLAUDE.md line count, all 10 ADRs present, no hardcoded domain in scripts, .env not tracked). Sprint 1+ stubs marked as `skip` |

### Empty scaffolding directories

| Directory | Purpose |
|---|---|
| `infra/` | Docker Compose, Caddy, LiteLLM config — Sprint 1+ |
| `scripts/` | bootstrap, provision, cleanup scripts — Sprint 1+ |
| `scripts/lib/` | Shared bash functions — Sprint 1+ |
| `student-starter/` | Starter project distributed to students — Sprint 4 |
| `templates/` | Onboarding card, consent letter, curriculum templates — Sprint 3/4 |
| `services/` | Founder Console and tool services — Sprint 5.5+ |

---

## Every ADR written

| ADR | Title | Decision summary |
|---|---|---|
| ADR-001 | LiteLLM as the only LLM gateway | All LLM calls route through `api.${DOMAIN}`. No direct provider calls from any service. |
| ADR-002 | Single VM + Docker Compose | Core stack runs on one GCP e2-small VM. No Kubernetes, no Cloud Run, until Sprint 4+ utilisation forces it. |
| ADR-003 | Postgres as the only database | One Postgres instance for LiteLLM + Open WebUI + Founder Console. pgvector added in Sprint 4 — no separate vector DB. |
| ADR-004 | Caddy for HTTPS | Caddy handles TLS termination and reverse proxy. Automatic Let's Encrypt. No nginx + certbot. |
| ADR-005 | Firebase Hosting for student sites | GCS rejected (no HTTPS on custom domains). Firebase Hosting for all 12 student static sites. |
| ADR-006 | Open WebUI for chat UI | Configure, don't reimplement. `ENABLE_SIGNUP=false`. Kid-mode system prompt via env var. |
| ADR-007 | Continue.dev as in-IDE student AI | OpenAI-compatible API base URL points to LiteLLM. Virtual key per student. No custom extension needed. |
| ADR-008 | Custom Founder Console | FastAPI + HTMX at `founder.${DOMAIN}`. IP-locked. Reads LiteLLM Postgres (read-only). Under 1,500 lines total. |
| ADR-009 | Three-layer budget caps | Layer 1: per-student daily/weekly/total caps. Layer 2: cohort team cap. Layer 3: provider master account caps (outside platform). |
| ADR-010 | Slack as primary alerting channel | Five dedicated channels. LiteLLM native alerting covers 80%. Custom cron for platform health in Sprint 5. |

---

## Key decisions made (beyond ADRs)

**Document mapping confirmed:** `cultivlab-prd-v2.md` is the technical plan. `cultivlab-prd-mvp.md`
is the tight MVP scope. `operator-control-plane copy.md` is the control plane addendum that
added the Founder Console (Sprint 5.5), three-layer budgets, and the five-channel Slack
alerting model.

**Firebase confirmed over GCS** for student sites (ADR-005). The MVP PRD's GCS bucket
references describe the provisioning model; the actual hosting technology is Firebase.

**CLAUDE.md content basis:** Synthesised from v2 PRD section 13 ("Conventions for AI coding
agents"), MVP PRD section 10, and the engineering standards in the project instructions.
Result: 113 lines, focused, project-specific.

**Hook scripts in `.claude/hooks/`** rather than inline JSON in `settings.json` — improves
readability, testability, and editability without touching the JSON.

**Smoke test is functional at Sprint 0**, not just a stub — it verifies scaffold completeness
(file existence, CLAUDE.md line count, ADR count, no hardcoded domain, .env not tracked).
Real infrastructure assertions are stubs marked `skip` until Sprint 1.

---

## What was explicitly punted

**`docs/install.md` — real content:** All 11 sections are skeleton headings only. Real
content fills in sprint by sprint as infrastructure is built. Intent is documented.

**`docs/operations.md`, `docs/student-onboarding.md`, `docs/security.md`:** Same — skeleton
with clear section headings and sprint attribution notes. Not stubs, not empty — they are
navigable documents with explicit "filled in Sprint N" markers.

**CI bootstrap test (`.github/workflows/ci-bootstrap.yml`):** Not included. Sprint 0 has
nothing to bootstrap. This workflow is added in Sprint 1 when `scripts/bootstrap.sh` exists.
The placeholder is `tests/bootstrap/.gitkeep`.

**Sprint-specific skills (`.claude/skills/`):** Empty. Skills are added per sprint as
patterns emerge.

**`docs/runbooks/` content:** Two critical runbooks (`incident-response.md`, `restore.md`)
are deferred to Sprint 5/6 when the infrastructure they describe is built.

**`pre-commit run --all-files` on this repo:** Requires pre-commit and the tool chain
installed locally. The CI workflows enforce this on every push. Local setup is documented in
`CONTRIBUTING.md`.

---

## Acceptance criteria — verified

| Criterion | Status |
|---|---|
| All deliverables from Sprint 0 scope exist with real content | ✓ |
| CLAUDE.md is <200 lines, focused, project-specific | ✓ — 113 lines |
| .env.example lists every env var across all 7 sprints with comments | ✓ — 60+ vars, all REQUIRED/OPTIONAL |
| All 10 ADRs fully written (not stubs) | ✓ |
| session.sh is executable, works on macOS, copies to clipboard via pbcopy | ✓ |
| No secrets, no real names, no real keys anywhere in the repo | ✓ — all values are placeholders |
| gitleaks detect --source . returns clean | Verify locally — no real secrets were written |
| Sprint 0 completion report generated as docs/sprint-reports/sprint-0.md | ✓ — this file |

---

## What Sprint 1 requires

To begin Sprint 1, the operator must:

1. **Create the GCP project** — `GCP_PROJECT_ID` must exist before any script runs.
2. **Enable GCP APIs** — Compute Engine, Firebase Hosting, IAM, Resource Manager, Billing.
3. **Set up billing alerts** — at $50, $100, $200/month in the GCP billing console.
4. **Configure DNS at the registrar** — have the domain ready and registrar access available.
5. **Set up Slack workspace and channels** — five channels and five incoming webhooks before
   Sprint 2 alerting is configured.
6. **Obtain provider API keys** — Anthropic, OpenAI, and Vertex AI service account before
   Sprint 2 LiteLLM configuration.

Sprint 1 deliverables (from `docs/PROJECT_BRIEF.md`):

- `scripts/gcp-bootstrap.sh` — idempotent: VM, static IP, firewall rules, service account
- `infra/docker-compose.yml` — Caddy + LiteLLM + Postgres
- `infra/Caddyfile.tmpl` — env-var-driven reverse proxy
- `infra/litellm/config.yaml` — three provider config
- `scripts/bootstrap.sh` — VM-side idempotent setup (Docker, Compose, HTTPS)
- `docs/install.md` — sections 1–5 filled in with real content
- `.github/workflows/ci-bootstrap.yml` — validates fresh-VM bootstrap in CI
- Sprint 1 completion report: `docs/sprint-reports/sprint-1.md`
