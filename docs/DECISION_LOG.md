# Architecture Decision Log

Each entry follows the ADR format: **Context → Decision → Alternatives considered → Consequences**.
Decisions recorded here are binding. An AI coding agent encountering a task that conflicts with a
recorded decision must stop and raise the conflict rather than silently deviate.

To add a new ADR: append it to this file in the next available slot. Never modify a closed ADR —
supersede it with a new one and cross-reference both.

---

## ADR-001 — LiteLLM as the only LLM gateway

**Status:** Accepted **Sprint:** 0 (decision), implemented Sprint 2

### Context

The platform needs to expose three LLM providers (Anthropic, OpenAI, Vertex AI Gemini) to two types
of callers: students using the Open WebUI chat interface, and students using Continue.dev inside VS
Code. Both require OpenAI-compatible APIs. The operator needs per-student budget enforcement, spend
visibility, and the ability to pause individual students or the entire cohort without touching
provider accounts.

Calling providers directly from the application layer would scatter API keys across multiple
services, make cost attribution difficult, and require per-service budget logic.

### Decision

LiteLLM Proxy is the single LLM gateway. Every LLM call — from Open WebUI, from Continue.dev, from
any future service — routes through `api.${DOMAIN}`. No service in this platform calls an LLM
provider directly.

### Alternatives considered

**Direct provider calls from Open WebUI:** Open WebUI supports configuring Anthropic and OpenAI
directly. Rejected because it bypasses budget enforcement, makes spend attribution per-student
impossible, and requires each service to manage its own provider keys.

**Building a custom proxy:** Unnecessary. LiteLLM provides virtual keys, per-key budgets, RPM/TPM
limits, spend logs, a built-in admin UI, Slack alerting, and an OpenAI-compatible API. Building
equivalents would take weeks and introduce maintenance burden.

**AWS Bedrock gateway:** Not evaluated. GCP is the reference cloud; Vertex AI covers the Gemini
requirement. Bedrock would add a second cloud dependency.

### Consequences

Positive:

- Single choke point for all LLM spend — one place to enforce budgets, one place to pause.
- Per-student spend attribution works natively via the `user` field and virtual keys.
- Provider keys live in one place (LiteLLM config on the VM), not scattered across services.
- Open WebUI and Continue.dev require only an OpenAI-compatible base URL.

Negative:

- LiteLLM is a dependency we don't control. Version pinning is mandatory.
- If LiteLLM is down, all LLM access is down. Mitigated by: pinned version, documented restart
  procedure, Caddy upstream health checks.
- Operator must learn LiteLLM's admin UI and key management model.

**Binding rule:** No service in this codebase may call an LLM provider API directly. All LLM calls
must use `api.${DOMAIN}` (or `http://litellm:4000` on the internal network).

---

## ADR-002 — Single VM + Docker Compose (not Kubernetes or microservices)

**Status:** Accepted **Sprint:** 0 (decision), implemented Sprint 1

### Context

The MVP serves 12 concurrent students. The operator is a solo founder. The platform is unvalidated —
there is no certainty about what usage will look like after the cohort. Infrastructure choices made
now have a long shadow: too complex and the operator can't operate it; too crude and it can't
evolve.

### Decision

All core services (Caddy, LiteLLM, Postgres, Open WebUI, Founder Console) run as containers in a
single Docker Compose stack on a single GCP e2-small VM. No Kubernetes. No Cloud Run for the core
stack. No microservices split until iteration 4 forces it by utilization.

### Alternatives considered

**Kubernetes (GKE):** Provides auto-scaling, rolling deploys, and resilience. Rejected for MVP
because: (1) operational complexity is an order of magnitude higher; (2) cost baseline is $70+/month
before any workload; (3) 12 students do not require auto-scaling; (4) a solo founder cannot debug
GKE networking at midnight before a cohort session.

**Cloud Run for each service:** Attractive for scale-to-zero cost profile. Rejected because: (1)
LiteLLM and Open WebUI are stateful and not designed for ephemeral containers; (2) cold-start
latency is unacceptable for a student chat session; (3) Postgres on Cloud SQL adds $30+/month; (4)
not needed until utilization consistently exceeds single-VM capacity.

**Docker Swarm:** More complex than Compose with fewer benefits than Kubernetes. No advantage for a
single-node deployment.

### Consequences

Positive:

- Entire stack starts with `docker compose up -d`. No cluster to manage.
- `docker compose down && docker compose up -d` restores full state — verifiable.
- SSH to VM + `docker compose logs` is all that's needed to debug most issues.
- Cost baseline of $15–20/month (VM + disk + IP).

Negative:

- Single point of failure: if the VM fails, everything is down. Mitigated by: daily backups,
  documented restore procedure, GCP VM auto-restart policy.
- Vertical scaling only until architecture is revisited. Sufficient for cohort scale.
- No zero-downtime rolling deploys. Acceptable: maintenance windows are announced.

**Binding rule:** Do not introduce Kubernetes, Swarm, or Cloud Run for core stack services in
Sprints 0–3. Revisit in Sprint 4 if and only if VM utilization consistently exceeds 70%.

---

## ADR-003 — Postgres as the only database

**Status:** Accepted **Sprint:** 0 (decision), implemented Sprint 1

### Context

The platform has multiple services that each need persistent storage: LiteLLM needs spend logs, key
metadata, and team budgets; Open WebUI needs user accounts and conversation history; the Founder
Console needs an audit log of operator actions. Future iterations will need vector storage for RAG.

Running separate databases for each service would increase operational complexity, backup
complexity, and cost.

### Decision

Postgres is the single database engine for all services. LiteLLM, Open WebUI, and the Founder
Console all connect to the same Postgres instance (different schemas/tables, not different servers).
pgvector is added in iteration 2 for RAG — no separate vector database.

### Alternatives considered

**SQLite for LiteLLM + Postgres for Open WebUI:** LiteLLM supports SQLite. Rejected because SQLite
does not support concurrent writes from multiple containers reliably, is harder to back up
correctly, and can't be used with Row-Level Security when multi-tenancy arrives.

**Separate Postgres instances per service:** Provides stronger isolation. Rejected because: three
separate Postgres containers triple the memory footprint on e2-small; backup scripts become three
times as complex; not necessary at 12-student scale.

**Qdrant or Pinecone for vectors:** Dedicated vector databases have better performance at scale.
Rejected because pgvector is sufficient for MVP-scale RAG (single cohort, small document set),
avoids a separate service and backup target, and defers the complexity until demand is validated.

**Redis for caching:** Not needed at MVP scale. LiteLLM has its own in-memory caching.

### Consequences

Positive:

- One backup target, one restore procedure.
- One connection string (`DATABASE_URL`) shared across services.
- `LiteLLM_SpendLogs` is directly queryable for custom reports without an API.
- pgvector added with a single migration when needed — no new service.

Negative:

- All services share Postgres connection pool — a runaway query from one service can affect others.
  Mitigated by: per-service Postgres roles with connection limits, `pg_stat_statements` monitoring.
- Single Postgres instance is a SPOF. Mitigated by: daily pg_dump to GCS, documented restore
  runbook. HA Postgres deferred to iteration 4+ if demand warrants.

**Binding rule:** Do not introduce Redis, MongoDB, Qdrant, Pinecone, or any other database engine.
Use Postgres + pgvector for all persistent storage needs.

---

## ADR-004 — Caddy for HTTPS (not nginx + certbot)

**Status:** Accepted **Sprint:** 0 (decision), implemented Sprint 1

### Context

The platform needs HTTPS for all subdomains: `chat.*`, `api.*`, `admin.*`, `founder.*`, and 12
student subdomains (`<slug>.*`). SSL certificate provisioning and renewal must be automated. The
operator should not be responsible for managing certificates manually.

### Decision

Caddy is the reverse proxy and TLS terminator. It handles automatic certificate provisioning via
Let's Encrypt and certificate renewal with no operator intervention. Configuration is driven
entirely by env vars via a template (`Caddyfile.tmpl`).

### Alternatives considered

**nginx + certbot:** The traditional stack. Rejected because: (1) certbot requires cron job
management and periodic renewal testing; (2) nginx configuration for wildcard subdomains with
env-var injection requires `envsubst` or Lua — more fragile; (3) debugging SSL issues with certbot
requires more operator knowledge than Caddy's automatic provisioning.

**Traefik:** Comparable to Caddy for auto-TLS. Rejected because Caddy has a simpler configuration
syntax (Caddyfile vs. YAML + labels), better documentation for the static reverse proxy use case,
and first-class env-var support.

**Cloudflare Tunnel:** Would eliminate the need for a public IP and port 80/443 firewall rules.
Rejected because: (1) adds Cloudflare as a required dependency; (2) more complex setup; (3) not
self-deployable without a Cloudflare account.

### Consequences

Positive:

- TLS certificates provisioned automatically on first request. Zero operator action needed.
- Wildcard subdomain support via DNS-01 challenge (configured when student sites scale).
- Caddyfile is human-readable and templatable with env vars.
- Single container handles all routing and TLS for all subdomains.

Negative:

- Caddy must have ports 80 and 443 open to the internet for ACME HTTP-01 challenge.
- Let's Encrypt rate limits apply: 50 certificates per registered domain per week. Student
  subdomains use Firebase Hosting certificates, not Caddy, so this is not an issue.
- Caddy is less commonly known than nginx — operator must reference Caddy docs.

---

## ADR-005 — Firebase Hosting for student static sites

**Status:** Accepted **Sprint:** 0 (decision), implemented Sprint 4

### Context

Each of the 12 students needs a public URL at `<slug>.${DOMAIN}` serving their static HTML site. The
site must have valid HTTPS. Students deploy by running a single script from their laptop.

### Decision

Firebase Hosting is used for student static sites. Each student gets a Firebase Hosting site
configured with a custom domain (`<slug>.${DOMAIN}`). Students deploy using the Firebase CLI
(`firebase deploy`). SSL certificates for student subdomains are provisioned automatically by
Firebase.

### Alternatives considered

**GCS bucket with static website hosting:** GCS supports static websites natively. Rejected because:
GCS static website hosting does NOT support HTTPS on custom domains — it only serves HTTP.
Workarounds (load balancer in front of GCS) add $20+/month per student or require complex CDN
configuration not suitable for MVP.

**VM-hosted Caddy with static files:** Students upload files to the VM via rsync or scp. Rejected
because: (1) requires SSH access management for students — significant security surface; (2) all 12
student sites would be on the same VM, competing for disk and CPU; (3) deployment script complexity
increases.

**Netlify / Vercel:** Consumer hosting platforms. Rejected because: (1) not self-deployable —
third-party dependency; (2) account management for 12 students is operationally complex; (3)
inconsistent with the "operator controls all infrastructure" principle.

**GitHub Pages:** Rejected because: (1) requires GitHub accounts for 8–12 year olds; (2) git-based
deployment is too complex for the student experience at this age.

### Consequences

Positive:

- HTTPS on custom domains is handled automatically by Firebase — no operator cert management.
- Deployment is `firebase deploy` — one command, student-accessible.
- Sites persist after the cohort with no VM changes.
- Firebase Hosting free tier covers 12 small static sites easily.

Negative:

- Firebase is a Google dependency — partially mitigated by GCP already being the reference cloud.
- Students need the Firebase CLI installed on their laptops.
- DNS CNAME records for each student subdomain must be added at the registrar. The provisioning
  script outputs the required records; operator adds them manually.

---

## ADR-006 — Open WebUI for chat UI (configure, don't reimplement)

**Status:** Accepted **Sprint:** 0 (decision), implemented Sprint 3

### Context

Students need a web-based chat interface to talk to Claude, ChatGPT, and Gemini. The interface must
be kid-accessible (simple, no overwhelming settings), operator-controlled (no self-signup, content
moderation), and able to route to multiple providers via LiteLLM.

### Decision

Open WebUI is the student-facing chat interface. It is configured (via env vars and the admin panel)
rather than reimplemented. Key configuration: `ENABLE_SIGNUP=false`, operator creates accounts
manually, file upload and web search disabled by default, system prompt set to kid-appropriate
defaults, model names simplified to "Claude" / "ChatGPT" / "Gemini".

### Alternatives considered

**Building a custom chat UI:** Full control over UX and features. Rejected because: (1) a solo
founder cannot build and maintain a production-quality chat UI alongside the platform
infrastructure; (2) Open WebUI already does everything needed — it is an active project with a large
community; (3) building custom duplicates weeks of effort.

**LibreChat:** Another open-source chat UI. Rejected because Open WebUI has better LiteLLM
integration, more active development, and a simpler configuration model for this use case.

**Direct ChatGPT / Claude.ai interfaces:** Provider UIs don't support virtual keys, budget
enforcement, operator monitoring, or custom system prompts. Not usable.

### Consequences

Positive:

- Zero frontend code to write or maintain.
- Open WebUI's `user` field passes student identity to LiteLLM automatically, enabling per-student
  spend attribution in the LiteLLM admin dashboard.
- Model selection, conversation history, and system prompts work out of the box.
- Active upstream project — security patches and features arrive without our effort.

Negative:

- Open WebUI version upgrades may require configuration changes. Mitigated by pinned version and
  documented upgrade procedure.
- Limited control over UI aesthetics for kids — acceptable at MVP.
- Open WebUI's feature set may expose settings to students. Operator must review what is visible in
  the student role and disable features not appropriate for 8–12 year olds.

---

## ADR-007 — Continue.dev as in-IDE student AI assistant

**Status:** Accepted **Sprint:** 0 (decision), implemented Sprint 4

### Context

Students write code in VS Code on their own laptops. They need AI code assistance (autocomplete,
chat, inline edits) that routes through the platform — so the operator can apply budget caps and see
usage — rather than students using their own API keys or consumer AI products.

### Decision

Continue.dev is the VS Code extension for AI code assistance. Each student configures it with their
virtual API key and the platform's `api.${DOMAIN}` as the API base URL. Because LiteLLM is
OpenAI-compatible, Continue.dev requires only a base URL change — no custom plugin.

### Alternatives considered

**GitHub Copilot:** Does not support custom API base URLs or virtual keys. Usage cannot be monitored
or budget-capped by the operator. Students would need individual Copilot subscriptions.

**Cursor:** A full IDE replacement, not a VS Code extension. Requires students to install a new IDE,
adds complexity on Day 1, and does not support routing through the platform proxy.

**Codeium:** Does not support custom API endpoints for routing through a proxy.

**Custom VS Code extension:** Maximum control. Rejected because building and distributing a VS Code
extension is a significant engineering effort not justified at MVP.

### Consequences

Positive:

- Students use their virtual key in Continue.dev, so all their VS Code AI usage is budget- capped
  and attributed in LiteLLM's customer usage tab — same as chat usage.
- No special infrastructure required — Continue.dev treats LiteLLM as a standard OpenAI endpoint.
- Continue.dev is free and open-source; students can keep using it after the cohort.

Negative:

- Students must complete a one-time configuration step (paste API base URL and key into Continue.dev
  settings). Documented in `docs/student-onboarding.md` with screenshots.
- Continue.dev version updates may change the configuration UI. Operator verifies before each
  cohort.

---

## ADR-008 — Custom Founder Console for cohort operations

**Status:** Accepted **Sprint:** 0 (decision), implemented Sprint 5.5

### Context

The operator needs a single interface to monitor and control the cohort: see all 12 students' spend
and status, pause/resume individual students or the whole cohort, top up budgets, and check platform
health. LiteLLM's built-in admin UI provides key and spend management, but does not integrate Open
WebUI account status, Firebase deployment status, or cohort-specific context into a single view.

### Decision

A lightweight custom Founder Console is built as a FastAPI + HTMX service at `founder.${DOMAIN}`. It
is IP-locked to the operator's IP. It reads data from LiteLLM's Postgres tables (read-only role) and
calls LiteLLM, Open WebUI, and Firebase REST APIs for actions. It does not store new state — all
state lives in the existing systems.

Implementation target: under 1,500 lines total across frontend and backend.

### Alternatives considered

**LiteLLM admin UI only (`admin.${DOMAIN}`):** Provides key management and spend data. Rejected as
the sole operator interface because: (1) it does not show Open WebUI account status or Firebase
deploy status; (2) it is not mobile-friendly; (3) it lacks cohort-level context (days remaining,
top/bottom spenders, engagement signals).

**Grafana + custom dashboard:** Excellent for metrics visualization. Rejected because: (1) adds a
significant new service (Grafana + data source config); (2) dashboards are read-only — operator
cannot pause a student from Grafana; (3) overkill for 12 students.

**Slack bot for operator actions:** Mobile-friendly and familiar. Rejected as the primary interface
because: (1) requires Slack API setup; (2) harder to display tabular student data; (3) no audit log.
Slack remains the alerting channel per ADR-010.

**No custom UI (scripts only):** All operator actions via CLI scripts. Viable but rejected because a
mobile-accessible dashboard is necessary for the operator to manage the cohort outside office hours
without SSH.

### Consequences

Positive:

- Single pane of glass for cohort operations — student grid, spend, status, deploy, actions.
- Mobile-friendly: operator can pause a student from their phone.
- Built on existing data (no new truth source) — console cannot get out of sync.
- Small codebase (~1,500 lines) — auditable, maintainable by a solo founder.

Negative:

- One more container to operate and keep updated.
- Founder Console must be kept in sync with LiteLLM and Open WebUI API changes. Mitigated by:
  versioned API clients, integration smoke test in CI.

---

## ADR-009 — Three-layer budget caps

**Status:** Accepted **Sprint:** 0 (decision), implemented Sprint 2/3

### Context

LLM spend is the primary financial risk for the platform. A single student with a runaway loop, or
an attacker who obtains a virtual key, could generate significant charges. The operator needs to be
able to run the cohort without anxiety about unexpected bills, even when not actively monitoring.

### Decision

Three independent layers of budget enforcement are applied:

**Layer 1 — Per-student virtual key** (tightest):

- Daily cap: configurable via `STUDENT_DAILY_BUDGET` (default $2/day)
- Weekly cap: configurable via `STUDENT_WEEKLY_BUDGET` (default $8/week)
- Total cap: configurable via `STUDENT_MAX_BUDGET` (default $10 for cohort duration)
- Soft budget: alert fires at `STUDENT_SOFT_BUDGET` (default $8 total), request still allowed
- Hard budget: request blocked once `STUDENT_MAX_BUDGET` is reached

**Layer 2 — Cohort team budget** (middle wall):

- Configured via `COHORT_MAX_BUDGET` (default $200)
- Soft budget at `COHORT_SOFT_BUDGET` (default $150) — Slack alert fires
- Hard budget at `COHORT_MAX_BUDGET` — all cohort requests blocked

**Layer 3 — Provider master account caps** (outer wall):

- Configured directly in Anthropic, OpenAI, and Google Cloud billing consoles
- Monthly hard limits set by the operator before the cohort begins
- These caps are outside the platform and cannot be bypassed even if LiteLLM is compromised

### Alternatives considered

**Single per-student hard cap only:** Simpler. Rejected because a single malicious or confused
student could still consume the entire cohort budget before the cohort cap triggers. The daily cap
prevents one bad session from consuming a week's budget.

**No budget caps (rely on operator monitoring):** Rejected unconditionally. A solo founder cannot
monitor 12 students 24/7. Automated enforcement is the only reliable protection.

**Provider-level caps only:** Protects the operator's credit card but doesn't provide per-student
visibility or control. Rejected as insufficient for operational management.

### Consequences

Positive:

- No single student can exceed their daily/weekly/total allocation regardless of bug or abuse.
- Even if all per-student caps fail, the cohort cap stops total spend.
- Even if both LiteLLM caps fail, provider account caps stop billing.
- Soft budgets give the operator early warning before students hit hard blocks.

Negative:

- More configuration required at provisioning time. Mitigated by defaults in `.env.example` and the
  provisioning script reading from env vars.
- Hard blocks return an error to students. Mitigated by LiteLLM's configurable error response (a
  friendly "you've used your allocation for today" message).

---

## ADR-010 — Slack as primary alerting channel

**Status:** Accepted **Sprint:** 0 (decision), implemented Sprint 2

### Context

The operator needs to receive alerts for: student budget thresholds, provider errors, platform
health issues, and daily spend reports. Alerts must be actionable on a mobile device. The operator
is a solo founder who may not be at a computer when an alert fires.

### Decision

Slack is the primary alert destination. LiteLLM's native alerting system is configured with five
separate webhooks, each routing to a dedicated Slack channel:

- `#cultivlab-budget` — budget threshold alerts (80% and 100%) and cohort cap alerts
- `#cultivlab-reports` — daily spend summaries and weekly reports
- `#cultivlab-exceptions` — provider errors, LLM exceptions, slow responses
- `#cultivlab-safety` — moderation triggers, unusual login activity
- `#cultivlab-platform` — VM disk, Postgres health, SSL cert expiry

LiteLLM provides native budget alerts, spend reports, exception alerts, and outage alerts. Custom
cron jobs (Sprint 5) cover platform health and SSL expiry checks.

### Alternatives considered

**Email only:** Familiar and universally accessible. Rejected as the primary channel because: (1)
email is too slow for actionable incidents (provider down, student blocked); (2) no mobile push
notifications without additional setup; (3) Slack is already the most common async communication
tool for solo technical founders.

**PagerDuty:** Industry-standard for on-call. Rejected because: (1) adds a paid dependency; (2)
heavyweight for a 12-student cohort; (3) Slack notifications are sufficient for the response time
needed.

**Email as secondary channel:** Email is used as a secondary channel for soft-budget alerts routed
to parent emails (Sprint 5). This is in addition to Slack, not instead of it.

**Telegram / Discord:** Alternative messaging platforms. Slack is preferred because: (1) it has
mature incoming webhook support; (2) LiteLLM has native Slack integration; (3) most
technically-oriented solo founders already use Slack.

### Consequences

Positive:

- LiteLLM's native alerting covers 80% of needed alerts with zero custom code.
- Five dedicated channels make it easy to filter signal from noise on mobile.
- Slack mobile app provides push notifications — operator can respond from anywhere.
- Webhook URLs are env vars — changing the Slack workspace or channels requires no code change.

Negative:

- Slack workspace must exist and webhooks must be configured before the cohort begins. Documented in
  `docs/install.md` pre-cohort checklist.
- Slack free tier has message history limits. Not a concern for operational alerts.
- If Slack is down, alerts are lost. Mitigated by: UptimeRobot external uptime monitoring
  (independent of Slack) and operator's daily console check habit.

## ADR-011 — Open WebUI Filter Function for user-field injection (2026-05-10)

**Status:** Accepted

**Context:** Sprint 2 established per-student LiteLLM virtual keys and per-user spend attribution
via the user field on chat completion requests. Sprint 3 plans to deploy Open WebUI as the
student-facing chat surface. Verification during Sprint 3 Deliverable 1 confirmed that Open WebUI
v0.5.20 does not natively pass the user field to upstream LLM proxies. This breaks per-student
attribution and budget enforcement.

**Decision:** Use an Open WebUI Filter Function (Python plugin) to inject the user field into every
chat completion request body before it leaves Open WebUI. This restores the user-field attribution
path proven in Sprint 2.

All students share ONE Open WebUI to LiteLLM connection authenticated with the LiteLLM master key.
The Filter Function provides per-student identity. LiteLLM Customer Usage attributes spend
correctly.

**Alternatives considered:**

1. Per-user Direct Connections (each student manually configures their LiteLLM virtual key in their
   own settings). Rejected: too much configuration burden for 8-12-year-olds; high setup failure
   rate.
2. One Open WebUI connection per student (admin-managed): admin pre-creates 12 OpenAI-compatible
   connections, each with a different LiteLLM key. Rejected: doesn't isolate students. Every user
   sees all admin connections in the model dropdown. Privacy leak; students could pick another
   student key.
3. Reverse-proxy middleware between Open WebUI and LiteLLM. Rejected: adds infrastructure complexity
   without proportional benefit over the Filter Function approach.

**Consequences:**

- Sprint 3 Deliverable 3 (provision-students.sh) creates Open WebUI accounts only; does NOT assign
  per-student LiteLLM virtual keys in Open WebUI settings.
- Sprint 2 virtual keys retained for API/Continue.dev access (chat goes through Filter Function
  path).
- Filter Function must be tested at Sprint 3 Deliverable 4 boundary.
- LiteLLM enforce_user_param=true provides defense-in-depth: requests without user are rejected.

**References:**

- Sprint 3 plan: docs/sprint-reports/sprint-3-plan.md (Deliverable 1 findings section)
- Sprint 2: scripts/provision-cohort.sh
- LiteLLM config: infra/litellm/config.yaml
