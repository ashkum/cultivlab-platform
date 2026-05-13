# CultivLab — Backlog

Deferred work tracked between sprints. Items here are known issues or improvements that are not
blocking current sprint goals. Move items to a sprint plan when ready to address.

## Format

Each item: title, priority (low/med/high), context, possible fixes, when-to-fix.

---

## scripts/gcp-bootstrap.sh — dry-run does real read calls

**Priority:** low **Source:** May 9, 2026 deployment session

**Context:** During `--dry-run`, `scripts/gcp-bootstrap.sh` makes real
`gcloud compute addresses describe` and similar read calls before logging "would enable APIs." On a
fresh GCP project where the Compute API isn't yet enabled, gcloud prompts the user to enable it —
blocking the dry-run.

**Workaround currently in use:** Operator types `y` when prompted; gcloud enables the API; dry-run
continues normally.

**Possible fixes (pick one when addressing):**

- Pre-enable APIs as a real step before read calls (dry-run no longer 100% read-only — slight
  philosophical compromise)
- Skip read calls entirely in dry-run mode (idempotency check happens only in real run — loses some
  preview value)
- Catch "API not enabled" errors gracefully with a clear log message and continue without the read

**When to fix:** Whenever someone is doing a fresh deploy and wants the dry-run to be truly silent.
Not blocking for current platform.

---

## .env.example — duplicate LITELLM_ADMIN_URL

**Priority:** low **Source:** May 9, 2026 deployment session

**Context:** `.env.example` has two consecutive `LITELLM_ADMIN_URL=` entries (visible when running
`grep LITELLM_ADMIN_URL .env.example`). Cosmetic — last one wins when sourced — but should be
deduplicated.

**Fix:** Delete one of the duplicate blocks.

**When to fix:** Next time anyone touches `.env.example` for any reason.

---

## OpenAI billing — manual prepaid balance setup

**Priority:** low (operator-side, not code) **Source:** May 9, 2026 deployment session

**Context:** OpenAI's billing now requires a positive prepaid balance, not just a spend limit.
Operator must add credits at https://platform.openai.com/settings/organization/billing/overview
before API calls work. Document this in install.md.

**When to fix:** During Sprint 6 (pre-cohort hardening) docs pass.

---

## Test cohort cleanup before real cohort

**Priority:** medium (must do before real cohort) **Source:** May 9, 2026 deployment session

**Context:** A test cohort `test-cohort` exists in LiteLLM with 2 student keys ($1 budget each).
Should be deleted before provisioning the real cohort to avoid name conflicts and clutter.

**Cleanup commands:**

```bash
# SSH to VM via IAP
gcloud compute ssh cultivlab-vm --tunnel-through-iap --zone us-central1-a --project cultivlab-platform

# On VM
sudo bash -c '
  source /opt/cultivlab/repo/.env
  TEAM_ID=$(curl -s -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    https://api.cultivlab.com/team/list \
    | python3 -c "import sys, json; data=json.load(sys.stdin); print(data[0][\"team_id\"]) if data else None")
  echo "Team to delete: $TEAM_ID"
  curl -s -X POST https://api.cultivlab.com/team/delete \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"team_ids\": [\"$TEAM_ID\"]}"
'
sudo rm -f /tmp/cohort-keys-test-cohort.csv /tmp/test-cohort.csv
```

**When to fix:** Right before provisioning the first real cohort.

---

## Add ADR-011 — Hybrid budget enforcement

**Priority:** medium (documents existing design) **Source:** Sprint 2 design

**Context:** Sprint 2 established that LiteLLM enforces total cohort cap and per-student total cap
natively, while daily/weekly windows will be enforced by Sprint 5 cron jobs reading
`LiteLLM_SpendLogs`. This split needs a formal ADR.

**Fix:** Add ADR-011 to `docs/DECISION_LOG.md`.

**When to fix:** During Sprint 3 documentation deliverable (folded into sprint-3.md).

---

## Open WebUI branding for chat.cultivlab.com

**Priority:** medium (do before real cohort) **Source:** May 10, 2026 Sprint 3 Deliverable 4

**Context:** The chat.cultivlab.com login/welcome page shows default Open WebUI branding (logo,
name, colors). Before students see the platform, customize to CultivLab branding.

**Tasks:**

- Customize platform name from "Open WebUI" to "CultivLab" (Admin Panel → Settings → Branding or
  similar)
- Upload CultivLab logo (need to create one)
- Custom welcome/signup text
- Custom favicon
- Possibly: custom theme colors

**When to fix:** Sprint 6 (pre-cohort hardening) or before first real cohort onboarding.

## provision-students.sh — password preservation on re-run

**Priority:** medium (must fix before real cohort) **Source:** May 10, 2026 Sprint 3 Deliverable 4

**Context:** When provision-students.sh runs against existing users (the "kept" branch), it writes
empty password to `cohort-students-${COHORT_NAME}.csv`, overwriting any previously-recorded
plaintext password. Mimics the issue provision-cohort.sh solves via `_existing_key_for_slug` helper.

**Symptom:** First run creates user with random password X, writes X to CSV. Second run detects
existing user, writes empty to CSV (overwriting X). Now we don't know the user's password.

**Fix:** Add `_existing_password_for_slug` helper that reads existing CSV before write. If row
exists with non-empty password, preserve it. Pattern matches `_existing_key_for_slug` in
scripts/provision-cohort.sh.

**When to fix:** Before first real cohort. Until fixed, NEVER re-run provision-students.sh after
passwords have been delivered to students.

## install.md sections 7-8 still placeholders

**Priority:** medium (do before real cohort) **Source:** Sprint 3 Deliverable 6

**Context:** docs/install.md §7 (Open WebUI setup) and §8 (Cohort provisioning) say "Filled in
Sprint 3" but were not actually filled in due to heredoc parsing issues during the Sprint 3 docs
session. Content is documented in docs/sprint-reports/sprint-3.md instead.

**Fix:** Rewrite sections 7-8 in install.md to cover: generating OPENWEBUI_SECRET_KEY, deploying
Open WebUI, creating admin account, installing Filter Function via admin panel, disabling signup,
running provision-cohort.sh + provision-students.sh, distributing onboarding cards.

**When to fix:** Sprint 6 docs pass (pre-cohort hardening).

## Open WebUI admin password reset doesn't work via UI

**Priority:** medium (do before real cohort) **Source:** May 10, 2026 Sprint 3 Deliverable 4 smoke
test

**Context:** Open WebUI v0.5.20 admin user edit form at
`https://chat.${DOMAIN}/admin/users/edit?id=<uuid>` does not accept password updates. Typing in the
New Password field and saving silently does nothing. Cause not yet diagnosed. Likely candidates:
form requires all fields re-touched, minimum password complexity not met silently, or a known v0.5.x
bug.

**Workarounds:**

- Delete the user and re-run provision-students.sh (loses chat history)
- Direct sqlite3 edit on the VM (last resort)
- Build `scripts/reset-student-password.sh` that uses the admin API directly

**Diagnostic steps when revisiting:**

- Open browser DevTools Network tab before clicking Save
- Look for PUT/POST request to /api/v1/users/<id>
- Check response status (4xx = validation error in response body)
- Check Console tab for JS errors

**When to fix:** Sprint 6 pre-cohort hardening. Build a reset script so we never depend on the
broken UI.

## Caddy v2 regex limitation note for docs

**Priority:** low (already implemented correctly) **Source:** Sprint 4 Deliverable 2

**Context:** Caddy v2 does not support regex in site addresses. Bracket syntax like
`l[0-9][0-9].${DOMAIN}` is treated as a literal hostname, not a regex pattern. Discovered when Caddy
refused to start with error "subject does not qualify for certificate: 'l[0-9][0-9].cultivlab.com'".

**Workaround used:** Explicit comma-separated hostname list (`l01.${DOMAIN}, l02.${DOMAIN}, ...`)
with `{labels.2}` placeholder to extract the slot identifier at request time.

**When to add to docs:** Sprint 6 install.md pass. Note in the Caddy section that adding new slots
requires editing Caddyfile.tmpl + DNS, not just creating a directory.

## docker compose up -d does not recreate running containers

**Priority:** medium (operational gotcha) **Source:** Sprint 4 Deliverable 2

**Context:** After updating Caddyfile.tmpl on the VM and running `bootstrap.sh`, the new config was
rendered but Caddy kept running with the old config because the container itself wasn't recreated.
The "Container cultivlab-caddy-1 Running" message in `docker compose up -d` output is misleading —
the container is running but with old config.

**Workaround:** Explicit `docker compose restart caddy` after Caddyfile changes.

**Fix:** Update `bootstrap.sh` to detect Caddyfile changes and force-restart caddy when the rendered
Caddyfile differs from the running container's view. OR: always restart caddy on bootstrap.sh runs
(simpler, slight downtime cost).

**When to fix:** Sprint 6 — before real cohort, when operator workflow becomes load-bearing.

## bash subshell stdin consumption pitfall

**Priority:** documentation-only (already fixed in provision-sites.sh) **Source:** Sprint 4
Deliverable 4

**Context:** `gcloud compute ssh` (and `gcloud compute scp`, ssh, curl, many tools) read from stdin
by default. In a `while ... < <(tail ...)` loop, the loop's stdin IS the source data. Without
`</dev/null` redirect on each ssh/scp call, ssh consumes the rest of the loop's input and the loop
exits after one iteration. Classic bash pitfall.

**When to document:** Add to CLAUDE.md or scripts/README.md when written. Future scripts that wrap
gcloud commands in loops must remember this.

## Onboarding card delivery automation

**Priority:** medium (do before real cohort) **Source:** Sprint 4 Deliverable 6

**Context:** `scripts/generate-cards.sh` writes markdown cards locally with mode 600. Operator
currently has to manually distribute (print, email, etc.). For a 12-student cohort this is
acceptable; for scale or multiple cohorts it becomes friction.

**Fix idea:** Add `--email` flag that uses a configured SMTP server to send each card to the
student's email (or parent's email). Or generate PDFs for printing. Or upload to a per-cohort secure
download portal.

**When to fix:** Sprint 6 pre-cohort hardening, depending on operator workflow preference.

## Continue.dev integration smoke test

**Priority:** medium (do before real cohort) **Source:** Sprint 4 Deliverable 5

**Context:** The Continue.dev config template renders correctly with envsubst. But we haven't
verified that a real student following the onboarding card instructions can actually get
Continue.dev working in VS Code and successfully chat through LiteLLM.

**Fix:** Sprint 6 — operator follows the onboarding card instructions on a clean Mac/Windows:
install VS Code, install Continue.dev extension, paste the config, ask Claude a question, verify
response comes through. Document any setup gotchas.

**When to fix:** Sprint 6 end-to-end run-through.

## Unify or symlink /opt/cultivlab/.env files

**Priority:** medium (operational risk) **Source:** 2026-05-11 OPENAI_API_KEY rotation incident

**Context:** The VM has two .env files: `/opt/cultivlab/.env` and `/opt/cultivlab/repo/.env`. Both
must be kept in sync for the platform to work correctly. Updating one and forgetting the other has
been a recurring footgun across Sprint 2-4 deployments.

**Fix:** Either (a) symlink `/opt/cultivlab/repo/.env -> /opt/cultivlab/.env` so they're literally
the same file, or (b) update bootstrap.sh to detect divergence and error out before starting
containers.

**When to fix:** Sprint 6 hardening.

## Document key rotation procedure in runbook

**Priority:** medium (do before real cohort) **Source:** 2026-05-11 OPENAI_API_KEY rotation incident

**Context:** Rotating OPENAI_API_KEY (or any provider key, or LITELLM_MASTER_KEY) currently
requires:

1. Revoke old key at provider
2. Generate new key
3. Update /opt/cultivlab/.env
4. Update /opt/cultivlab/repo/.env
5. Restart litellm container

This procedure should be a written runbook so it's executable under stress.

**Fix:** Create `docs/runbooks/rotate-provider-key.md` documenting the procedure with verification
steps.

**When to fix:** Sprint 6 docs pass.

## Upgrade Open WebUI to v0.9.5+ before next cohort

**Priority:** high (do before next cohort) **Source:** May 12, 2026 cohort-1-2026 session

**Context:** Open WebUI v0.5.20 does not have a UI toggle to prevent regular users from adding their
own model connections (Settings → Connections → Add). A student who knows their own OpenAI/Anthropic
API key could bypass LiteLLM entirely, evading budget enforcement.

v0.9.5 (current as of May 2026) adds granular user permission controls including "Allow users to add
connections." Risk is low for cohort-1-2026 (students are 8–12, unlikely to have API keys), but must
be fixed before any cohort where participants are older or more technical.

**Fix:** After cohort-1-2026 ends, upgrade Open WebUI:
```sh
cd /opt/cultivlab/infra
sudo docker compose pull open-webui
sudo docker compose --env-file /opt/cultivlab/.env up -d open-webui
```
Then in Admin Panel → Settings → Users, disable "Allow users to add connections."

**When to fix:** Before cohort-2 onboarding.

---

## .env files should never be cat'd in screensharing/chat contexts

**Priority:** low (lesson learned, documentation only) **Source:** 2026-05-11 OPENAI_API_KEY
rotation incident

**Context:** During debugging, `cat /opt/cultivlab/.env` was used which displayed the OPENAI_API_KEY
in plain text. Even in a SSH session, the output could be captured by any tool that logs terminal
contents. The operator must rotate immediately when this happens.

**Fix:** When debugging credentials, use `grep -E "^VAR_NAME" .env | sed 's/=.*/=<redacted>/'` to
confirm presence without revealing values.

**When to fix:** Add to CLAUDE.md or scripts/README.md as an operator hygiene note.
