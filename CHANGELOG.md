# Changelog

All notable changes to this project are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Each release is tagged in git.

---

## [Unreleased]

## [v0.5.5] — 2026-05-12 — Sprint 5.5 wrap

### Added

- `services/founder-console/` — FastAPI + HTMX operator dashboard at `founder.${DOMAIN}`; bcrypt
  password form + itsdangerous signed cookie (8-hour session); IP-locked via Caddy
- `services/founder-console/app/main.py` — app entry, `/health`, `/login`, `/logout`
- `services/founder-console/app/auth.py` — bcrypt password verify, cookie sign/verify
- `services/founder-console/app/db.py` — read queries: student grid, cohort summary, slot manifest
  (`/srv/students/*/.student`), site-live check
- `services/founder-console/app/actions.py` — Postgres writes: block/unblock key, topup
  `max_budget`, cohort-wide block/unblock (direct UPDATE; plaintext key not needed)
- `services/founder-console/app/routes/dashboard.py` — `GET /` (student grid + cohort summary)
- `services/founder-console/app/routes/student.py` — `POST /students/{slug}/pause|resume|topup`,
  `POST /cohort/pause|resume`; responses are HTMX HTML fragments swapped into `#flash`
- `services/founder-console/app/templates/` — `base.html`, `login.html`, `dashboard.html`;
  mobile-friendly system-font CSS; budget progress bars (green → amber 70% → red 90%); confirm
  dialogs on destructive actions
- `services/founder-console/Dockerfile` — `python:3.12-slim`, uvicorn ASGI entrypoint
- `services/founder-console/requirements.txt` — 7 pinned packages: fastapi, uvicorn, jinja2,
  python-multipart, psycopg2-binary, bcrypt, itsdangerous
- `.github/workflows/ci-sprint55-founder-console.yml` — Docker build + `/health` JSON check +
  `/login` 200 + `/` → 302 redirect; no live Postgres or Cloud SDK needed
- New env var in `.env.example`: `FOUNDER_CONSOLE_SECRET_KEY`

### Changed

- `infra/docker-compose.yml` — added `founder-console` service (builds from source; mounts
  `/srv/students:ro`; depends on `postgres` healthy; health check on `/health`)
- `infra/Caddyfile.tmpl` — added `founder.${DOMAIN}` block with `@allowed remote_ip` allowlist;
  header comment updated to "Five route patterns"
- `scripts/provision-sites.sh` — added `gcloud compute ssh` call per slot to write
  `/srv/students/<slot>/.student` slug manifest (Founder Console slot lookup)
- `docs/install.md` — §10 filled in (credentials, DNS, build/deploy, verify dashboard + actions)
- `docs/architecture.md` — Founder Console status updated to "Built"; header updated to Sprint 5.5
- `docs/PROJECT_BRIEF.md` — version updated to v0.5.5; version history row added

### Deferred to BACKLOG

- Open WebUI account suspend via Founder Console — OW v0.5.20 admin API for disabling users is
  unverified (known UI quirk per BACKLOG). Pause currently blocks the LiteLLM virtual key only (cuts
  IDE/Continue.dev). Chat suspend requires manual action via `admin.${DOMAIN}/ui`. Sprint 6.

## [v0.5.0] — 2026-05-12 — Sprint 5 wrap

### Added

- `scripts/daily-summary.sh` — daily Slack report posting cohort cumulative spend + per-student 24h
  IDE activity (via virtual keys) + chat activity aggregate (via Open WebUI UUID) to
  `#cultivlab-reports`; idempotency sentinel at `/var/log/cultivlab/`; `--dry-run` / `--force`
- `scripts/weekly-cap-enforcer.sh` — enforces 7-day rolling budget per student; blocks over-limit
  keys via direct Postgres UPDATE on `LiteLLM_VerificationToken`; alerts `#cultivlab-budget`;
  idempotent (already-blocked keys skipped); `--dry-run`
- `scripts/backup-postgres.sh` — nightly pg_dump → gzip → GCS; SHA-256 sidecar upload; three
  retention tiers (daily 30d, weekly 90d, monthly 365d); rotation on every run; EXIT trap posts
  failure to `#cultivlab-platform`; `--dry-run` / `--force`; idempotency via `gsutil stat`
- `scripts/restore-postgres.sh` — Phase 1 (download, checksum verify, temp DB sanity, drop) + Phase
  2 (`--force`: stop services, drop/recreate prod DB, restore, restart); `read -r < /dev/tty`
  confirmation requiring `"RESTORE"`; `--dry-run`
- `scripts/install-crontab.sh` — idempotent installer; writes `/etc/cron.d/cultivlab-ops` (23:00,
  23:30, 02:00 UTC, PATH includes `/snap/bin`) + `/etc/logrotate.d/cultivlab-ops` (14-day
  retention); verifies scripts exist; checks cron daemon active; `--dry-run`
- `.github/workflows/ci-sprint5-scripts.yml` — CI dry-run coverage for all five Sprint 5 scripts
  (separate workflow to stay under 300-line per-file limit)
- `docs/runbooks/backup-restore.md` — backup overview, Phase 1 and Phase 2 restore procedures,
  pre-restore checklist, post-restore verification, troubleshooting table
- `docs/runbooks/cohort-health-check.md` — automated check overview, manual full-stack check (9
  steps), pre-cohort checklist, during-cohort daily scan, manual student unblock procedure
- `docs/install.md §11` — cron monitoring setup: GCS bucket creation, `install-crontab.sh` usage,
  per-script manual verification, Phase 1 restore sanity test
- `docs/sprint-reports/sprint-5.md` — Sprint 5 completion report
- New env vars in `.env.example`: `POSTGRES_CONTAINER`, `LITELLM_CONTAINER`, `OPENWEBUI_CONTAINER`,
  `GCS_BACKUP_BUCKET`

### Changed

- `.env.example` — removed duplicate `LITELLM_ADMIN_URL=` entries (BACKLOG fix); added Sprint 5 cron
  section with 4 new env vars
- `docs/architecture.md` — current state updated to Sprint 5; cron monitoring layer and GCS backup
  bucket added to component inventory
- `docs/PROJECT_BRIEF.md` — version updated to Sprint 5 / v0.5.0; version history filled in for all
  sprints; current version description rewritten for v0.5.0
- `docs/install.md` — §11 renamed to §12 (pre-cohort hardening); new §11 added (cron setup)

### Fixed

- `scripts/backup-postgres.sh` / `scripts/restore-postgres.sh` EXIT trap: replaced bare `[[ ]]` with
  `if/then` guard to prevent false-conditional exit code bleed under `set -e`
- `scripts/daily-summary.sh` dry-run: `mkdir -p "$LOG_DIR"` now guarded to live-mode only

### Verified

- All five Sprint 5 scripts pass `bash -n` syntax check
- All five scripts exit 0 on `--dry-run` in CI sandbox
- `backup-postgres.sh` correctly activates weekly and monthly upload tiers (simulated Sunday + 1st)
- `weekly-cap-enforcer.sh` correctly classifies over-budget, already-blocked, and under-budget keys
- `restore-postgres.sh` Phase 1 + Phase 2 dry-run output verified
- `install-crontab.sh` correctly embeds SCRIPT_DIR, verifies script executability, prints cron +
  logrotate files

## [v0.4.0] — 2026-05-11 — Sprint 4 wrap

### Added

- Slot-based student site subdomains `l01.${DOMAIN}` through `l06.${DOMAIN}` with auto-HTTPS via
  Lets Encrypt (ADR-013)
- `scripts/provision-sites.sh` — assigns cohort students to slots, customizes index.html per
  student, deploys to VM via gcloud scp + ssh
- `scripts/generate-cards.sh` — joins cohort-students + cohort-slots CSVs on slug, renders
  per-student onboarding markdown cards with embedded Continue.dev YAML config
- `templates/student-starter/` — single-page HTML starter template + kid-friendly README
- `templates/continue-config/config.yaml.tmpl` — Continue.dev VS Code config template with 3 models
  (Claude Sonnet, GPT-4o Mini, Gemini Flash) all routed through LiteLLM
- ADR-013 (Caddy + VM filesystem for student site slots, supersedes ADR-005)
- CI workflow: 2 new dry-run steps for provision-sites.sh and generate-cards.sh
- `docs/sprint-reports/sprint-4.md` — Sprint 4 completion report (173 lines)
- 6 Lets Encrypt certificates auto-acquired for slot subdomains
- 6 DNS A records at GoDaddy for l01-l06.cultivlab.com

### Changed

- `infra/Caddyfile.tmpl` — added slot block serving l01-l06.${DOMAIN}, updated header comment to
  "Four route patterns"
- `infra/docker-compose.yml` — added /srv/students:/srv/students:ro volume mount to caddy service
- `docs/architecture.md` — marked ADR-005 as SUPERSEDED by ADR-013
- `docs/PROJECT_BRIEF.md` — version updated to Sprint 4 / v0.4.0
- `.gitignore` — added patterns for cohort-students*.csv, cohort-slots*.csv, onboarding-cards-\*/

### Verified

- l01.cultivlab.com through l06.cultivlab.com all serve via HTTPS with valid Lets Encrypt certs
- Student-starter template deployed to l01, renders correctly, button JS works
- 3-student test cohort fully provisioned end-to-end: cohort-students + cohort-slots CSVs +
  onboarding cards with embedded config
- CI all green on commit `1c99f55` (Lint, Secret Scan, CI — bootstrap)
- provision-sites.sh deploys ALL students after bash stdin-consumption bug fix
- generate-cards.sh CSV join works on both Mac bash 3.2 and Ubuntu CI bash 5

### Lessons captured

- Caddy v2 does not support regex in site addresses; use explicit comma-separated hostnames +
  `{labels.N}` placeholder
- `docker compose up -d` does NOT restart already-running containers; explicit `restart` needed to
  pick up Caddyfile changes
- `gcloud compute ssh` consumes loop stdin without `</dev/null` redirect (classic bash subshell
  pitfall)
- macOS default bash 3.2 lacks associative arrays; use awk for portable CSV joins
- Firebase Hosting does not support wildcard subdomains; per-domain manual setup with 24h cert wait
  (confirmed 2026-05-11)

## [v0.3.0] — 2026-05-10 — Sprint 3 wrap

### Added

- Open WebUI deployed as the student-facing chat surface at `chat.${DOMAIN}`
- `infra/open-webui/functions/cultivlab_user_injection.py` — Filter Function injecting `user` field
  per request (ADR-011)
- `infra/litellm/callbacks/safety_moderation.py` — LiteLLM CustomLogger callback for real-time
  content moderation via OpenAI `omni-moderation-latest` (ADR-012)
- `scripts/provision-students.sh` — idempotent Open WebUI account provisioning from cohort-keys CSV
- `scripts/lib/openwebui_admin.sh` — Open WebUI admin API wrapper (signin, user CRUD, dry-run
  support)
- ADR-011 (Open WebUI Filter Function design)
- ADR-012 (LiteLLM safety moderation callback design)
- `docs/BACKLOG.md` — running list of deferred work
- `docs/sprint-reports/sprint-3-plan.md` — Sprint 3 deliverables with hard STOP gates
- `docs/sprint-reports/sprint-3.md` — completion report
- Caddy `chat.${DOMAIN}` route with auto-HTTPS (public, no IP allowlist)
- CI workflow: Open WebUI + safety env stubs in synthesized .env, plus
  `provision-students.sh --dry-run` step
- 4 new env vars: `OPENWEBUI_SECRET_KEY`, `OPENWEBUI_ENABLE_SIGNUP`, `OPENWEBUI_DEFAULT_USER_ROLE`,
  `SAFETY_LOG_ONLY`, `SAFETY_MODERATION_DISABLED`

### Changed

- `infra/docker-compose.yml` — added `open-webui` service + `openwebui-data` volume + callbacks
  mount
- `infra/litellm/config.yaml` — registered safety_moderation callback
- `infra/Caddyfile.tmpl` — added `chat.${DOMAIN}` block
- `.env.example` — removed obsolete `OPENWEBUI_ENABLE_USER_TRACKING`, added Sprint 3 + safety vars
- `docs/PROJECT_BRIEF.md` — version updated to Sprint 3 / v0.3.0
- `docs/architecture.md` — Open WebUI status updated from "Not built" to "Live"

### Verified

- Open WebUI serves at `https://chat.cultivlab.com` with valid Let's Encrypt TLS
- Filter Function injects user UUID on every chat call (verified via LiteLLM Customer Usage)
- `provision-students.sh` created 2 test-cohort accounts idempotently (first run new=2, second run
  kept=2)
- Safety moderation blocks flagged content (verified with deliberate self-harm prompt; Slack alert
  fired)
- CI all green on commit `146387e`

## [v0.2.0] — 2026-05-09 — Sprint 2 wrap

### Added

- `scripts/provision-cohort.sh` — idempotent cohort team + per-student virtual key provisioning from
  `students.csv`
- `scripts/lib/litellm_admin.sh` — LiteLLM admin API wrapper (team + key CRUD, dry-run support)
- `scripts/lib/students_csv.sh` — pure-bash CSV parser with validation + iteration
- `scripts/test-slack-alerts.sh` — smoke tests all 5 Slack webhook channels
- `templates/students.csv.example` — 3-row CSV with placeholder data
- `docs/install.md` §6 — provider master-cap setup, cohort provisioning, Slack verification, key
  management
- `LITELLM_ADMIN_URL` env var (defaults to `https://api.${DOMAIN}`)

### Changed

- CI bootstrap workflow uses `python -c "urllib.request.urlopen(...)"` instead of curl (LiteLLM
  image is wolfi-based, no curl)
- Pre-commit prettier hook switched to `rbubley/mirrors-prettier` v3.8.3 to match CI version exactly
- All pre-commit hook versions updated via `pre-commit autoupdate`
- `.env.example` sync check narrowed to `infra/docker-compose.yml` + `infra/Caddyfile.tmpl` (was
  scanning shell scripts and producing false positives on internal vars)

### Fixed

- shellcheck SC2034 warnings on lib files (added `# shellcheck disable=SC2034 # used externally`
  directives)
- shellcheck SC2155 warning in `session.sh` (split `readonly REPO_ROOT="$(cmd)"` into two lines)
- Executable bits restored on `session.sh` and `scripts/lib/common.sh` (lost during awk-based edits)
- `.DS_Store` files removed from repo and added to `.gitignore`

### Added

- Repository scaffold: `README.md`, `LICENSE` (Apache 2.0), `.gitignore`, `CONTRIBUTING.md`
- `.env.example` — all env vars across all 7 sprints, with comments and REQUIRED/OPTIONAL markers
- `.pre-commit-config.yaml` — gitleaks, shellcheck, shfmt, prettier
- `CLAUDE.md` — project-specific AI agent context (<200 lines)
- `session.sh` — Mac clipboard context generator for Claude sessions
- `.claude/settings.json` — committed hooks and permissions
- `.claude/commands/` — `/project:review`, `/project:fix-issue`, `/project:deploy` slash commands
- `docs/PROJECT_BRIEF.md` — live project state document (v0.0.1)
- `docs/CLAUDE_SYSTEM_PROMPT.md` — master engineering standards prompt
- `docs/SESSION_STARTER.md` — per-task context template
- `docs/DECISION_LOG.md` — ADR-001 through ADR-010 (fully written)
- `docs/architecture.md` — current state (nothing built), deferred components
- `docs/install.md` — skeleton with section headings
- `docs/operations.md` — skeleton with section headings
- `docs/student-onboarding.md` — skeleton with section headings
- `docs/security.md` — skeleton with section headings
- `docs/runbooks/` — placeholder directory
- `docs/sprint-reports/sprint-0.md` — completion report
- `.github/workflows/lint.yml` — prettier, shellcheck, shfmt on push/PR
- `.github/workflows/secrets.yml` — gitleaks on push/PR
- `tests/smoke/smoke-test.sh` — placeholder smoke test
- Empty scaffolding dirs: `infra/`, `scripts/`, `scripts/lib/`, `student-starter/`, `templates/`,
  `services/`

### Architecture decisions recorded

- ADR-001: LiteLLM as the only LLM gateway
- ADR-002: Single VM + Docker Compose (not Kubernetes)
- ADR-003: Postgres as the only database
- ADR-004: Caddy for HTTPS
- ADR-005: Firebase Hosting for student sites
- ADR-006: Open WebUI for chat UI
- ADR-007: Continue.dev as in-IDE student AI
- ADR-008: Custom Founder Console for cohort operations
- ADR-009: Three-layer budget caps
- ADR-010: Slack as primary alerting channel

---

## Template for future releases

```
## [vX.Y.Z] — Sprint N — YYYY-MM-DD

### Added
### Changed
### Fixed
### Removed
### Security
```
