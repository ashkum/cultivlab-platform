# CultivLab — Operator Installation Guide

**Status:** Sections 1–5 filled in (Sprint 1). Sections 6–11 are skeletons; filled in
sprint by sprint.
Target: a stranger with a GCP account and a domain can deploy from scratch in under 30 minutes.

---

## 1. Prerequisites

You need the following on your laptop (the "operator's machine") before running anything:

| Tool                | Minimum version | Install command (macOS)                                                          |
| ------------------- | --------------- | -------------------------------------------------------------------------------- |
| `gcloud` CLI        | 480.0.0         | `brew install --cask google-cloud-sdk`                                           |
| `git`               | 2.40            | `brew install git`                                                               |
| `bash`              | 5.0+ (or 3.2)   | macOS ships 3.2 — fine. Optional upgrade: `brew install bash`                    |
| `curl`              | any             | shipped with macOS                                                               |
| `dig` or `nslookup` | any             | shipped with macOS (`dig` via `brew install bind` if missing)                    |
| `jq`                | 1.6             | `brew install jq` (Ubuntu 24.04 ships it; required by `provision-cohort.sh` from Sprint 2) |
| `pre-commit`        | 3.7             | `brew install pre-commit` (run `pre-commit install` once after cloning the repo) |

You also need:

- A **GCP account** with billing enabled.
- A **domain you control** (you'll add A records at the registrar).
- **Provider API keys** ready: Anthropic, OpenAI, and a Vertex-AI-enabled GCP project
  (the same project as your VM works fine — see §2).
- **Five Slack incoming webhooks** — one each for budget, reports, exceptions, safety,
  platform. Create the channels and webhooks before the cohort begins.

> Sprint 1 only requires `gcloud`, `git`, `curl`, and `dig`. The rest become required in
> later sprints.

---

## 2. GCP setup

### 2.1 Create the project (one-time)

```sh
gcloud projects create <YOUR_PROJECT_ID> --name="CultivLab"
gcloud config set project <YOUR_PROJECT_ID>
```

Link a billing account in the GCP console (Billing → Link a project), then **set a
billing budget alert** in Billing → Budgets & alerts:

- Threshold 1: `$50 USD` — email alert
- Threshold 2: `$100 USD` — email alert
- Threshold 3: `$200 USD` — email alert and **disable billing automatically** (optional
  but recommended for a solo operator)

### 2.2 Authenticate locally

```sh
gcloud auth login
gcloud auth application-default login
```

### 2.3 Run the bootstrap script

Copy `.env.example` → `.env`, fill in your values:

```sh
cp .env.example .env
$EDITOR .env
```

Required for this step: `DOMAIN`, `GCP_PROJECT_ID`, `GCP_REGION`, `GCP_ZONE`, `VM_NAME`,
`VM_MACHINE_TYPE`, `VM_DISK_SIZE_GB`, `STATIC_IP_NAME`.

Preview without touching GCP:

```sh
bash scripts/gcp-bootstrap.sh --dry-run
```

Apply:

```sh
bash scripts/gcp-bootstrap.sh
```

The script is idempotent — re-running produces no errors and creates no duplicate
resources. It enables the required APIs, creates a static external IP, the VM service
account `cultivlab-vm@${GCP_PROJECT_ID}.iam.gserviceaccount.com`, grants it
`roles/aiplatform.user` (for Vertex AI), creates an HTTP/HTTPS firewall rule scoped to
the `cultivlab-http` network tag, and finally creates the VM with the IP and SA attached.

On success, the script prints the VM's external IP and the next steps.

### 2.4 Grant yourself IAP SSH access

The firewall rule opens 80/443 only — port 22 is **never exposed publicly**. SSH goes
through GCP's Identity-Aware Proxy. Grant your account the two roles needed:

```sh
ME="$(gcloud auth list --filter=status:ACTIVE --format='value(account)')"
gcloud projects add-iam-policy-binding <YOUR_PROJECT_ID> \
  --member="user:${ME}" --role="roles/iap.tunnelAccessor"
gcloud projects add-iam-policy-binding <YOUR_PROJECT_ID> \
  --member="user:${ME}" --role="roles/compute.osLogin"
```

---

## 3. DNS configuration

Add these A records at your domain registrar, both pointing at the VM external IP that
`gcp-bootstrap.sh` printed:

| Type | Host    | Value           | TTL  |
| ---- | ------- | --------------- | ---- |
| A    | `api`   | `<VM_EXTERNAL_IP>` | 300  |
| A    | `admin` | `<VM_EXTERNAL_IP>` | 300  |

> Sprint 1 deploys only `api.${DOMAIN}` and `admin.${DOMAIN}`. `chat.${DOMAIN}`,
> `founder.${DOMAIN}`, and the per-student CNAMEs are added in later sprints.

Verify propagation before continuing — Caddy will request real Let's Encrypt
certificates on first request, and that requires DNS to resolve correctly:

```sh
dig +short api.${DOMAIN}
dig +short admin.${DOMAIN}
```

Both should return the VM IP. If they don't, wait — propagation typically takes
1–10 minutes for fresh records. Do **not** run `bootstrap.sh` until DNS resolves
correctly.

---

## 4. VM provisioning

### 4.1 SSH into the VM via IAP

```sh
gcloud compute ssh ${VM_NAME} \
  --tunnel-through-iap \
  --zone ${GCP_ZONE} \
  --project ${GCP_PROJECT_ID}
```

If this is your first SSH session, gcloud may prompt to generate an SSH key — accept the
default. The first connection takes 10–20 seconds while OS Login provisions your account
on the VM.

### 4.2 Get the repo onto the VM

Easiest is to clone it on the VM:

```sh
sudo mkdir -p /opt && cd /opt
sudo git clone <YOUR_REPO_URL> cultivlab-source
cd cultivlab-source
```

### 4.3 Copy `.env` to the VM

From your laptop (not the VM):

```sh
gcloud compute scp .env ${VM_NAME}:/tmp/.env \
  --tunnel-through-iap \
  --zone ${GCP_ZONE} \
  --project ${GCP_PROJECT_ID}
```

Then on the VM, move it into the cloned repo:

```sh
sudo mv /tmp/.env /opt/cultivlab-source/.env
sudo chmod 600 /opt/cultivlab-source/.env
sudo chown root:root /opt/cultivlab-source/.env
```

> The `.env` file is the single source of configuration truth on the VM. It is never
> committed to git (the pre-commit hook and `.gitignore` enforce this).

---

## 5. Bootstrap

From the cloned repo on the VM:

```sh
cd /opt/cultivlab-source
sudo bash scripts/bootstrap.sh --dry-run    # preview
sudo bash scripts/bootstrap.sh              # apply
```

The script will (in order):

1. Install Docker and the Compose plugin (skips if already present)
2. Copy `infra/` to `/opt/cultivlab/infra/`
3. Render `Caddyfile.tmpl` → `Caddyfile` via envsubst
4. `docker compose pull`
5. `docker compose up -d`
6. Wait up to 60 seconds for LiteLLM to become healthy (polls
   `http://localhost:4000/health/liveliness` from inside the container)
7. Self-test `https://api.${DOMAIN}/health/liveliness` — first request triggers
   Let's Encrypt cert issuance, which can take 10–60 seconds
8. Print service URLs and next steps

### Verify success

From your laptop:

```sh
# 1. Public health check (HTTP 200, valid SSL)
curl -fsSL https://api.${DOMAIN}/health/liveliness && echo "ok"

# 2. From your allowed IP, the admin UI returns 200
curl -fsSL https://admin.${DOMAIN}/ui >/dev/null && echo "admin reachable from this IP"

# 3. From any other IP (e.g. via a phone hotspot), admin returns 403
#    (this verifies the FOUNDER_ALLOWED_IP allowlist is wired correctly)

# 4. List configured models
curl -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" https://api.${DOMAIN}/v1/models | jq .
```

You should see three models: `claude-sonnet-4-6`, `gpt-4o-mini`, `gemini-2.5-flash`.

### If something fails

```sh
# On the VM:
docker compose -f /opt/cultivlab/infra/docker-compose.yml logs --tail=200
docker compose -f /opt/cultivlab/infra/docker-compose.yml ps
```

Common first-run issues:

- **`api.${DOMAIN}` returns a TLS error.** DNS hasn't propagated; `dig +short` from
  another network. Caddy will retry the ACME challenge automatically.
- **LiteLLM never becomes healthy.** Almost always a bad `DATABASE_URL` or a
  `POSTGRES_PASSWORD` that contains characters needing URL-encoding. Re-generate the
  password with `openssl rand -hex 24` (no special chars) and re-run `bootstrap.sh`.
- **Admin UI returns 403 from your own IP.** Your `FOUNDER_ALLOWED_IP` doesn't match
  your current public IP. Find your IP at <https://ifconfig.me> and update `.env`,
  then re-run `bootstrap.sh` (it will re-render the Caddyfile and `compose up -d` will
  reconfigure Caddy).

---

## 6. LiteLLM and provider configuration

This section covers the work that happens **after** Sprint 1 bootstrap but **before** the
first student logs in. Three things, in order:

1. Set provider master-account caps (third layer of ADR-009).
2. Provision the cohort (one team + one virtual key per student).
3. Verify Slack alert wiring across all five channels.

### 6.1 Set provider master-account caps

These caps live **outside** the platform and cannot be bypassed even if LiteLLM, the VM,
or a virtual key is compromised. Set them once before each cohort.

**Anthropic** (`https://console.anthropic.com`):
1. Open **Settings → Plans & Billing**.
2. Under **Usage limits**, set a **monthly hard limit**. Anthropic blocks all requests on the
   account once the limit is reached.
3. Recommended starting cap: 1.5 × (`COHORT_MAX_BUDGET` × duration / 4 weeks) — enough
   headroom for retries and operator testing, well below uncapped exposure.

**OpenAI** (`https://platform.openai.com`):
1. Open **Settings → Limits**.
2. Set **Monthly budget** (hard cap — OpenAI rejects requests when reached).
3. Optional but recommended: set the **email notification threshold** to 80% so you get
   warned before requests start failing.

**GCP / Vertex AI** (`https://console.cloud.google.com/billing/budgets`):
1. Open **Billing → Budgets & alerts**.
2. Create a new budget, scope it to your CultivLab project's billing account, and filter
   **services** to **Vertex AI API**.
3. Set the budget amount and tick **alert at 50% / 90% / 100%** of actual spend. GCP does
   not auto-stop services on budget exhaustion — set up a **Pub/Sub topic + Cloud
   Function** to disable the API key on the 100% alert if you want a true hard cap. For
   MVP cohorts, the 90% email alert plus LiteLLM's per-cohort cap is sufficient.

### 6.2 Provision the cohort

Done from your laptop, against the live VM. The script reads `students.csv` and creates
one LiteLLM team plus one virtual key per student.

```bash
# 1. Copy the template (real students.csv is gitignored — keep it outside the repo).
cp templates/students.csv.example ~/cultivlab-cohort/students.csv

# 2. Fill in real student rows (name, email, slug, parent_email, optional overrides).
#    See templates/students.csv.example for the schema and constraints.
$EDITOR ~/cultivlab-cohort/students.csv

# 3. Point .env at it.
echo 'STUDENTS_CSV_PATH=~/cultivlab-cohort/students.csv' >> .env  # or edit by hand

# 4. Dry-run first — validates students.csv, prints intended actions, makes zero changes.
./scripts/provision-cohort.sh --dry-run

# 5. Live run.
./scripts/provision-cohort.sh
```

The live run writes `cohort-keys-${COHORT_NAME}.csv` next to your `students.csv`, mode
`0600`. Each row maps a slug to its plaintext virtual key. Plaintext keys cannot be
retrieved later — back this file up before you distribute the keys to students (see §6.4).

The script is idempotent: re-running reconciles team and key budgets/limits without
creating duplicates. If a key already exists in LiteLLM but isn't in the recorded CSV
(e.g. you lost the file), the script logs a warning and omits that row — re-issue the
key manually via the LiteLLM admin UI in that case.

Exit codes: `0` all rows succeeded, `1` setup failure (env / CSV / network), `2` partial
success — re-run to retry the failed rows.

### 6.3 Verify Slack alert wiring

```bash
./scripts/test-slack-alerts.sh --dry-run   # confirms env is loaded
./scripts/test-slack-alerts.sh             # posts one test message per channel
```

Each of the five channels should receive a message labeled `[CultivLab Sprint 2 smoke
test] #cultivlab-<channel>`. If a webhook returns `404`, the URL is no longer valid —
regenerate it in **Slack admin → Apps → Manage → Incoming Webhooks**, paste the new
URL into `.env` under the matching `SLACK_WEBHOOK_*` var, redeploy LiteLLM (`docker
compose up -d` on the VM picks up the new env), and re-run the test.

Note: `SLACK_WEBHOOK_SAFETY` is the moderation channel. LiteLLM doesn't route to it
yet — Sprint 3's moderation flow wires it up. The smoke test confirms only that the
webhook itself is live, not that LiteLLM will post to it. The other four channels are
exercised end-to-end by LiteLLM's native budget / spend / exception / DB alerts and you
will see real traffic on them once students start using the platform.

### 6.4 Where the keys live

The output file `cohort-keys-${COHORT_NAME}.csv`:

- lives in the same directory as `students.csv` (whatever `STUDENTS_CSV_PATH` points at);
- is gitignored (the repo `.gitignore` covers `cohort-keys*.csv` and `students*.csv`);
- has columns `slug,name,email,parent_email,key,key_alias`;
- is mode `0600` — only the operator's user can read it.

Distribute keys to students out-of-band: printed onboarding cards (Sprint 3) are the
default. Never email or Slack a plaintext virtual key. If a key leaks, block it in the
LiteLLM admin UI (`https://admin.${DOMAIN}/ui` → Virtual Keys → Block) and re-issue.

---

## 7. Open WebUI setup

_Filled in Sprint 3._

Connecting Open WebUI to LiteLLM, configuring the kid-mode system prompt, creating the first
operator account, verifying student signup is disabled.

---

## 8. Cohort provisioning

_Filled in Sprint 3._

Preparing `students.csv`, running `scripts/provision-cohort.sh --dry-run`, running it for
real, verifying all 12 virtual keys and Open WebUI accounts exist.

---

## 9. Student site setup

_Filled in Sprint 4._

Firebase Hosting project setup, running the site provisioning script, adding DNS CNAME
records for each student subdomain, verifying HTTPS on student URLs.

---

## 10. Founder Console setup

_Filled in Sprint 5.5._

Building the console container, configuring the bcrypt password, verifying the dashboard
loads and all student actions work.

---

## 11. Pre-cohort hardening checklist

_Filled in Sprint 5/6._

Full pre-cohort verification: backup test, alert test, pause/resume test, all acceptance
criteria from `docs/../README.md` checked off.

---

## Verification

_Sprint 1 verification commands are in §5 above. Updated each sprint as new components
arrive._

---

## Troubleshooting

_Filled in Sprint 1 (basics — see "If something fails" in §5), updated each sprint. See
also `docs/runbooks/`._
