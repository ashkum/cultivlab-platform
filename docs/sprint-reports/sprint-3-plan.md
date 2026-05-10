# Sprint 3 — Plan

**Status:** Not started **Predecessor:** Sprint 2 wrap (v0.2.1) **Target version:** v0.3.0

## Goal

Deploy Open WebUI as the student-facing chat surface at `chat.${DOMAIN}`, with one account per
cohort student linked to their existing LiteLLM virtual key, plus a moderation pipeline that alerts
on flagged content.

## Critical risk to verify EARLY

**Open WebUI must pass each student's identity to LiteLLM as the `user` field on every chat
completion.** Without this, per-student spend attribution (proven working in Sprint 2 via direct API
calls) will not work through the chat surface.

If Open WebUI doesn't pass `user` natively in our pinned version, the workaround is a
header-injection middleware — which is meaningfully different infrastructure and must be decided up
front, not at the end.

Verification: spin up Open WebUI in a temporary local docker container pointing at a stub LiteLLM,
make one chat call as a logged-in user, inspect the request body LiteLLM receives. If
`user: <openwebui_user_id>` is in the body, proceed. If not, stop and design middleware.

This verification is **Deliverable 1** of Sprint 3.

## Deliverables (in this order, with hard STOP gates)

### 1. Verify user-field passing (research, no production code)

- Spin up Open WebUI locally pointed at a stub LiteLLM
- Verify `user` field passes through to chat completion calls
- Report findings
- **STOP** for go/no-go decision before any production code

### 2. Open WebUI service + Caddy route

- Add `open-webui` service to `infra/docker-compose.yml`
- Configure: signup disabled, OAuth disabled, kid-mode system prompt as env var
- Add `chat.${DOMAIN}` route in `infra/Caddyfile.tmpl`
- Update `.env.example` with new vars
- **STOP** for diff review

### 3. Per-student account provisioning script

- `scripts/provision-students.sh` reads `cohort-keys-${COHORT_NAME}.csv` (Sprint 2 output)
- Creates one Open WebUI account per row, linked to that student's LiteLLM virtual key
- Idempotent, supports `--dry-run`, exit codes 0/1/2 (matching Sprint 2's pattern)
- Generates plaintext "onboarding cards" — one per student — as PDFs with login URL + key
- **STOP** for diff review

### 4. Moderation pipeline

- LiteLLM moderation hook configured to alert `SLACK_WEBHOOK_SAFETY` on flagged content
- Use OpenAI's `omni-moderation-latest` as the moderator (already accessible via existing OpenAI
  key)
- Test with a deliberately flagged prompt; verify Slack alert fires
- **STOP** for diff review

### 5. CI updates

- Update `.github/workflows/ci-bootstrap.yml` to include `open-webui` in the compose-up step
- Add a basic smoke test: open-webui returns 200 on `/health`
- Verify CI passes
- **STOP** for diff review

### 6. Documentation

- `docs/install.md` §7 — Open WebUI setup, kid-mode prompt, signup disabled
- `docs/install.md` §8 — student onboarding flow + `provision-students.sh` usage
- Update `docs/architecture.md` to reflect Open WebUI added
- Fill in `docs/student-onboarding.md` (was placeholder in Sprint 0)
- Add ADR-011 to `docs/DECISION_LOG.md`: hybrid budget enforcement (LiteLLM total + Sprint 5 cron)
- Update `docs/PROJECT_BRIEF.md` to v0.3.0
- Create `docs/sprint-reports/sprint-3.md` (completion report, format matches sprint-2.md)
- **STOP** for diff review

### 7. Wrap

- Pre-commit clean
- Commit, push, watch CI
- Tag v0.3.0 if CI green

## Hard rules

- **Never proceed past a STOP without explicit "proceed" or "go"**
- If a contract bug surfaces in Sprint 1 or 2 work (e.g., Open WebUI doesn't pass user field), STOP
  and report — don't silently work around
- Don't touch any file outside the current deliverable
- If a deliverable takes more than 90 minutes, STOP and report — likely scope is bigger than
  estimated

## Out of scope (do NOT build, even if related)

- Sprint 4: Firebase Hosting integration, student-starter zip
- Sprint 5: monitoring crons, daily summaries, backups
- Sprint 5.5: Founder Console
- Sprint 6: pre-cohort hardening
- Anything not in deliverables 1-7 above

## Deliverable 1 — completed 2026-05-10

### Findings

1. Open WebUI v0.5.20 does NOT pass the `user` field to upstream LLM proxy on chat completions.
2. LiteLLM Customer Usage confirmed: 5 chat calls from Open WebUI registered with no user
   attribution.
3. Open WebUI v0.5.20 has a **Functions** subsystem (Filter Functions) that can inject fields into
   request bodies before they leave Open WebUI.
4. Open WebUI admin UI supports adding multiple OpenAI-compatible connections with distinct API
   keys, and a "Direct Connections" feature for per-user keys.

### Design decision

**Adopt: Filter Function for user-field injection (Open WebUI Functions subsystem).**

All students share ONE Open WebUI → LiteLLM connection (using the master key). A custom Open WebUI
Filter Function injects `user: <openwebui_user_id>` into every chat completion request body. LiteLLM
then attributes spend per-student via the existing `user` field path (already proven in Sprint 2).

### Why this approach over alternatives

- **Vs. per-user "Direct Connections" (each student configures their own LiteLLM key):** Too much
  configuration burden for 8-year-olds. High setup failure rate.
- **Vs. one admin-configured connection per student:** Doesn't isolate students from each other's
  keys in the model dropdown. Privacy leak.
- **Vs. middleware reverse proxy:** Adds infrastructure complexity. Filter Function achieves the
  same outcome with less moving parts.

### Implications for downstream deliverables

- **Deliverable 3 (provision-students.sh):** changes from "link account to LiteLLM virtual key" to
  "create Open WebUI account; rely on Filter Function for attribution"
- **Sprint 2 virtual keys retained:** used for API/Continue.dev access (NOT for chat). Documented in
  install.md §6.
- **No changes needed to LiteLLM config:** `user` field path is already wired in Sprint 2
  (`enforce_user_param: true`).

### Open questions for Deliverable 3

1. Does Open WebUI admin API support programmatic user creation? (Need to verify; affects provision
   script automation.)
2. Where exactly does the Filter Function get installed — admin Functions tab, or per-model?
   (Determines configuration UX.)

---

## Estimated effort

2-3 focused sessions of 90-120 min each. Total ~6 hours of focused work.

## Dependencies satisfied

- ✅ LiteLLM proxy live at `https://api.cultivlab.com`
- ✅ Per-student key provisioning verified (Sprint 2)
- ✅ DNS for `chat.cultivlab.com` already pointing at VM (set up during Sprint 1+2 deployment)
- ✅ Slack webhook for safety alerts configured

## Pre-Sprint 3 checklist

Before starting Sprint 3, complete the BACKLOG.md item "Test cohort cleanup before real cohort"
(delete the test-cohort team in LiteLLM). Otherwise it'll show up in Sprint 3 testing and cause
confusion.
