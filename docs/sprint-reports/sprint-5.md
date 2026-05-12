# Sprint 5 — Completion Report

**Version:** v0.5.0 **Date:** 2026-05-12 **Goal:** Operational hygiene that becomes load-bearing
once a real cohort runs.

---

## Summary

Sprint 5 shipped the monitoring and backup layer. The platform can now run a real cohort with
nightly cost visibility, automatic budget enforcement, and recoverable Postgres backups. No operator
manual intervention is needed for day-to-day operations — the three cron jobs handle reporting,
enforcement, and backup autonomously.

---

## Deliverables completed

### D1 — Architecture research (DONE)

Verified `LiteLLM_SpendLogs` schema from installed litellm==1.57.3 Prisma schema. Confirmed spend
attribution split (ADR-011): chat via Open WebUI uses master key (user = OW UUID, team_id = NULL);
IDE via Continue.dev uses student virtual key (api_key = hashed token, team_id = cohort).

Key design decisions locked:

- Block keys via direct Postgres UPDATE (plaintext not stored on VM; `/key/block` API requires it)
- Crontab over systemd timers (simpler for three non-interdependent scripts)
- GCS bucket with tiered retention (30/90/365 days)
- Always post daily summary even on zero activity ("No activity. Cron is healthy.")

### D2 — `scripts/daily-summary.sh` (DONE, 283 lines)

Three SQL queries (team totals, per-student IDE activity, chat aggregate). Slack message with
monospace student table. Idempotency sentinel. `--dry-run` uses stub data. Exit 0/1/2.

### D3 — `scripts/weekly-cap-enforcer.sh` (DONE, 255 lines)

7-day rolling spend query. Per-key branching: over-budget → block via
`UPDATE LiteLLM_VerificationToken SET blocked = true`; already-blocked → skip; under budget → skip.
Slack alert only when new blocks occur. Exit 0/1/2.

### D4 — `scripts/backup-postgres.sh` (DONE, 228 lines)

pg_dump inside container piped through gzip to temp file. SHA-256 sidecar. Three-tier GCS upload.
Rotation via gsutil ls + filename date comparison. EXIT trap posts failure Slack. Idempotency via
`gsutil stat`. `--dry-run` / `--force`. Exit 0/1/2.

### D5 — `scripts/restore-postgres.sh` (DONE, 250 lines)

Phase 1: download + checksum verify + temp DB restore + table count sanity + drop. Phase 2
(`--force`): confirmation prompt (`read < /dev/tty`, requires "RESTORE"), stop services, drop +
recreate prod DB, restore, restart services. Exit 0/1/2.

### D6 — `scripts/install-crontab.sh` (DONE, 142 lines)

Writes `/etc/cron.d/cultivlab-ops` (PATH includes `/snap/bin` for gsutil) and
`/etc/logrotate.d/cultivlab-ops`. Verifies scripts exist and are executable. Checks cron daemon.
`--dry-run`. Exit 0/1.

### D7 — CI (`ci-sprint5-scripts.yml`) (DONE, 107 lines)

Separate workflow (kept `ci-bootstrap.yml` under 300 lines). Five dry-run steps covering all new
scripts. Tool checks (jq/gsutil) gated to live-mode so CI runner needs no Cloud SDK.

### D8 — Documentation (DONE)

- `docs/install.md §11` — cron setup + verification (6 subsections)
- `docs/runbooks/backup-restore.md` — backup overview, Phase 1 + Phase 2 procedures, troubleshooting
- `docs/runbooks/cohort-health-check.md` — automated + manual checks, pre-cohort checklist, unblock
  procedure
- `docs/sprint-reports/sprint-5.md` — this file
- `docs/architecture.md` — current state updated to Sprint 5; cron + GCS in component inventory
- `docs/PROJECT_BRIEF.md` — v0.5.0; full version history
- `CHANGELOG.md` — v0.5.0 entry

---

## Files changed

| File                                       | Type     | Lines     |
| ------------------------------------------ | -------- | --------- |
| `scripts/daily-summary.sh`                 | New      | 283       |
| `scripts/weekly-cap-enforcer.sh`           | New      | 255       |
| `scripts/backup-postgres.sh`               | New      | 228       |
| `scripts/restore-postgres.sh`              | New      | 250       |
| `scripts/install-crontab.sh`               | New      | 142       |
| `.github/workflows/ci-sprint5-scripts.yml` | New      | 107       |
| `docs/runbooks/backup-restore.md`          | New      | ~130      |
| `docs/runbooks/cohort-health-check.md`     | New      | ~140      |
| `docs/sprint-reports/sprint-5.md`          | New      | this file |
| `.env.example`                             | Modified | +13       |
| `docs/install.md`                          | Modified | +80       |
| `docs/architecture.md`                     | Modified | +4        |
| `docs/PROJECT_BRIEF.md`                    | Modified | +12       |
| `CHANGELOG.md`                             | Modified | +68       |

---

## Bugs fixed

- `daily-summary.sh` dry-run: `mkdir -p "$LOG_DIR"` was running unconditionally (before dry-run
  branch); fixed with live-mode guard.
- `backup-postgres.sh` + `restore-postgres.sh` EXIT traps: bare `[[ ]]` returning false caused exit
  code bleed under `set -e`; fixed with `if/then`.
- `.env.example` duplicate `LITELLM_ADMIN_URL=` entries (BACKLOG item) removed.

---

## Lessons

- `set -e` + EXIT trap: a false `[[` in a cleanup function can change the script's effective exit
  code. Use `if/then` for all conditional cleanup.
- `gsutil` tool check must be guarded to live-mode for CI to pass without Cloud SDK installed.
- `/etc/cron.d/` format requires a `user` field in column 6; root user crontab does not.
- `read -r < /dev/tty` correctly prompts interactively even when stdin is redirected.
- Single CI workflow file for 5 new scripts kept `ci-bootstrap.yml` under the 300-line limit.

---

## Known issues / deferred to backlog

- `daily-summary.sh`: chat activity section cannot resolve student names from Open WebUI UUIDs on
  the VM (plaintext students CSV is on operator's Mac). Per-student chat breakdown requires the
  Founder Console (Sprint 5.5).
- `weekly-cap-enforcer.sh`: does not auto-unblock keys that drop back under budget in a later week.
  Manual unblock via runbook is the current procedure.
- Logrotate setup not tested end-to-end in CI (requires `/etc/logrotate.d/` write access).
- No alerting if a cron job is silently skipped (e.g. VM rebooted before 23:00 UTC). A future
  "heartbeat" to an external uptime monitor (BACKLOG: `UPTIME_MONITOR_WEBHOOK`) would catch this.

---

## Next up — Sprint 5.5

Goal: Founder Console — operator dashboard for real-time cohort visibility, student pause/resume,
and spend drill-down without SSH access to the VM.
