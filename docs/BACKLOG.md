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
