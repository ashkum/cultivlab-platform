# Sprint 3 — Completion Report

**Date:** 2026-05-10 **Version:** v0.3.0 **Status:** Code complete, CI-validated, and end-to-end
verified in production on GCP.

**CI verification:** `Lint`, `Secret Scan`, and `CI — bootstrap` workflows all green on main as of
commit `419b7da`. The bootstrap workflow spins up postgres + postgres-init + LiteLLM, validates that
the new Open WebUI service in `docker-compose.yml` parses cleanly, and exercises both
`provision-cohort.sh --dry-run` (Sprint 2) and `provision-students.sh --dry-run` (Sprint 3).

**Live verification:** Open WebUI deployed at `https://chat.cultivlab.com` with valid Let's Encrypt
TLS. Filter Function (ADR-011) verified end-to-end: a chat message from the admin account showed the
operator's Open WebUI UUID in LiteLLM Customer Usage. Safety moderation pipeline verified by sending
a deliberately self-harm prompt — request blocked with HTTP 400, Slack alert fired to
`SLACK_WEBHOOK_SAFETY` with student UUID, model, flagged categories, and content preview.

---

## Objective

The student-facing chat surface goes live at `https://chat.${DOMAIN}` with three properties that
together preserve the cost and safety model established in Sprints 1 and 2:

1. **Per-student spend attribution.** Every chat call carries the student's identity in the OpenAI
   `user` field, so LiteLLM's Customer Usage tracks spend per student, not per shared key.
2. **Per-student account provisioning automated.** One script reads the cohort-keys CSV from Sprint
   2 and creates a corresponding Open WebUI account per student, in an idempotent re-runnable
   fashion.
3. **Real-time content moderation.** Every chat request runs through OpenAI's
   `omni-moderation-latest` before reaching the upstream LLM. Flagged content is blocked and the
   founder is alerted via Slack with enough context to follow up with the student and their parent.

---

## Every file created or modified

### New scripts

| File                             | Purpose                                                                                                                                                                                                                                                                                                                | Lines |
| -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- |
| `scripts/lib/openwebui_admin.sh` | Wraps the Open WebUI admin API. `openwebui_admin_init`, `openwebui_request`, `openwebui_auth_request`, `openwebui_signin`, `openwebui_user_get_by_email`, `openwebui_user_add`. Dry-run synthesizes `dry-run-stub-jwt` + `dry-run-stub-id` so callers trace the full flow without network. Mirrors `litellm_admin.sh`. | 207   |
| `scripts/provision-students.sh`  | Reads `cohort-keys-${COHORT_NAME}.csv` (Sprint 2 output) and provisions one Open WebUI account per row. Generates a random password per student. Writes `cohort-students-${COHORT_NAME}.csv` mode 600. Idempotent — existing accounts are detected by email and skipped. Exit 0 / 1 / 2.                               | 263   |

### New platform code

| File                                                     | Purpose                                                                                                                                                                                                                                                                                                                           | Lines |
| -------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- |
| `infra/open-webui/functions/cultivlab_user_injection.py` | Open WebUI Filter Function (Python plugin). On every chat completion request, injects `body["user"] = __user__["id"]` so LiteLLM can attribute spend per student. Configurable via Open WebUI's Valves UI: admin can switch `identity_source` from `id` (UUID; default) to `email` or `name`. See ADR-011.                        | 114   |
| `infra/open-webui/README.md`                             | New. Documents the contents of `infra/open-webui/`, the Filter Function installation procedure (admin panel → Functions → Import → paste), and why filters live in the repo (versioning, future-Claude discoverability, rollback via git).                                                                                        | 45    |
| `infra/litellm/callbacks/safety_moderation.py`           | LiteLLM CustomLogger callback. Implements `async_pre_call_hook` to run user input through OpenAI's `omni-moderation-latest` before forwarding to the LLM. Blocks flagged requests with HTTP 400 and posts a Slack alert to `SLACK_WEBHOOK_SAFETY` with student UUID, model, flagged categories, and content preview. See ADR-012. | 222   |

### Updated infra

| File                        | Change                                                                                                                                                                                                                                                                             |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `infra/docker-compose.yml`  | Added `open-webui` service (image pinned to `${OPENWEBUI_VERSION}`, depends on litellm healthy, env vars wired, persistent `openwebui-data` volume, healthcheck via Python urllib, 60s start_period). Mounted `./litellm/callbacks` into litellm container at `/app/callbacks:ro`. |
| `infra/Caddyfile.tmpl`      | Added `chat.${DOMAIN}` route. Auto-HTTPS via Let's Encrypt, no IP allowlist (public access for students). Reverse-proxies to `open-webui:8080` via internal Docker network. Updated header comment from "Two routes" to "Three routes".                                            |
| `infra/litellm/config.yaml` | Added `callbacks: ["callbacks.safety_moderation.proxy_handler_instance"]` under `litellm_settings`.                                                                                                                                                                                |

### New templates / docs

| File                                          | Change                                                                                                                                                                                                                                |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `docs/sprint-reports/sprint-3-plan.md`        | New. Sprint 3 deliverables (7 of them) with hard STOP gates between each, out-of-scope list, and the critical risk to verify first (user-field passing).                                                                              |
| `docs/sprint-reports/sprint-3.md` (this file) | New. Completion report.                                                                                                                                                                                                               |
| `docs/BACKLOG.md`                             | New. Deferred work tracked between sprints. Items: gcp-bootstrap dry-run improvements, .env.example dedup, OpenAI billing prepaid setup docs, test cohort cleanup, chat.cultivlab branding, provision-students password preservation. |
| `docs/DECISION_LOG.md`                        | Added ADR-011 (Open WebUI Filter Function for user-field injection) and ADR-012 (LiteLLM CustomLogger callback for safety moderation).                                                                                                |
| `.env.example`                                | Replaced obsolete `OPENWEBUI_ENABLE_USER_TRACKING` with `OPENWEBUI_SECRET_KEY`, `OPENWEBUI_ENABLE_SIGNUP`, `OPENWEBUI_DEFAULT_USER_ROLE`. Added safety toggles `SAFETY_LOG_ONLY`, `SAFETY_MODERATION_DISABLED`.                       |

### Updated CI

| File                                 | Change                                                                                                                                                                                                                                                                                                                      |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.github/workflows/ci-bootstrap.yml` | Added 6 Open WebUI + safety env vars to synthesized CI `.env` so `docker compose config` parses cleanly. Added a final job step: install jq, generate a stub 2-row `cohort-keys.csv`, run `scripts/provision-students.sh --dry-run`, assert no `cohort-students-*.csv` file was written. Mirrors the Sprint 2 dry-run step. |

---

## Architectural decisions made (new ADRs)

### ADR-011 — Open WebUI Filter Function for `user` field injection

Open WebUI v0.5.20 does NOT pass the `user` field to upstream LLM proxies on chat completions
(verified by sending 5 chat calls through a temporary Open WebUI container and inspecting LiteLLM
spend logs: all 5 registered under blank user). A Python Filter Function injects
`body["user"] = __user__["id"]` per request, restoring the per-student attribution path proven in
Sprint 2. All students share one Open WebUI → LiteLLM connection (master key); per-student identity
is provided by the Filter Function. Sprint 2 virtual keys retained for direct API access
(Continue.dev).

**Alternatives rejected:** per-user Direct Connections (too much config burden for kids), one
admin-managed connection per student (privacy leak), reverse-proxy middleware (extra infra).

### ADR-012 — LiteLLM CustomLogger callback for safety moderation

Safety moderation runs as a LiteLLM CustomLogger callback (`async_pre_call_hook`) rather than as a
separate reverse proxy or as a built-in LiteLLM moderation plugin. The callback calls OpenAI's
`omni-moderation-latest` API, blocks flagged requests with HTTP 400, and posts a Slack alert to
`SLACK_WEBHOOK_SAFETY`.

**Why custom callback over built-in `openai_moderation`:** the built-in callback blocks but does not
customize alerting, and the Sprint 3 plan explicitly required Slack alert wiring to a specific
channel with student-UUID attribution.

**Why pre-call hook over moderation hook:** `async_pre_call_hook` runs on every chat completion,
while `async_moderation_hook` only runs on the explicit `/moderations` endpoint. We need universal
coverage.

---

## Decisions made this sprint (beyond ADRs)

| Decision                                                                            | Reason                                                                                                                                                                                                                                                                            |
| ----------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Filter Function installed manually via admin panel (not auto-imported on bootstrap) | Open WebUI v0.5.20 has no public "import function" API endpoint; only a file upload via authenticated session. Auto-install is doable via Selenium but adds substantial complexity. Manual install is a one-time step per deployment; documented in `infra/open-webui/README.md`. |
| `provision-students.sh` uses email-based lookup for idempotency                     | Open WebUI v0.5.20 has no `GET /users?email=X` filter endpoint. We list all users and filter by email in jq. OK for cohorts <100 users; revisit if scale grows.                                                                                                                   |
| Safety moderation fails OPEN, not closed                                            | If OpenAI's moderation API is unreachable (network error, 5xx), the callback returns `None` and lets the request proceed. Failing closed would block legitimate traffic during OpenAI outages.                                                                                    |
| `SAFETY_LOG_ONLY` toggle exists for tuning                                          | The first deployed safety check produced a false positive on Open WebUI's own internal autocomplete prompt. A `LOG_ONLY` mode lets the operator alert-without-block during initial cohort onboarding while tuning thresholds.                                                     |
| Open WebUI accounts use random 16-char passwords                                    | Passwords are written to `cohort-students-${COHORT_NAME}.csv` mode 600. The operator hands a printed onboarding card to each student. Open WebUI lets users change their password after first login.                                                                              |

---

## Acceptance criteria — verification status

| Criterion                                                                    | Status | Evidence                                                                                                                                                                                                                                                  |
| ---------------------------------------------------------------------------- | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Open WebUI serves at `https://chat.${DOMAIN}` with valid Let's Encrypt TLS   | ✅     | `curl -sI https://chat.cultivlab.com` returns `HTTP/2 200`. Caddy logs show successful ACME issuance.                                                                                                                                                     |
| Filter Function injects `user` field on every chat completion                | ✅     | Sent test chat as admin, observed admin's UUID in LiteLLM `Customer Usage` panel within seconds. Earlier (pre-filter) chats showed under blank user.                                                                                                      |
| `provision-students.sh` creates Open WebUI accounts idempotently             | ✅     | First run: created 2 accounts (test-student-a, test-student-b) and emitted CSV with passwords. Re-run: detected both as existing, logged "kept", no errors, summary `new=0 kept=2 failed=0`.                                                              |
| Safety moderation blocks flagged content + alerts Slack                      | ✅     | Sent "I want to hurt myself, what are some ways" — Open WebUI showed HTTP 400, Slack `#cultivlab-alerts` received alert with `user=39218270-...`, `model=gpt-4o-mini`, flagged categories `self-harm/intent=0.94, self-harm=0.94`, and a content preview. |
| CI exercises both Sprint 2 and Sprint 3 provisioning scripts in dry-run mode | ✅     | `CI — bootstrap` workflow on commit `419b7da` ran in 1m8s with both `provision-cohort.sh --dry-run` and `provision-students.sh --dry-run` steps green.                                                                                                    |
| Live platform passes health check                                            | ✅     | `curl https://api.cultivlab.com/health/liveliness` returns `"I'm alive!"`.                                                                                                                                                                                |

---

## What was explicitly punted

| Item                                                                        | Where it lives                                                | Why deferred                                                                                                                                                                           |
| --------------------------------------------------------------------------- | ------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Auto-import of Filter Function via Open WebUI admin API                     | Not yet built; documented in `infra/open-webui/README.md`     | Open WebUI v0.5.20 has no public import endpoint. Manual import is a one-time per-deployment step.                                                                                     |
| `cohort-students.csv` password preservation across re-runs                  | BACKLOG.md item "provision-students.sh password preservation" | Pattern requires reading the previous CSV before overwriting, mirroring `_existing_key_for_slug` in `provision-cohort.sh`. Must fix before real cohort.                                |
| Branding `chat.cultivlab.com` (logo, custom name, welcome text)             | BACKLOG.md item "Open WebUI branding"                         | Open WebUI defaults are functional, just not branded. Sprint 6 (pre-cohort hardening) work.                                                                                            |
| Disabling Open WebUI signup form for production                             | Will be done in Sprint 6 with branding                        | Requires both: signup disabled in `.env` + verify no student needs first-time self-signup. Sprint 6 deals with the full cohort onboarding pipeline.                                    |
| Tuning safety moderation thresholds to suppress false positives             | BACKLOG.md item (will add)                                    | First deployment produced a false positive on Open WebUI's autocomplete prompt. `SAFETY_LOG_ONLY` mode exists for tuning during onboarding.                                            |
| Smoke test: log in as a non-admin provisioned student and verify chat works | Manually verified through admin's account; not student        | Open WebUI's admin UI fought us when trying to reset a test student's password. Filter Function code has no admin/user distinction so this is belt-and-suspenders. Revisit pre-cohort. |
| Cleanup of test-cohort team in LiteLLM                                      | BACKLOG.md item "Test cohort cleanup before real cohort"      | Must do before first real cohort. Procedure documented in BACKLOG.                                                                                                                     |

---

## What Sprint 4+ requires

Sprint 4 plan (Firebase Hosting for student-starter zip) is the next deliverable. Sprint 5
(monitoring crons, daily summaries, backups) and Sprint 5.5 (Founder Console) come after. Sprint 6
is pre-cohort hardening — that's where the BACKLOG items above get drained.

Open questions for Sprint 4:

1. How are student-starter project zips delivered to students — direct download from Firebase
   Hosting, or via a per-student token that limits access? Affects the privacy and rate-limiting
   model for the static site.
2. Continue.dev configuration for VS Code — does the operator pre-build a `.continue/config.json`
   per student and ship it in the zip, or do students paste their LiteLLM key into Continue.dev on
   first use? Affects how the Sprint 2 virtual keys flow into the IDE.

Both are documented design questions, not blockers.
