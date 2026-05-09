# Changelog

All notable changes to this project are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Each release is tagged in git.

---

## [Unreleased]

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
