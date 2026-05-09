# CultivLab — Security

**Status:** Skeleton — sections filled in sprint by sprint. This document covers the threat model,
secret handling, consent, moderation, data retention, and audit logging for the platform.

---

## Threat model

_Filled in Sprint 2._

Actors considered: curious student trying to access another student's account, student attempting to
bypass content moderation, external attacker probing public endpoints, compromised virtual key,
runaway spending. Mitigations for each.

Not in scope for MVP: nation-state actors, physical access to infrastructure, supply-chain attacks
on Docker images.

---

## Secrets handling

_Filled in Sprint 1._

### What counts as a secret

- Provider API keys (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, etc.)
- `LITELLM_MASTER_KEY` and `LITELLM_SALT_KEY`
- `POSTGRES_PASSWORD`
- `FOUNDER_CONSOLE_PASSWORD_HASH`
- Slack webhook URLs
- Firebase service account keys
- Student virtual API keys (generated, not stored in repo)

### Rules

- Secrets never in git. Pre-commit gitleaks hook enforces this.
- `.env` file lives only on the operator's machine and on the VM. Never committed.
- Student virtual keys printed on physical onboarding cards only. Not emailed in plaintext.
- Firebase service account keys generated per-student, distributed individually.
- Periodic `gitleaks detect --source .` scan documented in Sprint 5 runbook.

### Secret rotation procedure

_Filled in Sprint 2._

---

## Parental consent

_Filled in Sprint 1 (template), Sprint 3 (process)._

Required before any student under 13 is given access. Consent covers: data collection (chat logs,
usage metrics), content moderation monitoring, operator access to conversation history for support
purposes.

Consent collection method: `templates/parent-consent-letter.md` (operator customises and
distributes). No student account is created until signed consent is received.

Provider ToS review: Anthropic, OpenAI, and Google ToS reviewed before each cohort for under-13
usage clauses. Documented decision recorded here.

---

## Content moderation

_Filled in Sprint 2._

LiteLLM moderation callback enabled. Provider: OpenAI Moderation API (configurable). Moderation
triggers logged and Slack alert sent to `#cultivlab-safety` channel. Operator reviews safety alerts
within 1 hour during cohort hours.

Kid-mode system prompt (configurable via `KID_MODE_SYSTEM_PROMPT` env var) instructs all models to
keep responses age-appropriate.

---

## Data retention

_Filled in Sprint 3._

- Chat conversation history: retained in Open WebUI Postgres for cohort duration + 90 days. Deleted
  on cohort cleanup or on parent request.
- LLM spend logs: retained in LiteLLM Postgres for 1 year (billing audit trail).
- Student site content: retained on Firebase Hosting until manually deleted (student's work).
- Operator audit log (Founder Console): retained for 1 year.
- Postgres backups: retained for 30 days on GCS, then deleted by lifecycle policy.

---

## Audit logs

_Filled in Sprint 5.5._

Operator actions logged: every pause/resume/top-up/restrict/password-reset action recorded in
Founder Console audit table with timestamp and actor. Audit log is read-only and persists across
container restarts.

LiteLLM logs every request to `LiteLLM_SpendLogs` — queryable directly via Postgres.

---

## Access control hardening

_Filled in Sprint 2._

- `admin.${DOMAIN}` and `founder.${DOMAIN}` allowlisted to `FOUNDER_ALLOWED_IP` at Caddy layer. Even
  a compromised LiteLLM master key cannot be used from outside that IP.
- Open WebUI signup disabled (`ENABLE_SIGNUP=false`). No anonymous account creation.
- Postgres accessible only within the Docker Compose internal network. Not exposed externally.
- LiteLLM admin API protected by `LITELLM_MASTER_KEY`. Virtual keys have scoped permissions.
- VM firewall: only ports 80 and 443 open. SSH access via GCP IAP (no public SSH port).

---

## Vulnerability management

_Filled in Sprint 6._

Pinned Docker image versions. Process for evaluating and applying upstream security patches.
Frequency of dependency review.
