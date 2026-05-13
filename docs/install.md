# CultivLab — Operator Installation Guide

**Status:** Sections 1–5 filled in (Sprint 1). Sections 6–11 are skeletons; filled in sprint by
sprint. Target: a stranger with a GCP account and a domain can deploy from scratch in under 30
minutes.

---

## 1. Prerequisites

You need the following on your laptop (the "operator's machine") before running anything:

| Tool                | Minimum version | Install command (macOS)                                                                    |
| ------------------- | --------------- | ------------------------------------------------------------------------------------------ |
| `gcloud` CLI        | 480.0.0         | `brew install --cask google-cloud-sdk`                                                     |
| `git`               | 2.40            | `brew install git`                                                                         |
| `bash`              | 5.0+ (or 3.2)   | macOS ships 3.2 — fine. Optional upgrade: `brew install bash`                              |
| `curl`              | any             | shipped with macOS                                                                         |
| `dig` or `nslookup` | any             | shipped with macOS (`dig` via `brew install bind` if missing)                              |
| `jq`                | 1.6             | `brew install jq` (Ubuntu 24.04 ships it; required by `provision-cohort.sh` from Sprint 2) |
| `pre-commit`        | 3.7             | `brew install pre-commit` (run `pre-commit install` once after cloning the repo)           |

You also need:

- A **GCP account** with billing enabled.
- A **domain you control** (you'll add A records at the registrar).
- **Provider API keys** ready: Anthropic, OpenAI, and a Vertex-AI-enabled GCP project (the same
  project as your VM works fine — see §2).
- **Five Slack incoming webhooks** — one each for budget, reports, exceptions, safety, platform.
  Create the channels and webhooks before the cohort begins.

> Sprint 1 only requires `gcloud`, `git`, `curl`, and `dig`. The rest become required in later
> sprints.

---

## 2. GCP setup

### 2.1 Create the project (one-time)

```sh
gcloud projects create <YOUR_PROJECT_ID> --name="CultivLab"
gcloud config set project <YOUR_PROJECT_ID>
```

Link a billing account in the GCP console (Billing → Link a project), then **set a billing budget
alert** in Billing → Budgets & alerts:

- Threshold 1: `$50 USD` — email alert
- Threshold 2: `$100 USD` — email alert
- Threshold 3: `$200 USD` — email alert and **disable billing automatically** (optional but
  recommended for a solo operator)

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

The script is idempotent — re-running produces no errors and creates no duplicate resources. It
enables the required APIs, creates a static external IP, the VM service account
`cultivlab-vm@${GCP_PROJECT_ID}.iam.gserviceaccount.com`, grants it `roles/aiplatform.user` (for
Vertex AI), creates an HTTP/HTTPS firewall rule scoped to the `cultivlab-http` network tag, and
finally creates the VM with the IP and SA attached.

On success, the script prints the VM's external IP and the next steps.

### 2.4 Grant yourself IAP SSH access

The firewall rule opens 80/443 only — port 22 is **never exposed publicly**. SSH goes through GCP's
Identity-Aware Proxy. Grant your account the two roles needed:

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

| Type | Host    | Value              | TTL |
| ---- | ------- | ------------------ | --- |
| A    | `api`   | `<VM_EXTERNAL_IP>` | 300 |
| A    | `admin` | `<VM_EXTERNAL_IP>` | 300 |

> Sprint 1 deploys only `api.${DOMAIN}` and `admin.${DOMAIN}`. `chat.${DOMAIN}`,
> `founder.${DOMAIN}`, and the per-student CNAMEs are added in later sprints.

Verify propagation before continuing — Caddy will request real Let's Encrypt certificates on first
request, and that requires DNS to resolve correctly:

```sh
dig +short api.${DOMAIN}
dig +short admin.${DOMAIN}
```

Both should return the VM IP. If they don't, wait — propagation typically takes 1–10 minutes for
fresh records. Do **not** run `bootstrap.sh` until DNS resolves correctly.

---

## 4. VM provisioning

### 4.1 SSH into the VM via IAP

```sh
gcloud compute ssh ${VM_NAME} \
  --tunnel-through-iap \
  --zone ${GCP_ZONE} \
  --project ${GCP_PROJECT_ID}
```

If this is your first SSH session, gcloud may prompt to generate an SSH key — accept the default.
The first connection takes 10–20 seconds while OS Login provisions your account on the VM.

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

> The `.env` file is the single source of configuration truth on the VM. It is never committed to
> git (the pre-commit hook and `.gitignore` enforce this).

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
7. Self-test `https://api.${DOMAIN}/health/liveliness` — first request triggers Let's Encrypt cert
   issuance, which can take 10–60 seconds
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

- **`api.${DOMAIN}` returns a TLS error.** DNS hasn't propagated; `dig +short` from another network.
  Caddy will retry the ACME challenge automatically.
- **LiteLLM never becomes healthy.** Almost always a bad `DATABASE_URL` or a `POSTGRES_PASSWORD`
  that contains characters needing URL-encoding. Re-generate the password with
  `openssl rand -hex 24` (no special chars) and re-run `bootstrap.sh`.
- **Admin UI returns 403 from your own IP.** Your `FOUNDER_ALLOWED_IP` doesn't match your current
  public IP. Find your IP at <https://ifconfig.me> and update `.env`, then re-run `bootstrap.sh` (it
  will re-render the Caddyfile and `compose up -d` will reconfigure Caddy).

---

## 6. LiteLLM and provider configuration

This section covers the work that happens **after** Sprint 1 bootstrap but **before** the first
student logs in. Three things, in order:

1. Set provider master-account caps (third layer of ADR-009).
2. Provision the cohort (one team + one virtual key per student).
3. Verify Slack alert wiring across all five channels.

### 6.1 Set provider master-account caps

These caps live **outside** the platform and cannot be bypassed even if LiteLLM, the VM, or a
virtual key is compromised. Set them once before each cohort.

**Anthropic** (`https://console.anthropic.com`):

1. Open **Settings → Plans & Billing**.
2. Under **Usage limits**, set a **monthly hard limit**. Anthropic blocks all requests on the
   account once the limit is reached.
3. Recommended starting cap: 1.5 × (`COHORT_MAX_BUDGET` × duration / 4 weeks) — enough headroom for
   retries and operator testing, well below uncapped exposure.

**OpenAI** (`https://platform.openai.com`):

1. Open **Settings → Limits**.
2. Set **Monthly budget** (hard cap — OpenAI rejects requests when reached).
3. Optional but recommended: set the **email notification threshold** to 80% so you get warned
   before requests start failing.

**GCP / Vertex AI** (`https://console.cloud.google.com/billing/budgets`):

1. Open **Billing → Budgets & alerts**.
2. Create a new budget, scope it to your CultivLab project's billing account, and filter
   **services** to **Vertex AI API**.
3. Set the budget amount and tick **alert at 50% / 90% / 100%** of actual spend. GCP does not
   auto-stop services on budget exhaustion — set up a **Pub/Sub topic + Cloud Function** to disable
   the API key on the 100% alert if you want a true hard cap. For MVP cohorts, the 90% email alert
   plus LiteLLM's per-cohort cap is sufficient.

### 6.2 Provision the cohort

Done from your laptop, against the live VM. The script reads `students.csv` and creates one LiteLLM
team plus one virtual key per student.

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

The live run writes `cohort-keys-${COHORT_NAME}.csv` next to your `students.csv`, mode `0600`. Each
row maps a slug to its plaintext virtual key. Plaintext keys cannot be retrieved later — back this
file up before you distribute the keys to students (see §6.4).

The script is idempotent: re-running reconciles team and key budgets/limits without creating
duplicates. If a key already exists in LiteLLM but isn't in the recorded CSV (e.g. you lost the
file), the script logs a warning and omits that row — re-issue the key manually via the LiteLLM
admin UI in that case.

Exit codes: `0` all rows succeeded, `1` setup failure (env / CSV / network), `2` partial success —
re-run to retry the failed rows.

### 6.3 Verify Slack alert wiring

```bash
./scripts/test-slack-alerts.sh --dry-run   # confirms env is loaded
./scripts/test-slack-alerts.sh             # posts one test message per channel
```

Each of the five channels should receive a message labeled
`[CultivLab Sprint 2 smoke test] #cultivlab-<channel>`. If a webhook returns `404`, the URL is no
longer valid — regenerate it in **Slack admin → Apps → Manage → Incoming Webhooks**, paste the new
URL into `.env` under the matching `SLACK_WEBHOOK_*` var, redeploy LiteLLM (`docker compose up -d`
on the VM picks up the new env), and re-run the test.

Note: `SLACK_WEBHOOK_SAFETY` is the moderation channel. LiteLLM doesn't route to it yet — Sprint 3's
moderation flow wires it up. The smoke test confirms only that the webhook itself is live, not that
LiteLLM will post to it. The other four channels are exercised end-to-end by LiteLLM's native budget
/ spend / exception / DB alerts and you will see real traffic on them once students start using the
platform.

### 6.4 Where the keys live

The output file `cohort-keys-${COHORT_NAME}.csv`:

- lives in the same directory as `students.csv` (whatever `STUDENTS_CSV_PATH` points at);
- is gitignored (the repo `.gitignore` covers `cohort-keys*.csv` and `students*.csv`);
- has columns `slug,name,email,parent_email,key,key_alias`;
- is mode `0600` — only the operator's user can read it.

Distribute keys to students out-of-band: printed onboarding cards (Sprint 3) are the default. Never
email or Slack a plaintext virtual key. If a key leaks, block it in the LiteLLM admin UI
(`https://admin.${DOMAIN}/ui` → Virtual Keys → Block) and re-issue.

---

## 7. Open WebUI setup

Pre-requisites: §5 bootstrap succeeded (LiteLLM healthy), §6 LiteLLM and provider config done.

### 7.1 Add DNS record for `chat.${DOMAIN}`

At your registrar, add one A record (same VM IP as `api` and `admin`):

| Type | Host   | Value              | TTL |
| ---- | ------ | ------------------ | --- |
| A    | `chat` | `<VM_EXTERNAL_IP>` | 300 |

Verify before proceeding:

```sh
dig +short chat.${DOMAIN}   # must return the VM IP
```

### 7.2 Create the admin account (one-time, first signup only)

The **first** account created at `https://chat.${DOMAIN}` is automatically promoted to admin. You
must create it before disabling signup.

1. Open `https://chat.${DOMAIN}` in a browser.
2. Click **Sign up**, enter `OPENWEBUI_ADMIN_EMAIL` and a strong password of your choice.
3. You are now logged in as admin — the interface shows a full admin panel.

Set `OPENWEBUI_ADMIN_EMAIL` and `OPENWEBUI_ADMIN_PASSWORD` in `.env` to match the values you just
used. These credentials are required by `provision-students.sh` and `reset-student-password.sh`.

**Set default user role to `user`:** In Admin Panel → Settings → General, find **Default User Role**
and set it to `user` (not `pending`). If left as `pending`, provisioned student accounts will be in
a pending state and cannot log in without manual admin approval.

### 7.3 Disable student self-registration

Once the admin account exists, prevent students from self-registering:

In `.env`:

```sh
OPENWEBUI_ENABLE_SIGNUP=false
```

Restart Open WebUI on the VM to apply:

```sh
cd /opt/cultivlab/infra
sudo docker compose --env-file /opt/cultivlab/.env up -d --force-recreate open-webui
```

Verify: open `https://chat.${DOMAIN}` in an incognito window — you should see only a **Sign in**
form with no **Sign up** link.

### 7.4 Verify the LiteLLM connection

Log in as admin. The model selector should list the three configured models: `claude-sonnet-4-6`,
`gpt-4o-mini`, `gemini-2.5-flash`.

If no models appear:

```sh
# On the VM — check Open WebUI sees LiteLLM
docker compose -f /opt/cultivlab/infra/docker-compose.yml logs open-webui --tail=50
```

Common cause: `OPENAI_API_KEYS` in the Open WebUI container does not match `LITELLM_MASTER_KEY`.
Re-verify `.env` and force-recreate both services.

### 7.5 Create Public workspace models (required — students see 0 models otherwise)

Models from the LiteLLM API connection are visible to admin only by default. You must create Public
workspace models so students can select them in the chat interface.

In Admin Panel → **Workspace → Models**, click **+** to create each model:

| Model ID            | Display name                 | Base model          |
| ------------------- | ---------------------------- | ------------------- |
| `claude-sonnet-4-6` | Claude (CultivLab)           | `claude-sonnet-4-6` |
| `gpt-4o-mini`       | GPT-4o mini (CultivLab)      | `gpt-4o-mini`       |
| `gemini-2.5-flash`  | Gemini 2.5 Flash (CultivLab) | `gemini-2.5-flash`  |

For each: set **Visibility** to **Public**. Leave all other fields at defaults.

Verify by logging in as a test student account — the model dropdown must show all three models.
Without this step, students will see an empty model list even after a successful login.

### 7.6 Verify kid-mode system prompt

In the Open WebUI admin panel → **Admin → Settings → General**, confirm the **System Prompt** field
contains the value from `KID_MODE_SYSTEM_PROMPT` in `.env`. If it is blank, paste the value in and
click **Save**.

### 7.7 Verify branding

The login page title and header should read **"Sign in to CultivLab"** (or whatever `WEBUI_NAME` is
set to in `.env`), not "Sign in to Open WebUI". If it still shows "Open WebUI", confirm `WEBUI_NAME`
is set in `.env` and that Open WebUI was force-recreated in §7.3.

---

## 8. Cohort provisioning

Pre-requisites: §6.2 (`provision-cohort.sh`) complete — `cohort-keys-${COHORT_NAME}.csv` exists on
your laptop. Open WebUI admin account created and credentials in `.env` (§7.2).

This section provisions Open WebUI accounts for each student and produces the `cohort-students` CSV
that all subsequent operator scripts depend on.

### 8.1 Run `provision-students.sh`

```sh
# Dry-run — prints intended OW account creates, makes no API calls
bash scripts/provision-students.sh --dry-run

# Live run — creates one OW account per student
bash scripts/provision-students.sh
```

The live run writes `cohort-students-${COHORT_NAME}.csv` (mode `0600`) next to the `cohort-keys`
CSV. Columns: `slug,owui_user_id,email,owui_password,litellm_key`.

The script is idempotent: re-running detects existing accounts by email and skips creation,
preserving the password recorded from the first run. Exit codes: `0` all rows succeeded, `1` setup
failure, `2` partial success — re-run to retry failed rows.

> **Keep `cohort-students-${COHORT_NAME}.csv` safe.** It contains plaintext student passwords. Back
> it up alongside `cohort-keys-${COHORT_NAME}.csv` before distributing credentials.

### 8.2 Generate onboarding cards

```sh
bash scripts/generate-cards.sh
```

Produces one markdown file per student (in `onboarding-cards-${COHORT_NAME}/`) containing their chat
URL, email, password, API key, and personal site URL. Print or convert to PDF to hand out in person
— never email or Slack plaintext credentials.

### 8.3 Verify a student can log in

Using one row from `cohort-students-${COHORT_NAME}.csv`, test the end-to-end student flow:

1. Open `https://chat.${DOMAIN}` in an incognito window.
2. Sign in with the student's email and recorded password.
3. Send a short message — confirm a model response arrives via LiteLLM.
4. Log out.

### 8.4 Reset a student password if needed

```sh
bash scripts/reset-student-password.sh \
  --cohort "${COHORT_NAME}" \
  --slug <student-slug>
```

Prints the new password to stdout and updates `cohort-students-${COHORT_NAME}.csv` automatically.
Use `--password <value>` to supply a specific password instead of a random one.

### 8.5 One-command provisioning (recommended for repeat cohorts)

`scripts/provision-all.sh` runs all four provisioning steps in sequence (cohort keys → OW accounts →
site slots → onboarding cards) then calls `push-env.sh` to sync the updated `.env` to the VM:

```sh
bash scripts/provision-all.sh --dir ~/Desktop/cultivlab-cohort-1-2026
bash scripts/provision-all.sh --dir ~/Desktop/cultivlab-cohort-1-2026 --dry-run
```

The `--dir` argument must point to a folder containing `students.csv`. All output CSVs and
onboarding cards are written to the same folder.

### 8.6 Sync `.env` changes to VM

Any time you change `.env` on your laptop (new COHORT_NAME, rotated key, updated FOUNDER_ALLOWED_IP
etc.), push the change to the VM and restart affected services:

```sh
bash scripts/push-env.sh          # restart founder-console only
bash scripts/push-env.sh --all    # also restart litellm (use after provider key rotation)
```

---

## 9. Student site setup

_Filled in Sprint 4._

Firebase Hosting project setup, running the site provisioning script, adding DNS CNAME records for
each student subdomain, verifying HTTPS on student URLs.

---

## 10. Founder Console setup (Sprint 5.5)

The Founder Console is a FastAPI + HTMX operator dashboard at `founder.${DOMAIN}`. It shows the
student grid (spend, status, slot, site), cohort totals, and provides one-click pause/resume and
budget top-up. IP-locked to `FOUNDER_ALLOWED_IP` via Caddy — same allowlist as `admin.${DOMAIN}`.

### 10.1 Generate credentials (one-time, on your laptop)

```sh
# 1. bcrypt-hash a password of your choice
python3 -c "import bcrypt; print(bcrypt.hashpw(b'your-chosen-password', bcrypt.gensalt()).decode())"
# → $2b$12$...  (copy this output)

# 2. Generate a cookie-signing secret
openssl rand -hex 32
# → abcdef123...  (copy this output)
```

Add both values to `.env`:

```sh
FOUNDER_CONSOLE_PASSWORD_HASH=$2b$12$...   # paste bcrypt output
FOUNDER_CONSOLE_SECRET_KEY=abcdef123...    # paste openssl output
```

### 10.2 Add DNS A record for founder.${DOMAIN}

At your registrar, add one more A record pointing at the VM IP:

| Type | Host      | Value              | TTL |
| ---- | --------- | ------------------ | --- |
| A    | `founder` | `<VM_EXTERNAL_IP>` | 300 |

Verify: `dig +short founder.${DOMAIN}` should return the VM IP.

### 10.3 Build and deploy the container (on the VM)

The Founder Console is built from source rather than pulled from a registry, so the image must be
built on the VM before `docker compose up -d` can start it.

```sh
# On the VM, from the repo directory
cd /opt/cultivlab-source

# Pull any code changes if you haven't already
sudo git pull

# Copy updated .env to the live location
sudo cp .env /opt/cultivlab/.env
sudo chmod 600 /opt/cultivlab/.env

# Build the founder-console image (first run: ~2 minutes)
sudo docker compose -f infra/docker-compose.yml build founder-console

# Start it (other services are already running — only founder-console starts)
sudo docker compose -f infra/docker-compose.yml up -d founder-console

# Re-render Caddyfile and reload Caddy to pick up the new founder.${DOMAIN} block
sudo bash scripts/bootstrap.sh
```

`bootstrap.sh` re-renders `Caddyfile.tmpl` with the updated env, calls `docker compose up -d`
(founder-console is already up, so Docker skips it), then restarts Caddy to pick up the new route.

### 10.4 Verify the console is running

```sh
# On the VM: container should be Up and healthy within 20 s
docker ps --format "table {{.Names}}\t{{.Status}}" | grep founder-console

# From your laptop (must be on your allowed IP):
curl -fsSL https://founder.${DOMAIN}/health   # → {"status":"ok"}
```

Open `https://founder.${DOMAIN}` in a browser — you should see the login form. Log in with the
password you bcrypt-hashed in §10.1.

### 10.5 Verify the dashboard and actions

After logging in:

- The cohort summary card should show team spend and student counts (zeros before first activity).
- The student grid should list all provisioned students with their LiteLLM key status.
- Test pause: click **⛔ Pause** on one student → flash message confirms; LiteLLM key is blocked
  within ~60 seconds (cache TTL).
- Test resume: click **▶ Resume** → flash message confirms; key unblocked within ~60 seconds.
- Test top-up: enter `1` in the $ field and click **+$** → flash message confirms; `max_budget`
  increased by $1.00 in `LiteLLM_VerificationToken`.
- Slot and site columns are populated after `provision-sites.sh` has run (Sprint 4 step).

### 10.6 Verify IP lockout

From a network that is **not** in `FOUNDER_ALLOWED_IP` (e.g. a phone hotspot):

```sh
curl -I https://founder.${DOMAIN}    # should return HTTP 403 Forbidden
```

If it returns 200, check that `FOUNDER_ALLOWED_IP` in `.env` is set to your specific CIDR (e.g.
`1.2.3.4/32`) and not to `0.0.0.0/0`, then re-run `bootstrap.sh` to re-render the Caddyfile.

---

## 11. Cron monitoring setup (Sprint 5)

Three scripts run as root cron jobs on the VM. Run all steps below on the VM (not your laptop).

### 11.1 Prerequisites on the VM

```sh
# jq — required by daily-summary and weekly-cap-enforcer
sudo apt-get install -y jq

# gsutil — required by backup-postgres; already present on GCP Ubuntu 24.04 via Cloud SDK snap.
# Verify:
gsutil version
```

### 11.2 Create the GCS backup bucket (one-time)

```sh
# Source env to pick up GCS_BACKUP_BUCKET and GCP_PROJECT_ID
source /opt/cultivlab/.env

gsutil mb -p "${GCP_PROJECT_ID}" -l us-central1 "gs://${GCS_BACKUP_BUCKET}"

# Grant the VM's service account write access
gsutil iam ch "serviceAccount:${VM_SERVICE_ACCOUNT_EMAIL}:roles/storage.objectAdmin" \
  "gs://${GCS_BACKUP_BUCKET}"
```

Verify access (should list the empty bucket without error):

```sh
gsutil ls "gs://${GCS_BACKUP_BUCKET}"
```

### 11.3 Install cron jobs

From the repo on the VM:

```sh
cd /path/to/cultivlab-platform

# Preview what will be installed — no changes
sudo bash scripts/install-crontab.sh --dry-run

# Install /etc/cron.d/cultivlab-ops and /etc/logrotate.d/cultivlab-ops
sudo bash scripts/install-crontab.sh
```

This writes:

- `/etc/cron.d/cultivlab-ops` — three jobs at 02:00, 23:00, 23:30 UTC
- `/etc/logrotate.d/cultivlab-ops` — daily rotation, 14-day retention
- `/var/log/cultivlab/` — log directory (mode 750)

The script is idempotent; re-run it whenever the scripts directory path changes.

### 11.4 Verify each script manually

Test each script immediately after install. Run them with `--dry-run` first, then live if the
dry-run looks correct.

```sh
# Daily summary (dry-run: uses stub data, no Slack post)
sudo bash scripts/daily-summary.sh --dry-run

# Daily summary (live: posts to #cultivlab-reports)
sudo bash scripts/daily-summary.sh --force

# Weekly cap enforcer (dry-run: shows what would be blocked)
sudo bash scripts/weekly-cap-enforcer.sh --dry-run

# Backup (dry-run: shows what would be uploaded)
sudo bash scripts/backup-postgres.sh --dry-run

# Backup (live: pg_dump → GCS, Slack success notification to #cultivlab-platform)
sudo bash scripts/backup-postgres.sh --force

# Verify backup landed in GCS
source /opt/cultivlab/.env
gsutil ls "gs://${GCS_BACKUP_BUCKET}/daily/"
```

### 11.5 Verify restore (sanity — Phase 1 only)

Run a Phase 1 restore to confirm the backup you just created is valid:

```sh
source /opt/cultivlab/.env
LATEST="$(gsutil ls gs://${GCS_BACKUP_BUCKET}/daily/*.sql.gz | sort | tail -1)"
echo "Restoring: ${LATEST}"
sudo bash scripts/restore-postgres.sh "${LATEST}" --dry-run   # preview
sudo bash scripts/restore-postgres.sh "${LATEST}"             # Phase 1: temp DB + sanity check
```

A successful Phase 1 restore prints `phase1: complete sanity=OK tables=N` and drops the temp
database. For a full production restore procedure, see `docs/runbooks/backup-restore.md`.

### 11.6 Verify cron is scheduled

```sh
cat /etc/cron.d/cultivlab-ops         # confirm entries
sudo systemctl status cron            # confirm cron daemon is running
tail -20 /var/log/cultivlab/backup-postgres.log   # after 02:00 UTC, should have entries
```

---

## 12. Pre-cohort hardening checklist

_Filled in Sprint 5/6._

Full pre-cohort verification: backup test, alert test, pause/resume test, all acceptance criteria
from `docs/../README.md` checked off.

---

## Verification

_Sprint 1 verification commands are in §5 above. Updated each sprint as new components arrive._

---

## Troubleshooting

_Filled in Sprint 1 (basics — see "If something fails" in §5), updated each sprint. See also
`docs/runbooks/`._
