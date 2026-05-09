# Sprint 2 — Completion Report

**Date:** 2026-05-09 **Version:** v0.2.0 **Status:** Code complete and CI-validated. Pending
operator verification on real GCP (deployment phase).

**CI verification:** `Lint`, `Secret Scan`, and `CI — bootstrap` workflows all green on main as of
commit `c42abaa` (CI — bootstrap) and `a4fa6fc` (Lint + Secret Scan). The bootstrap workflow
successfully spins up postgres + postgres-init + LiteLLM on a fresh Ubuntu 24.04 runner and verifies
LiteLLM is healthy via `/health/liveliness`.

---

## Objective

The operator runs one script with `students.csv` as input and ends up with: a LiteLLM "team"
carrying the cohort budget, one virtual key per student carrying their per-student caps and rate
limits, an output `cohort-keys-${COHORT_NAME}.csv` mapping slugs to plaintext keys, and verified
Slack alert wiring across all five channels. Provider master-caps are configured by the operator in
each provider's billing console and documented in `docs/install.md` §6.

---

## Every file created or modified

### New scripts

| File                           | Purpose                                                                                                                                                                                                                                                                                                               | Lines |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- |
| `scripts/lib/litellm_admin.sh` | Wraps the LiteLLM admin API. `litellm_admin_init`, `litellm_request`, team_get/create/update, key_get/create/update. Dry-run synthesizes `dry-run-team-id` + `sk-dry-run-<alias>` so callers trace the full flow without network.                                                                                     | 252   |
| `scripts/lib/students_csv.sh`  | Pure-bash CSV parser. `students_csv_validate` (header, row count vs `COHORT_SIZE`, slug regex, dup detection — exits 1 with cited line number) and `students_csv_iter` (callback per row, `STUDENT_*` defaults filled in for blank optional cells). Uses a `,X` sentinel to defeat bash's trailing-empty-field strip. | 292   |
| `scripts/provision-cohort.sh`  | Headline script. Validates env + CSV, ensures the cohort team, iterates students creating/updating keys, writes `cohort-keys-${COHORT_NAME}.csv` (mode 0600). Idempotent — re-runs reconcile budgets and preserve plaintext recorded in the prior CSV. Exit 0 / 1 / 2.                                                | 294   |
| `scripts/test-slack-alerts.sh` | Posts one synthetic message to each of the five `SLACK_WEBHOOK_*` URLs (direct curl, not via LiteLLM). Sleeps 1s between channels. Exit 0 if all five returned 200.                                                                                                                                                   | 125   |

### New templates / docs

| File                             | Change                                                                                                                                                                                                       |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `templates/students.csv.example` | New. 3-row CSV with placeholder names + `example.com` emails. Header comment lists schema, slug regex, and the no-commas-in-fields constraint.                                                               |
| `docs/install.md` §1             | Added `jq` (1.6+) to the prerequisites table — required by `provision-cohort.sh`.                                                                                                                            |
| `docs/install.md` §6             | Replaced the skeleton with §6.1 provider master-cap setup (Anthropic, OpenAI, GCP/Vertex), §6.2 cohort provisioning steps, §6.3 Slack alert verification, §6.4 where the keys live + key-rotation procedure. |
| `docs/architecture.md`           | Added the **LiteLLM cohort team** as a logical Sprint 2 component in the inventory table.                                                                                                                    |
| `.env.example`                   | One new var: `LITELLM_ADMIN_URL` (empty default; scripts fall back to `https://api.${DOMAIN}`). Operator pasted this manually because the `.claude` sensitive-writes hook blocks `.env*` edits.              |

### Updated CI

| File                                 | Change                                                                                                                                                                                                                                                                 |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.github/workflows/ci-bootstrap.yml` | Added a final job step: install `jq`, generate a stub 2-row `students.csv`, run `scripts/provision-cohort.sh --dry-run`, and assert that no `cohort-keys-*.csv` file was written. Exercises validation + dry-run code paths without needing a live LiteLLM master key. |

### Updated docs

| File                              | Change                                                                            |
| --------------------------------- | --------------------------------------------------------------------------------- |
| `docs/PROJECT_BRIEF.md`           | Version bump to v0.2.0, version history row added, "Next up" pointed at Sprint 3. |
| `docs/sprint-reports/sprint-2.md` | This file.                                                                        |

---

## Architectural decisions affirmed (no new ADRs)

- **ADR-001** — LiteLLM is the only LLM gateway. All keys created in Sprint 2 live in LiteLLM and
  authenticate against `api.${DOMAIN}`; no parallel auth paths.
- **ADR-009** — Three-layer budget caps. Layer 1 (per-student): `max_budget` for total cap,
  `soft_budget` for alert, `metadata.daily_budget` and `metadata.weekly_budget` for the Sprint 5
  windowed-cron check. Layer 2 (cohort): team `max_budget` + `soft_budget`. Layer 3 (provider
  master): documented setup in `docs/install.md` §6.1.
- **ADR-010** — Slack as primary alerting. Five webhooks smoke-tested by
  `scripts/test-slack-alerts.sh`; LiteLLM's native budget / spend / exception / DB alerts use four
  of them, `SLACK_WEBHOOK_SAFETY` is reserved for Sprint 3 moderation flow.

---

## Decisions made this sprint (beyond ADRs)

| Decision                                                            | Why                                                                                                                                                                                                                                                                                 |
| ------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `LITELLM_ADMIN_URL` defaults via `${VAR:-https://api.${DOMAIN}}`    | The `.claude` hook blocks Claude from editing `.env.example`; an empty entry there + a script-side fallback satisfies the lint env-sync check while letting operators run admin scripts without setting anything new.                                                               |
| Library function signatures take `soft_budget` positionally         | Brief listed `litellm_key_create` without `soft_budget`, but ADR-009 requires it on every key. Took `soft_budget` as a positional arg rather than coupling the lib to a specific env-var name. Same for `litellm_team_{create,update}`.                                             |
| `litellm_key_get <alias>` via `/key/list?team_id=X` + jq filter     | LiteLLM has no native "look up key by alias" endpoint. List + filter is fine at cohort scale (≤200 keys per team).                                                                                                                                                                  |
| Daily / weekly caps stored as `metadata`, not native LiteLLM fields | LiteLLM keys natively support a daily reset OR a total cap, not both. Sprint 5 cron job reads `LiteLLM_SpendLogs` for windowed enforcement; metadata fields keep the values discoverable per key in the meantime.                                                                   |
| Per-row failure mode: continue + exit 2                             | Brief allowed a flag for abort-on-first; chose simplicity. A failed row is logged, the script continues, and the operator re-runs to fix only the failed rows — same outcome with less surface area.                                                                                |
| `,X` sentinel in `students_csv.sh`                                  | Bash's `read -a` strips a single trailing empty field, so `Bea,b@x,bea,p@x,,,,,` parses as 8 fields instead of 9. Appending `,X` then dropping the last element makes parsing length-correct in all cases.                                                                          |
| `cohort-keys.csv` merge-on-re-run                                   | Plaintext virtual keys cannot be retrieved after creation. Re-runs read the existing CSV, preserve recorded plaintext for keys that still exist in LiteLLM, append new rows for keys created this run, and warn + omit rows where the key exists in LiteLLM but plaintext was lost. |
| `--dry-run` synthesizes team_id + key plaintext                     | Lets the dry-run trace the full happy path through `provision-cohort.sh` without making any network calls. Synthetic values are clearly marked (`dry-run-team-id`, `sk-dry-run-<alias>`) and the CSV write is skipped so the synthetic keys never persist.                          |
| Files at the 300-line cap                                           | `students_csv.sh` 292 / `provision-cohort.sh` 294 / `litellm_admin.sh` 252 — all under the CLAUDE.md cap. `docs/install.md` is now 409 lines after the §6 expansion; docs are exempt from the 300-line rule by convention (Sprint 1 already pushed install.md past 280).            |

---

## Acceptance criteria — verification status

| Criterion                                                                                                             | Status                                                                                                                                                                      |
| --------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `scripts/provision-cohort.sh --dry-run` runs cleanly with a valid `students.csv`, makes zero LiteLLM calls            | **Verified** (smoke test, 2-row stub CSV)                                                                                                                                   |
| `scripts/provision-cohort.sh --dry-run` exits non-zero with a structured error on duplicates / bad slugs / wrong rows | **Verified** (4 negative cases, all rc=1, line-cited)                                                                                                                       |
| `scripts/provision-cohort.sh` runs end-to-end against a real LiteLLM instance — team + N keys + CSV                   | **Pending operator** — requires live VM                                                                                                                                     |
| Re-running `scripts/provision-cohort.sh` produces no errors / no duplicates / updates budgets if changed              | **Pending operator** — code paths smoke-tested via dry-run                                                                                                                  |
| Each generated virtual key successfully calls each of the three providers via `curl /v1/chat/completions`             | **Pending operator** — requires real provider keys                                                                                                                          |
| `scripts/test-slack-alerts.sh` posts to all five channels with HTTP 200                                               | **Pending operator** — requires real webhook URLs                                                                                                                           |
| `docs/install.md` §6 is filled in with real, working content for all three provider master-cap pages                  | **Verified** (content written; URLs not auto-tested)                                                                                                                        |
| `templates/students.csv.example` is committed; `students.csv` is not (gitignored)                                     | **Verified** (`.gitignore` covers `students*.csv`)                                                                                                                          |
| CI bootstrap workflow passes with the new dry-run step                                                                | **Pending first push to main**                                                                                                                                              |
| `.env.example` is in sync with all new env vars introduced this sprint                                                | **Pending operator paste of `LITELLM_ADMIN_URL=`** — script defaults to `https://api.${DOMAIN}` if missing, but `lint.yml` env-sync check will fail until the line is added |
| `pre-commit run --all-files` passes                                                                                   | **Pending operator local run**                                                                                                                                              |
| `gitleaks detect --source .` returns clean                                                                            | **Pending operator local run**                                                                                                                                              |

---

## What was explicitly punted

- **Daily / weekly windowed budget enforcement.** ADR-009's per-student daily and weekly caps are
  stored on each key as `metadata.daily_budget` / `metadata.weekly_budget` but not natively enforced
  by LiteLLM (LiteLLM supports either a daily reset OR a total cap, not both). The Sprint 5 cron job
  reads `LiteLLM_SpendLogs` and blocks keys that exceed the windowed thresholds.
- **Mid-cohort soft-budget adjustments.** The operator can update budgets per-row by editing
  `students.csv` and re-running `provision-cohort.sh`; a mid-sprint Founder Console UI for
  per-student budget tweaks is Sprint 5.5.
- **`SLACK_WEBHOOK_SAFETY` end-to-end test.** The smoke-test posts to the webhook URL but does not
  exercise LiteLLM's wiring — Sprint 3 moderation flow lights this up.
- **Multi-CIDR webhook reachability checks.** The operator's local IP is not validated against
  Slack's IP allowlist (Slack doesn't have one for incoming webhooks).
- **Real provider call against each generated key in CI.** CI uses a stub master key — real provider
  calls require committed secrets, which we do not gate this sprint on.

---

## What Sprint 3 requires

To begin Sprint 3 verification, the operator must:

1. **Run Sprint 2 to completion on the live VM** — confirm the manual acceptance criteria,
   distribute keys via printed cards.
2. **Add `LITELLM_ADMIN_URL=`** to `.env.example` if not already pasted.
3. **Decide the kid-mode system prompt** for Open WebUI (Sprint 3 ships a default; operator may want
   to edit).
4. **Confirm cohort dates** (`COHORT_START`, `COHORT_END`) are accurate before Sprint 3
   onboarding-card generation.

Sprint 3 deliverables (preview — formal task brief at sprint start):

- Open WebUI deployed at `chat.${DOMAIN}`, signup disabled, kid-mode system prompt applied.
- `scripts/provision-students.sh` — creates one Open WebUI account per student, links each to its
  LiteLLM virtual key.
- Onboarding cards (PDF) generated per student with their key + their `chat.${DOMAIN}` login.
- Moderation pipeline wired to `SLACK_WEBHOOK_SAFETY`.
- Sprint 3 completion report.
