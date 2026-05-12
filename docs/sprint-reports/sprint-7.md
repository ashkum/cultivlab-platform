# Sprint 7 — Pre-Cohort Hardening

**Version:** v0.7.0  
**Tag:** v0.7.0  
**Status:** Complete  
**Date:** 2026-05-12

---

## Goal

Close all known operational gaps before a real student cohort runs. No new features — correctness,
resilience, and operator confidence.

---

## Deliverables

### D1 — Test cohort cleanup on VM

Wiped the `test-cohort` LiteLLM team and all associated virtual keys from the live database via the
admin API. Verified `GET /team/list` and `GET /key/list?team_id=test-cohort` both returned empty
after cleanup. VM is in a clean pre-cohort state.

### D2 — Unify `.env` files on VM (symlink)

**Problem:** `/opt/cultivlab/.env` (used by `docker compose`) and `/opt/cultivlab/repo/.env` (used
by operator scripts) were separate files that had drifted out of sync. Three differences found:
`FOUNDER_ALLOWED_IP` format (space vs comma), `FOUNDER_CONSOLE_PASSWORD_HASH` (placeholder vs real
hash), missing `FOUNDER_CONSOLE_SECRET_KEY` and `OPENWEBUI_URL`.

**Fix:** One-time migration synced the three diverged values into `repo/.env`, then created a
permanent symlink: `/opt/cultivlab/.env → /opt/cultivlab/repo/.env`. Now there is one source of
truth. `bootstrap.sh` was updated to create this symlink on first run instead of copying the file.

**Files changed:** `scripts/bootstrap.sh` — `stage_install_dir()` replaced `cp` with `ln -sf`.

### D3 — `bootstrap.sh` force-restart Caddy

**Problem:** `docker compose up -d` does not restart already-running containers, so a re-run of
`bootstrap.sh` after a Caddyfile change would not apply the new config.

**Fix:** Added `restart_caddy()` step (6b/9) that always runs `docker compose restart caddy`
immediately after `compose_up`. Caddy reloads its config in under 2 seconds, so the service
interruption is imperceptible.

**Files changed:** `scripts/bootstrap.sh` — new `restart_caddy()` function + call in `main()`.

### D4 — `scripts/reset-student-password.sh` (new script)

New operator tool for resetting a student's Open WebUI password without re-provisioning the full
cohort. Reads `cohort-students-${COHORT}.csv` to look up the student's Open WebUI user ID by slug,
then:

1. **Primary:** `POST /api/v1/users/{id}/update` via Open WebUI admin API.
2. **Fallback:** bcrypt hash via `docker exec` inside the OW container + direct `psql UPDATE auth`.

Updates the CSV with the new password on success. Prints `NEW_PASSWORD=...` to stdout for the
operator to hand to the student. Supports `--dry-run` and `--password <value>`.

**Files changed:** `scripts/reset-student-password.sh` (new, 285 lines after shfmt).

### D5 — `provision-students.sh` password preservation

**Problem:** Re-running `provision-students.sh` (idempotent for account creation) overwrote the
`owui_password` column with an empty string for existing users, destroying the recorded password.

**Fix:** On startup the script now loads any existing `cohort-students-${COHORT_NAME}.csv` into
parallel arrays. In the "kept" branch of `provision_one()`, it looks up and preserves the recorded
password instead of writing an empty string. If no recorded password is found it logs a warning
directing the operator to `reset-student-password.sh`.

**Files changed:** `scripts/provision-students.sh` — added `EXISTING_PW_*` arrays,
`_existing_password_for_slug()` helper, updated kept-user branch. File is exactly 300 lines.

### D6 — Fix Open WebUI account suspend 422 error

**Problem:** `services/founder-console/app/actions.py`'s `ow_disable_student()` called
`POST /api/v1/users/{id}/update` with only `{"role": "pending"}`. Open WebUI v0.5.20 validates a
`UserUpdateForm` requiring all four fields: `name`, `email`, `profile_image_url`, `role`. Sending
only `role` returned HTTP 422 (Unprocessable Entity), causing an amber "OW suspend failed" warning
on every pause/resume action.

**Fix:** `_ow_find_user_id()` renamed to `_ow_find_user()`, now returns the full user dict instead
of just the ID (no extra API call needed). `_ow_set_role()` now accepts the full dict and sends all
four fields in the update payload.

**Files changed:** `services/founder-console/app/actions.py`.

### D7 — Open WebUI branding (`WEBUI_NAME`)

Added `WEBUI_NAME: ${WEBUI_NAME:-CultivLab}` to the `open-webui` service environment in
`docker-compose.yml`. Added `WEBUI_NAME=CultivLab` to `.env.example`. Added `WEBUI_NAME=CultivLab`
to the live VM `.env`. After `--force-recreate open-webui`, the login page shows **"Sign in to
CultivLab"** instead of "Sign in to Open WebUI".

**Files changed:** `infra/docker-compose.yml`, `.env.example`.

### D8 — `docs/install.md` §7 and §8

Filled in the two sections that have been placeholders since Sprint 3:

- **§7 — Open WebUI setup:** DNS record for `chat.${DOMAIN}`, first-run admin account creation,
  disabling student self-registration, verifying LiteLLM connection and models, kid-mode system
  prompt verification, branding check.
- **§8 — Cohort provisioning:** `provision-students.sh` dry-run + live run, generating onboarding
  cards, verifying a student can log in end-to-end, password reset procedure.

**Files changed:** `docs/install.md`.

### D9 — Runbook: rotate a provider API key

New runbook at `docs/runbooks/rotate-provider-key.md` covering Anthropic, OpenAI, and Vertex AI key
rotation: generate new key at provider → update `.env` on laptop → push to VM → force-recreate
LiteLLM → smoke test all three providers → revoke old key. Includes symlink integrity check and
troubleshooting for auth errors and IAM gaps.

**Files changed:** `docs/runbooks/rotate-provider-key.md` (new).

### D10 — Runbook: Continue.dev smoke test

New runbook at `docs/runbooks/continue-dev-smoke-test.md` for the operator to verify Continue.dev
works with the platform before each cohort. Covers: install extension, pick a test virtual key,
configure `config.json` with `apiBase` + key, verify chat response, verify autocomplete inline
suggestion, verify spend attribution in LiteLLM admin UI, optional budget enforcement test, version
recording.

**Files changed:** `docs/runbooks/continue-dev-smoke-test.md` (new).

### D11 — Sprint docs + wrap

- `docs/sprint-reports/sprint-7.md` — this file
- `docs/PROJECT_BRIEF.md` — updated to v0.7.0
- `CHANGELOG.md` — v0.7.0 entry
- Git: commit `[sprint-7]`, tag `v0.7.0`, push

---

## Verified

- D2: `ls -la /opt/cultivlab/.env` confirms symlink; `docker compose config` resolves env correctly.
- D3: Caddy restarts cleanly on every `bootstrap.sh` run; Caddyfile changes apply immediately.
- D7: `https://chat.cultivlab.com` login page shows **"Sign in to CultivLab"** (confirmed live).
- D6: Code fix verified in review; live validation deferred until a test student is provisioned (no
  students in DB during Sprint 7 — clean pre-cohort state).

---

## Lessons captured

- **OW v0.5.20 `UserUpdateForm` requires all 4 fields.** Sending only `{role}` returns HTTP 422.
  Always pass `name`, `email`, `profile_image_url`, and `role` in any OW user update call.
- **`docker compose up -d` does not restart running containers.** After any Caddyfile or env-var
  change, always call `docker compose restart <service>` explicitly.
- **Two `.env` files will drift.** A symlink is the only reliable fix — not a copy, not a reminder
  in the docs.
- **IAP SSH sessions drop silently.** Always verify the shell prompt shows the VM hostname before
  pasting commands. Mac and VM terminals look identical.

---

## Deferred to Sprint 8 / BACKLOG

- D6 live validation (pause/resume student in Founder Console with a real provisioned student).
- `docs/student-onboarding.md` — still skeletal; needs screenshots and Continue.dev config
  walk-through.
- `docs/install.md` §12 pre-cohort hardening checklist — placeholder since Sprint 5.
- Langfuse tracing integration (Sprint 4 deferred; cohort will validate demand).
