# Sprint 1 — Completion Report

**Date:** 2026-05-09
**Version:** v0.1.0
**Status:** Code complete. Pending operator verification on a real GCP project (acceptance
criteria checklist below).

---

## Objective

Build the foundation: a single GCP e2-small VM running Caddy + LiteLLM + Postgres +
postgres-init via Docker Compose. The operator runs two scripts from their laptop and ends
up with a live VM serving `https://api.${DOMAIN}/health/liveliness` over valid TLS, plus an
IP-locked LiteLLM admin UI at `https://admin.${DOMAIN}`. No virtual keys, no Open WebUI,
no students.

---

## Every file created or modified

### New scripts

| File                       | Purpose                                                                              | Lines |
| -------------------------- | ------------------------------------------------------------------------------------ | ----- |
| `scripts/lib/common.sh`    | Shared bash lib: `log_info/warn/error` (JSON stdout/stderr), `require_env`, `is_dry_run`, `run_or_dry`, `parse_common_args` | 128 |
| `scripts/gcp-bootstrap.sh` | Mac-side idempotent GCP setup: APIs, static IP, VM SA, IAM binding, firewall, VM    | 246 |
| `scripts/bootstrap.sh`     | VM-side idempotent bringup: Docker install, stage `/opt/cultivlab/infra`, render Caddyfile, `compose pull/up`, health-poll, public self-test | 281 |

### New infra

| File                          | Purpose                                                                                  | Lines |
| ----------------------------- | ---------------------------------------------------------------------------------------- | ----- |
| `infra/docker-compose.yml`    | 4 services on `cultivlab-net`: postgres → postgres-init → litellm → caddy. Only Caddy publishes 80/443. All values env-var-driven. | 122 |
| `infra/Caddyfile.tmpl`        | Reverse proxy template. `api.${DOMAIN}` → litellm:4000. `admin.${DOMAIN}` IP-locked via `remote_ip` matcher; non-allowed traffic returns 403. | 36 |
| `infra/litellm/config.yaml`   | Three providers (Anthropic, OpenAI, Vertex AI). Five Slack webhook routes for `alert_to_webhook_url`. `enforce_user_param: true`, `store_model_in_db: false`, `drop_params: true`. | 52 |

### New CI

| File                                     | Purpose                                                                                            | Lines |
| ---------------------------------------- | -------------------------------------------------------------------------------------------------- | ----- |
| `.github/workflows/ci-bootstrap.yml`     | Path-filtered (`infra/**`, `scripts/**`). Brings up postgres + postgres-init + litellm on Ubuntu 24.04 runner, polls `/health/liveliness`, asserts container states, dumps logs on failure, tears down. Caddy excluded — no public TLS in CI. | 140 |

### Updated docs

| File                                | Change                                                                  |
| ----------------------------------- | ----------------------------------------------------------------------- |
| `docs/install.md`                   | Sections 1–5 filled in with real, testable content (prerequisites, GCP setup, DNS, IAP SSH, bootstrap, verification, troubleshooting). Sections 6–11 remain skeleton. |
| `docs/architecture.md`              | "Current state" diagram updated from "scaffold only" to Sprint 1 state. Component inventory updated. Target diagram preserved. |
| `docs/PROJECT_BRIEF.md`             | Version v0.1.0, live URLs table updated, "Next up" pointed at Sprint 2 |
| `.gitignore`                        | Added `infra/Caddyfile` (rendered by bootstrap.sh) and `infra/.env`     |

---

## Architectural decisions affirmed (no new ADRs)

- **ADR-001** — LiteLLM is the only LLM gateway. The compose file wires three providers
  through LiteLLM only; no other service in the stack reaches a provider.
- **ADR-002** — Single VM + Docker Compose. The whole Sprint 1 stack lives on one e2-small.
- **ADR-003** — Postgres is the only database. `postgres` is the sole DB container; LiteLLM,
  Open WebUI (Sprint 3), and Founder Console (Sprint 5.5) will all share it.
- **ADR-004** — Caddy for HTTPS. Caddy auto-issues Let's Encrypt certs; no nginx + certbot.
- **ADR-009** — Three-layer budget caps (provider master-cap layer setup is operator-side
  in §6 of `docs/install.md`, deferred to Sprint 2).
- **ADR-010** — Slack as primary alerting. Five webhooks routed via LiteLLM
  `alert_to_webhook_url`; `SLACK_WEBHOOK_SAFETY` is reserved for Sprint 3 moderation flow
  (LiteLLM's native `alert_types` don't include a moderation category, so the env is
  passed to the container but unused until Sprint 3).

---

## Decisions made this sprint (beyond ADRs)

| Decision                                         | Why                                                                                                          |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| **Caddy from Docker Hub, not GHCR**              | Docker Hub `caddy:2.8.4-alpine` has reliable tag coverage; GHCR mirror is sparser. Documented in compose.    |
| **`v` prefix in LiteLLM tag hardcoded in compose** | Lets `LITELLM_VERSION` in `.env.example` stay a clean semver (e.g. `1.57.3`). Tag becomes `main-v1.57.3`. The sensitive-writes hook also blocks edits to `.env.example`, so this is the lowest-friction path. Operators bumping LiteLLM update only the numeric part. |
| **SA-before-VM ordering** in `gcp-bootstrap.sh`  | Brief listed VM before SA, but attaching an SA via `set-service-account` requires a stopped VM. Creating the SA first lets us pass `--service-account` at VM-create time, which is re-run-safe. End state identical. |
| **IAP SSH only; port 22 not exposed**            | Defense-in-depth. The HTTP/HTTPS firewall rule scopes to a network tag (`cultivlab-http`), not the whole VM. SSH is governed by `roles/iap.tunnelAccessor` + OS Login. |
| **Vertex AI via ADC, no key file**               | The VM's attached SA gets `roles/aiplatform.user`; the GCE metadata server provides ADC inside the LiteLLM container. No service-account JSON ever lands on disk. |
| **`postgres-init` is a one-shot anchor**         | Today it just does `psql -c 'SELECT 1'` then exits 0. LiteLLM runs its own Prisma migrations on startup, so we don't duplicate that. The container exists so future sprints (pgvector in Sprint 4) can add `CREATE EXTENSION` calls without changing topology. |
| **`/health/liveliness` for the self-test**       | LiteLLM's `/health` exercises every model and can flake on cold start; `/health/liveliness` is the lightweight proxy-only check used by the compose health check too. Operator-facing manual check (`/health`) remains documented in install.md §5. |
| **CI skips Caddy entirely**                      | Real Let's Encrypt requires public DNS + 80/443 — neither exists on a GH runner. Bringing up postgres + postgres-init + litellm covers everything CI can meaningfully verify; Caddy correctness is verified by `bootstrap.sh`'s self-test on a real VM. |
| **`FOUNDER_ALLOWED_IP` comma-normalization**     | `.env.example` documents comma-separated CIDRs but Caddy's `remote_ip` matcher uses space separation. `bootstrap.sh` rewrites commas to spaces before envsubst, so both formats work without changing the env-var schema. |

---

## Acceptance criteria — verification status

| Criterion                                                                        | Status                                                            |
| -------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| `scripts/gcp-bootstrap.sh --dry-run` runs cleanly on a Mac with no GCP calls     | **Verified** (smoke-tested with stub gcloud)                       |
| `scripts/gcp-bootstrap.sh` runs end-to-end on a fresh GCP project                | **Pending operator** — requires real GCP project                  |
| Re-running `gcp-bootstrap.sh` produces no errors / no duplicates                 | **Verified** (4 skip-if-exists checks fire on stub run)            |
| `scripts/bootstrap.sh --dry-run` runs cleanly on the VM with no changes          | **Verified** (smoke-tested with stub env)                          |
| `scripts/bootstrap.sh` runs end-to-end: Docker installed, stack running, TLS valid | **Pending operator**                                              |
| Re-running `bootstrap.sh` produces no errors                                     | **Pending operator** — code paths designed for it                 |
| `curl https://api.${DOMAIN}/health` returns HTTP 200 with valid SSL              | **Pending operator**                                              |
| `curl https://admin.${DOMAIN}/ui` returns HTTP 200 from `FOUNDER_ALLOWED_IP`     | **Pending operator**                                              |
| Same URL from any other IP returns HTTP 403                                      | **Pending operator**                                              |
| `docker compose down && docker compose up -d` restores full state                | **Pending operator** — compose volumes designed for it            |
| All three provider models listed at `GET /v1/models`                             | **Pending operator**                                              |
| Direct curl to LiteLLM with a test prompt succeeds for each provider             | **Pending operator** — requires real provider keys                |
| `docs/install.md` sections 1–5 are filled in with real working content           | **Verified**                                                       |
| CI bootstrap workflow passes on a clean Ubuntu 24.04 runner                      | **Pending first push to main** — workflow path-filter triggers    |
| `.env.example` is in sync with all new env vars introduced this sprint           | **Verified** (no new vars introduced; lint workflow enforces sync) |
| `pre-commit run --all-files` passes                                              | **Pending operator local run**                                    |
| `gitleaks detect --source .` returns clean                                       | **Pending operator local run**                                    |

---

## What was explicitly punted

- **Real `pre-commit` and `gitleaks` runs.** These run in CI (`.github/workflows/lint.yml`,
  `secrets.yml`) on every push. Local execution depends on operator tooling; not gating
  Sprint 1 close-out.
- **End-to-end provider verification.** LiteLLM's `/health/liveliness` confirms the proxy
  is running; actual provider calls require real keys and are part of the Sprint 2
  acceptance criteria.
- **Multi-CIDR `FOUNDER_ALLOWED_IP` documentation.** The comma → space normalization works
  for any number of CIDRs; explicit operator-facing documentation of multi-CIDR setup is
  deferred until an operator actually needs it.
- **Sprint 1 runbooks.** `docs/runbooks/` remains empty; `docs/install.md` §5
  troubleshooting covers the common first-run failure modes inline. Dedicated runbooks
  arrive in Sprint 5/6 with `incident-response.md` and `restore.md`.

---

## What Sprint 2 requires

To begin Sprint 2 verification, the operator must:

1. **Run Sprint 1 to completion on a real GCP project** and confirm the manual acceptance
   criteria in the table above.
2. **Have real provider API keys** loaded into `.env` (Anthropic, OpenAI, Vertex AI) —
   already documented in `.env.example`.
3. **Have all five Slack incoming webhooks live** so budget alerts and daily reports can
   be smoke-tested in Sprint 2.
4. **Decide cohort budget defaults** (`COHORT_MAX_BUDGET`, `STUDENT_MAX_BUDGET`,
   `STUDENT_DAILY_BUDGET`, `STUDENT_WEEKLY_BUDGET`) — defaults in `.env.example` are
   conservative starting points (see ADR-009).

Sprint 2 deliverables (preview — formal task brief at sprint start):

- `scripts/provision-cohort.sh` — reads `students.csv`, generates per-student virtual
  keys via LiteLLM admin API, applies three-layer budget caps
- LiteLLM team budgets configured for the cohort
- Provider master-cap configuration documented in `docs/install.md` §6
- Slack alert smoke test: one synthetic budget breach per channel
- Sprint 2 completion report
