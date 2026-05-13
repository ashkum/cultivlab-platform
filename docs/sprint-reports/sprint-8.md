# Sprint 8 — Pre-Cohort-2 Hardening

**Version:** v0.8.0 **Tag:** v0.8.0 **Status:** Complete **Date:** 2026-05-13

---

## Goal

Close all remaining gaps before cohort-2: upgrade Open WebUI to get proper permission controls,
write the student onboarding guide, fix install.md accuracy issues, rotate the expired OpenAI key,
and clean up test user accounts. Cohort-1-2026 was live during this sprint — all production changes
were non-destructive or had operator-informed downtime.

---

## Deliverables

### D1 — `docs/student-onboarding.md` — full content

Replaced all "_Filled in Sprint 4_" placeholder sections with real, validated content based on the
cohort-1-2026 operator run-through. Covers:

- What students need before Day 1 (hardware, software, what to bring)
- Onboarding card contents (table of all fields)
- Chat login at `https://chat.${DOMAIN}`, model selection
- VS Code install (macOS and Windows)
- Continue.dev and Live Server extension install + verification
- Continue.dev `config.json` setup with all 3 models (Claude, GPT-4o mini, Gemini 2.5 Flash)
- Starter project structure and opening in VS Code
- Live Server local preview workflow
- Deploy workflow: student saves file, tells operator, operator pushes live (no gcloud on student
  laptops)
- The daily edit → preview → deploy → share loop
- Getting help table (8 common problems with exact fixes)

Key design decision: students do not run `gcloud` commands. The operator deploys files for them
using the two-step `gcloud scp` + `sudo mv` workflow.

### D2 — `docs/install.md` §7–8 accuracy review

Four issues found and fixed:

1. **§7.2 missing:** "Set Default User Role to `user`" step — without this, provisioned student
   accounts end up in `pending` state and cannot log in.
2. **§7.5 missing (new section):** "Create Public workspace models" — without this, students see 0
   models in the chat interface even after a successful login. Added table of 3 models with exact
   Visibility=Public setting. Flagged as required.
3. **§8.2 wrong:** generate-cards.sh "produces PDF" → corrected to "produces markdown files".
4. **§8.5–8.6 missing:** Added `provision-all.sh` one-command provisioner and `push-env.sh` usage
   documentation.

### D3 — Delete test users in Open WebUI

Removed Test Student A (`test.a@example.com`) and Test Student B (`test.b@example.com`) via the OW
admin API. Admin user list now shows only the 4 production accounts: admin + 3 cohort-1-2026
students.

### D4 — Upgrade Open WebUI v0.5.20 → v0.9.5

Research confirmed: no env var renames, admin API endpoints unchanged, filter functions compatible.
One breaking behavior: PersistentConfig vars (ENABLE_SIGNUP, DEFAULT_USER_ROLE) are now stored in
the database after first run — env vars do not override admin panel settings on subsequent restarts.

Upgrade procedure:

1. Updated `OPENWEBUI_VERSION=0.9.5` in local `.env` and `.env.example`
2. `bash scripts/push-env.sh` — synced `.env` to VM
3. Freed disk space on VM: stopped old container, removed old image (freed ~6GB), cleared build
   cache. VM went from 76% full to 43% full.
4. Pulled new image and started container:
   `docker compose pull open-webui && docker compose up -d open-webui`
5. Container healthy within 60 seconds. All student accounts and chat history preserved (volume
   mount unchanged).

Verified: admin login, student login, all 3 models visible and responding, chat history intact.

New capability unlocked: **Direct Connections** is disabled by default in v0.9.5 — students have no
connections option in their settings UI. The gap that existed in v0.5.20 is closed without any
configuration required.

### D5 — Key rotation live drill (OpenAI)

During D4 verification, GPT-4o mini returned HTTP 401. Root cause: the `OPENAI_API_KEY` in `.env`
was a revoked key (`sk-proj-...IiAA`) — the key had been revoked in the OpenAI dashboard but `.env`
was never updated to the replacement key created on 2026-05-12.

Followed `docs/runbooks/rotate-provider-key.md` procedure:

1. Identified active key in OpenAI dashboard (`platform.openai.com/api-keys`)
2. Updated `OPENAI_API_KEY` in local `.env`
3. `bash scripts/push-env.sh --all` — synced `.env` and restarted LiteLLM
4. Verified GPT-4o mini chat responding

Runbook worked correctly. No gaps found. Time to restore: ~3 minutes.

---

## Known limitations at close

- `docs/install.md` §12 (pre-cohort hardening checklist) remains a placeholder — deferred to
  Sprint 9.
- `docs/install.md` §9 (student site setup) still references Firebase Hosting (superseded by ADR-013
  in Sprint 4) — deferred to Sprint 9 docs pass.
- Founder Console suspend/resume not verified against OW v0.9.5 — the admin API endpoints are
  unchanged per research, but a live pause/resume test should be done before cohort-2.

---

## Lessons

- Open WebUI v0.9.5 disables Direct Connections by default — no configuration needed to lock down
  student API access.
- PersistentConfig in v0.9.5 means env vars only take effect on first container start. Subsequent
  restarts use the database values. Use admin panel for configuration changes after initial deploy.
- VM disk management: a 19GB boot disk fills up across Docker image pulls. Before major image
  upgrades, always check `docker system df` and free the old image first.
- Revoked provider keys do not surface as errors until a request is made — the platform appears
  healthy until a student hits the affected model. Monitor all 3 models after any key rotation.
