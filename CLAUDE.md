# CultivLab Platform — CLAUDE.md

AI agent context. Read this file completely at the start of every session.

---

## What this is

CultivLab is a self-deployable, multi-tenant AI platform. The first use case is a 3-week AI literacy
cohort for ages 8–12: students chat with Claude/ChatGPT/Gemini, write code with AI assistance in VS
Code, and deploy static sites to `<slug>.${DOMAIN}`.

No operator-specific values (domain name, real keys, real student names) belong in this repo.
Everything operator-specific lives in `.env` or outside the repo entirely.

---

## Current state

**Version:** v0.0.1 — Sprint 0 (repository scaffold only). **Nothing runs yet.** **Next sprint:**
Sprint 1 — GCP foundation, VM, Caddy, Postgres, LiteLLM.

See `docs/PROJECT_BRIEF.md` for the living project state. Update it every sprint.

---

## Read every session

1. This file (CLAUDE.md) — you are reading it now ✓
2. `docs/PROJECT_BRIEF.md` — current state, stack, known issues, next up
3. The task brief for today's specific work

When implementing infrastructure or scripts, also read `docs/architecture.md` and
`docs/DECISION_LOG.md` before touching any files.

---

## Engineering rules (binding — no exceptions)

1. **No hardcoded values.** All operator-specific config must be env vars from `.env`.
2. **New env var = update `.env.example`** in the same commit. CI will catch sync drift.
3. **Idempotent scripts only.** Running twice must produce identical state, no duplicates.
4. **Every script must have `--dry-run`.** Prints intended actions, makes zero changes.
5. **Explicit error handling.** Validate inputs. Handle failures. No silent failures.
6. **Files under 300 lines.** If a file would exceed this, propose a split before writing.
7. **DRY.** Logic written twice → extract to `scripts/lib/` or a shared module.
8. **No PII in repo.** Real student names, emails, keys live outside the repo entirely.
9. **Structured JSON logging** to stdout from all scripts and services.
10. **Secrets never in code.** Pre-commit gitleaks will catch leaks — don't test it.
11. **Update `docs/architecture.md`** whenever a new component is added or changed.
12. **Update `docs/install.md`** whenever a new install step or dependency is introduced.
13. **Prefer existing tools.** Configure LiteLLM, Open WebUI, Caddy — do not reimplement.
14. **No new dependencies without justification.** Each one is a long-term maintenance cost.
15. **Production-quality code, not demos.** SOLID, single-responsibility, defensive coding.

---

## Sprint conventions

- **Commit prefix:** `[sprint-0]`, `[sprint-1]`, etc. Imperative subject. Under 72 chars.
- **Confirm the current sprint** before coding. Never build ahead into a future sprint.
- **Stay in MVP scope.** If a task implies Appendix A (deferred platform features), stop and ask the
  operator before proceeding.
- **Before writing code:** state what changes, list files touched, flag side effects. Ask if
  anything is unclear.
- **After writing code:** self-review for bugs and edge cases, list follow-ups, state what needs
  manual testing.

---

## Architecture (current state: Sprint 0 — nothing built yet)

```
chat.${DOMAIN}     → Open WebUI       (student chat UI)        [Sprint 3]
api.${DOMAIN}      → LiteLLM proxy    (gateway, virtual keys)  [Sprint 2]
admin.${DOMAIN}    → LiteLLM admin UI (operator, IP-locked)    [Sprint 2]
founder.${DOMAIN}  → Founder Console  (operator, IP-locked)    [Sprint 5.5]
<slug>.${DOMAIN}   → Firebase Hosting (student static sites)   [Sprint 4]
```

Core stack: Single GCP e2-small VM → Docker Compose → Caddy + LiteLLM + Postgres + Open WebUI +
Founder Console. Postgres is the only database for all services.

Key decisions: LiteLLM is the **only** LLM gateway — no direct provider calls anywhere. Three-layer
budget caps per student (daily / weekly / total) plus cohort cap plus provider master cap. Full
decision log: `docs/DECISION_LOG.md`.

---

## What you must NOT do

- Do not write secrets, real keys, real names, or the operator's real domain into any file.
- Do not call LLM providers directly — all calls must route through LiteLLM at `api.${DOMAIN}`.
- Do not introduce Kubernetes, Cloud Run, or microservice splits in Sprints 0–3.
- Do not add Langfuse or pgvector before Sprint 4.
- Do not introduce npm or Python packages without operator approval.
- Do not skip `--dry-run` on any provisioning or destructive script.
- Do not push to `main` directly — PRs only, CI must pass.
- Do not build deferred platform features (RAG, agents, billing, evals) until the cohort validates
  demand and the operator writes a new PRD for the next iteration.

---

## Quick reference

| What you need           | Where to find it                       |
| ----------------------- | -------------------------------------- |
| All env vars            | `.env.example`                         |
| Architecture decisions  | `docs/DECISION_LOG.md`                 |
| Current project state   | `docs/PROJECT_BRIEF.md`                |
| Full install steps      | `docs/install.md`                      |
| Ops runbooks            | `docs/operations.md`, `docs/runbooks/` |
| Session context builder | `./session.sh [file1] [file2] ...`     |
