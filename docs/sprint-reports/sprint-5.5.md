# Sprint 5.5 — Completion Report

**Version:** v0.5.5 **Date:** 2026-05-12 **Goal:** Founder Console — single-pane operator dashboard
at `founder.${DOMAIN}` for cohort management without SSH.

---

## Summary

Sprint 5.5 shipped the Founder Console: a FastAPI + HTMX web application that gives the operator a
mobile-friendly view of the entire cohort and one-click controls for pausing students, resuming
them, and topping up budgets. All writes go directly to Postgres (same pattern as Sprint 5's
`weekly-cap-enforcer.sh`) because plaintext virtual keys are not stored on the VM.

---

## Deliverables

### D1 — Architecture research (DONE)

Key decisions locked:

- **Open WebUI pause deferred.** OW v0.5.20 admin API for account disable is unverified (BACKLOG
  notes a known form-update bug). "Pause" = LiteLLM key block only. Chat suspend is manual via
  `admin.${DOMAIN}/ui`. Documented in dashboard footer and CHANGELOG.
- **Auth:** bcrypt password form + itsdangerous `TimestampSigner` cookie, 8-hour TTL. One new env
  var: `FOUNDER_CONSOLE_SECRET_KEY`. `FOUNDER_CONSOLE_PASSWORD_HASH` was already in `.env.example`
  from Sprint 0 scaffolding.
- **Slot manifest:** `provision-sites.sh` writes `/srv/students/<slot>/.student` containing the
  student slug. Founder Console reads these at request time (no cache) via `os.scandir`.
- **`/health` is DB-free** — lazy DB connection, CI-friendly without a live Postgres instance.

### D2 — `services/founder-console/` (DONE)

Ten files across the FastAPI application:

| File                           | Lines | Purpose                                          |
| ------------------------------ | ----- | ------------------------------------------------ |
| `Dockerfile`                   | 20    | `python:3.12-slim` + uvicorn entrypoint          |
| `requirements.txt`             | 7     | 7 pinned packages                                |
| `app/main.py`                  | 80    | App init, `/health`, `/login`, `/logout`         |
| `app/auth.py`                  | 70    | bcrypt verify, itsdangerous cookie               |
| `app/db.py`                    | 185   | 3 read queries + slot manifest + site-live check |
| `app/actions.py`               | 90    | Postgres writes: block/unblock/topup             |
| `app/routes/dashboard.py`      | 50    | `GET /` dashboard                                |
| `app/routes/student.py`        | 115   | 5 HTMX action endpoints                          |
| `app/templates/base.html`      | 80    | Layout + all CSS (mobile-first, no framework)    |
| `app/templates/login.html`     | 20    | Password form                                    |
| `app/templates/dashboard.html` | 120   | Student grid + cohort summary + HTMX buttons     |

Total Python: ~590 lines. Templates: ~220 lines. Well under the 1,500-line ADR-008 target.

Student grid columns: slug, status badge, total spend, budget + progress bar, 24h IDE spend, 7d IDE
spend, slot (from `.student` manifest), site live link (from `index.html` presence check),
pause/resume + topup actions.

HTMX action pattern: every button `POST`s to its endpoint; the response is a small HTML fragment
that replaces `#flash` — no full-page reload. Confirm dialogs guard destructive actions (pause
student, pause cohort).

### D3 — Docker + Caddy integration (DONE)

`infra/docker-compose.yml`: `founder-console` service added after `open-webui`. Builds from
`../services/founder-console/`, mounts `/srv/students:ro`, depends on `postgres` healthy,
health-checks `/health` every 10s.

`infra/Caddyfile.tmpl`: `founder.${DOMAIN}` block added with the same
`@allowed remote_ip ${FOUNDER_ALLOWED_IP}` pattern as `admin.${DOMAIN}`. Returns 403 from any
non-allowlisted IP.

`.env.example`: `FOUNDER_CONSOLE_SECRET_KEY` added to the Sprint 5.5 section.

### D4 — `provision-sites.sh` slot manifest (DONE)

One additional `gcloud compute ssh` call per slot writes
`printf '%s' '${slug}' | sudo tee /srv/students/$slot/.student > /dev/null`. Follows the existing
`</dev/null` + error-exit pattern. Dry-run log message updated.

### D5 — CI (DONE)

`.github/workflows/ci-sprint55-founder-console.yml` (80 lines). Triggers on
`services/founder-console/**` and `infra/docker-compose.yml` changes. Tests:

1. `docker build` — image builds cleanly
2. Container start + 30s readiness poll
3. `/health` response body is `{"status": "ok"}`
4. `/login` (GET) returns 200 — auth form renders
5. `/` (GET) returns 302 → `/login` — auth gate working

No live Postgres or GCS needed; DB connection is lazy.

### D6 — Documentation (DONE)

- `docs/install.md` §10 — filled in (credentials, DNS A record, build/deploy, verify actions, IP
  lockout test)
- `docs/architecture.md` — Founder Console row updated; header updated to Sprint 5.5
- `docs/PROJECT_BRIEF.md` — v0.5.5; version history row added
- `CHANGELOG.md` — v0.5.5 Added/Changed/Deferred sections

---

## Known limitations and BACKLOG items

**OW account suspend not implemented.** Pause blocks the LiteLLM virtual key (IDE/Continue.dev).
Chat via Open WebUI continues until the operator manually disables the OW account at
`admin.${DOMAIN}/ui`. Dashboard footer and CHANGELOG document this gap. Sprint 6 item: verify OW
admin API user-disable endpoint, implement `set_student_ow_disabled()` in `actions.py`.

**Dashboard does not auto-refresh.** After a pause/resume action, the `#flash` message updates via
HTMX, but the student's status badge in the grid does not change until the operator refreshes the
page. An HTMX `hx-get="/"` poll or a full-row re-render after action would fix this. Sprint 6 polish
item.

**Slot column empty until `provision-sites.sh` is re-run.** Existing cohorts provisioned before
Sprint 5.5 do not have `.student` files. Re-running `provision-sites.sh` writes them. Documented in
`docs/install.md §10.5`.

---

## Lessons captured

- `itsdangerous.TimestampSigner` provides expiry-aware cookie signing in ~5 lines; no session DB
  needed for a single-operator tool.
- FastAPI `app.state` is the clean way to share a `Jinja2Templates` instance across routers without
  a global import.
- Jinja2 3.1+ supports `[a, b]|min` and `[a, b]|max` list filters natively — no custom filter needed
  for capping progress bar widths.
- HTMX `hx-post` on a `<button>` (not inside a form) sends no body by default. For the topup amount,
  a `<form>` wrapping the input + button is correct and cleaner than `hx-vals`.
- Docker `build.context` in Compose can point one level up (`../services/founder-console`) — the
  context is relative to the Compose file, not the working directory.
