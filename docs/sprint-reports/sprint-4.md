# Sprint 4 — Completion Report

**Date:** 2026-05-11 **Version:** v0.4.0 **Status:** Code complete, CI-validated, slot
infrastructure live in production.

**CI verification:** `Lint`, `Secret Scan`, and `CI — bootstrap` workflows all green on main as of
commit `1c99f55`. CI workflow now exercises `provision-cohort.sh`, `provision-students.sh`,
`provision-sites.sh`, and `generate-cards.sh` all in dry-run mode.

**Live verification:** Six student site slots (`l01.cultivlab.com` through `l06.cultivlab.com`)
deployed with valid Let's Encrypt TLS certificates. Slot l01 serves the rendered student-starter
template; slots l02-l06 are ready for assignment. End-to-end test: 3-student dummy cohort fully
provisioned with sites + onboarding cards.

---

## Objective

Each cohort student gets a personal subdomain hosting a customized starter HTML site, plus a
Continue.dev VS Code configuration wired to their LiteLLM virtual key, plus a single onboarding
markdown card containing everything they need for Day 1. Slot-based subdomain naming (l01-lNN)
preserves student privacy and supports cohort URL reuse.

This sprint departed from the original plan (Firebase Hosting per ADR-005) due to research findings
that Firebase Hosting does not support wildcard subdomains. The replacement design (Caddy + VM
filesystem with explicit per-slot hostnames) is documented in ADR-013.

---

## Every file created or modified

### New scripts

| File                         | Purpose                                                                                                                                                                                                               | Lines |
| ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- |
| `scripts/provision-sites.sh` | Reads cohort-students CSV (Sprint 3), assigns slots l01..lNN in order, customizes index.html per student, deploys to /srv/students/lNN/ on VM via gcloud scp + ssh. Idempotent, supports --dry-run, exit codes 0/1/2. | 280   |
| `scripts/generate-cards.sh`  | Joins cohort-students.csv + cohort-slots.csv on slug, renders per-student onboarding markdown including embedded Continue.dev YAML config. Writes mode-600 cards in mode-700 output directory.                        | 302   |

### New infrastructure

| File                       | Change                                                                                                                                                                                   |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `infra/Caddyfile.tmpl`     | Added slot block serving l01-l06.${DOMAIN}. Uses explicit comma-separated hostnames + `{labels.2}` placeholder for directory routing. Caddy v2 does not support regex in site addresses. |
| `infra/docker-compose.yml` | Added `/srv/students:/srv/students:ro` volume mount on the caddy service so Caddy can serve files from the VM filesystem.                                                                |

### New templates

| File                                         | Purpose                                                                                                                                                                                                     |
| -------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `templates/student-starter/index.html`       | Single-page starter site with amber theme, kid-friendly inline CSS, clear `CHANGE THIS` markers, working JS button. 86 lines.                                                                               |
| `templates/student-starter/README.md`        | Kid-friendly guide explaining what files exist, how to edit, easy first changes (title, colors, button text), how to ask Claude for help. 74 lines.                                                         |
| `templates/continue-config/config.yaml.tmpl` | Continue.dev VS Code extension config template. Three models (Claude Sonnet, GPT-4o Mini, Gemini Flash) all routed through LiteLLM via the student's API key. Variables: ${DOMAIN}, ${STUDENT_LITELLM_KEY}. |
| `templates/continue-config/README.md`        | Documents how the template is rendered per-student.                                                                                                                                                         |

### Updated docs

| File                    | Change                                                                                                                        |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `docs/DECISION_LOG.md`  | Added ADR-013 documenting the Caddy + VM filesystem choice over Firebase Hosting. Supersedes ADR-005 for static cohort sites. |
| `docs/architecture.md`  | Updated to include student slot subdomains as live infrastructure.                                                            |
| `docs/PROJECT_BRIEF.md` | Version bumped to Sprint 4 / v0.4.0.                                                                                          |
| `docs/BACKLOG.md`       | Captured Sprint 4 learnings: Caddy v2 regex limitation, docker compose up -d gotcha, bash subshell stdin pitfall.             |
| `.gitignore`            | Added patterns for cohort-students*.csv, cohort-slots*.csv, onboarding-cards-\*/. Mirrors Sprint 2's cohort-keys pattern.     |

### Updated CI

| File                                 | Change                                                                                                                                                                                                                               |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `.github/workflows/ci-bootstrap.yml` | Added two new dry-run steps for Sprint 4 scripts: `provision-sites.sh --dry-run` and `generate-cards.sh --dry-run`. Generates stub cohort-students.csv and cohort-slots.csv in CI; asserts no real CSV files are written by dry-run. |

---

## Architectural decisions (new ADRs)

### ADR-013 — Caddy + VM filesystem for student site slots

**Status:** Accepted

**Context:** Sprint 4 plan called for Firebase Hosting per ADR-005. Research during Sprint 4
Deliverable 1 confirmed Firebase Hosting does NOT support wildcard subdomains as of May 2026; each
custom domain must be explicitly added with up to 24h SSL cert acquisition delay per domain.
Combined with the privacy concern (student names in URLs = PII), this triggered a design pivot.

**Decision:** Host student sites on the existing VM, served by Caddy with explicit comma-separated
hostname site addresses (`l01.${DOMAIN}, l02.${DOMAIN}, ... { ... }`) and `{labels.2}` placeholder
routing to `/srv/students/<slot>/` on the VM filesystem. Adopt slot-based subdomain naming (l01-l99)
instead of student-named subdomains.

**Why slot-based:** Privacy (no PII in URLs), reusable across cohorts, no service-tier ceiling,
instant cert acquisition via existing Let's Encrypt setup.

**Alternatives rejected:**

- Firebase Hosting per-domain: 24h cert wait per subdomain, 20-subdomain ceiling, more vendor
  complexity.
- Wildcard `*.cultivlab.com`: Requires DNS-01 ACME challenge, requires Cloud DNS API token.
- Named subdomains (alice.cultivlab.com): PII concern for kids' platform.
- Third-party static host (Netlify, GitHub Pages): Vendor proliferation.

**Supersedes ADR-005** for static cohort sites.

---

## Decisions made beyond ADRs

| Decision                                                     | Reason                                                                                                                                                                           |
| ------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Slot count starts at 6 (l01-l06)                             | Cheap to extend later (add DNS records + Caddy hostnames). Proves architecture before full cohort.                                                                               |
| Caddy uses explicit comma-separated hostnames, not regex     | Caddy v2 does not support regex in site addresses; brackets `l[0-9][0-9]` are treated as literal hostname. Multi-host syntax (`l01, l02, l03 { ... }`) is the canonical pattern. |
| `gcloud compute ssh` requires `</dev/null` in scripted loops | Without it, ssh consumes the loop's stdin (process substitution) and the loop terminates after one iteration. Classic bash pitfall — same applies to scp.                        |
| provision-sites.sh runs on operator's Mac, scp's to VM       | Matches Sprint 2/3 operator pattern; preserves gcloud auth context on operator's machine.                                                                                        |
| generate-cards.sh uses awk for CSV join, not `declare -A`    | macOS default bash 3.2 does not support associative arrays. awk-based join works portably on both Mac and Ubuntu CI.                                                             |
| Continue.dev template includes 3 models                      | Claude Sonnet (chat), GPT-4o Mini (alternative), Gemini Flash (autocomplete). LiteLLM routes all three through the student's single API key.                                     |
| Onboarding cards are markdown, not PDF                       | Markdown is human-readable, version-controllable, embeddable in the cohort handoff workflow. PDF generation can be added later if needed.                                        |
| Cards include the full Continue.dev YAML inline              | Single artifact contains everything the student needs; reduces operator handoff steps.                                                                                           |

---

## Acceptance criteria — verification status

| Criterion                                                        | Status | Evidence                                                                                           |
| ---------------------------------------------------------------- | ------ | -------------------------------------------------------------------------------------------------- |
| 6 student slot subdomains (l01-l06) have valid Let's Encrypt TLS | ✅     | Caddy logs show successful ACME certificate issuance for all 6 hostnames.                          |
| Caddyfile slot block serves /srv/students/lNN/ correctly         | ✅     | `curl https://l01.cultivlab.com` returns the deployed HTML.                                        |
| Student-starter template renders correctly in browser            | ✅     | Manual test: button click triggers JS message, styling correct.                                    |
| provision-sites.sh dry-run validates without remote changes      | ✅     | 3-student test cohort dry-runs cleanly.                                                            |
| provision-sites.sh deploys ALL students (not just first)         | ✅     | Fixed bash stdin-consumption bug; verified all 3 test students deployed correctly.                 |
| generate-cards.sh joins CSVs correctly on slug                   | ✅     | Manual test with 3-student cohort: each card has correct name, email, password, slot URL, API key. |
| Onboarding cards have mode 600, output directory has mode 700    | ✅     | `ls -la onboarding-cards-test-cohort/` confirms.                                                   |
| Continue.dev config template renders with envsubst               | ✅     | Manual test: `${DOMAIN}` and `${STUDENT_LITELLM_KEY}` substituted correctly.                       |
| CI exercises provision-sites + generate-cards dry-runs           | ✅     | `CI — bootstrap` workflow on commit `1c99f55` ran in 1m17s with both new steps green.              |

---

## What was deferred

| Item                                                      | Where it lives                         | Why deferred                                                                                          |
| --------------------------------------------------------- | -------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Automating onboarding-cards delivery (email/print)        | BACKLOG.md "Onboarding card delivery"  | Operator manual process for now; secure transmission to parents is a design decision that needs care. |
| Tuning the starter template for older vs younger students | BACKLOG.md "Starter template variants" | Cohort-1 will inform whether single template works; curriculum can introduce complexity over weeks.   |
| Continue.dev integration smoke test                       | BACKLOG.md "Continue.dev smoke test"   | Template renders; actual VS Code integration test deferred until cohort onboarding.                   |
| Real cohort provisioning end-to-end run-through           | Sprint 6 "Pre-cohort hardening"        | Will combine Sprints 2-4 scripts in one operator workflow.                                            |
| Extending slots beyond 6 (l07-l99)                        | Operator-level task, not sprint work   | Process is: add DNS record + add hostname to Caddyfile + create directory. ~30 seconds per slot.      |

---

## Lessons captured (also in BACKLOG)

1. **Caddy v2 does not support regex in site addresses.** Bracket syntax `l[0-9][0-9]` treated as
   literal hostname. Multi-host syntax (`l01, l02 { ... }`) with `{labels.N}` placeholder is
   canonical.

2. **`docker compose up -d` doesn't restart already-running containers.** Even after Caddyfile
   changes, must explicitly `docker compose restart caddy` to pick up new config.

3. **`gcloud compute ssh` consumes loop stdin without `</dev/null`.** Classic bash pitfall. Same
   applies to `scp`. Required fix for provision-sites.sh.

4. **macOS default bash 3.2 lacks associative arrays.** Use awk for portable CSV joins; works on
   both Mac and Ubuntu CI without requiring bash 4+.

5. **Firebase Hosting does not support wildcard subdomains** (confirmed 2026-05-11). Each subdomain
   requires manual add with 24h cert wait. Slot-based subdomains on the VM are simpler and more
   flexible.

---

## What Sprint 5 requires

**Goal:** Monitoring crons, daily summaries, backups. Operational hygiene before first real cohort.

Sprint 5 deliverables (preview):

1. `scripts/daily-summary.sh` — cron reads LiteLLM_SpendLogs, posts daily Slack summary to
   `#cultivlab-reports`
2. `scripts/weekly-cap-enforcer.sh` — deactivates student keys that exceeded weekly budget
3. `scripts/backup-postgres.sh` — daily pg_dump to GCS bucket
4. `scripts/restore-postgres.sh` — tested restore procedure
5. systemd timers OR crontab entries for all three
6. CI updates
7. Documentation + sprint-5.md
8. Wrap + tag v0.5.0

Estimated: 6-7 hours focused work.

---

## What Sprint 6 will handle (pre-cohort hardening)

All BACKLOG items. Big-ticket:

- install.md sections 7-8 + new section 9 + section 10 (full operator playbook)
- Open WebUI branding (logo, name, welcome text)
- provision-students.sh password preservation fix
- Safety moderation threshold tuning
- Disable signup before real cohort
- Test cohort cleanup
- End-to-end run-through with throwaway "real" cohort
- Cohort onboarding day playbook

Estimated: 10-12 hours focused work over 2-3 sessions.
