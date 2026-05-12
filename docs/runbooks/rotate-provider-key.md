# Runbook: Rotate a Provider API Key

**When to use this runbook:**

- A provider key is suspected or confirmed leaked (e.g. found in a log, public commit, or breach
  alert).
- You are rotating keys as part of a scheduled security review.
- A provider key has expired or been revoked by the provider.

**Affected providers:** Anthropic, OpenAI, Vertex AI (service account key).

**Time required:** 5–10 minutes per provider. Zero downtime if steps are followed in order.

---

## 1. Generate the new key at the provider

Do this **before** touching the VM or `.env`. Having the new key ready prevents any gap in service.

**Anthropic** (`https://console.anthropic.com/settings/keys`):

1. Click **Create Key** → give it a descriptive name (e.g. `cultivlab-vm-2026-06`).
2. Copy the new key (`sk-ant-...`) — it is shown only once.
3. Do **not** delete the old key yet.

**OpenAI** (`https://platform.openai.com/api-keys`):

1. Click **+ Create new secret key** → name it (e.g. `cultivlab-vm-2026-06`).
2. Copy the new key (`sk-...`) — shown only once.
3. Do **not** delete the old key yet.

**Vertex AI service account key** (if using a key file rather than ADC):

1. In GCP Console → IAM & Admin → Service Accounts, open the VM service account.
2. Keys → **Add Key → Create new key → JSON** → download the file.
3. Upload to the VM (see §3 for the path) after updating `.env`.

---

## 2. Update `.env` on your laptop

Edit `.env` in the repo root (never commit this file):

```sh
# Replace the old value with the new key
ANTHROPIC_API_KEY=sk-ant-...   # new Anthropic key
OPENAI_API_KEY=sk-...          # new OpenAI key
# VERTEX_AI_SERVICE_ACCOUNT_KEY_PATH — only if rotating a key file
```

---

## 3. Push the new key to the VM

```sh
# From your laptop — copy the updated .env
gcloud compute scp .env ${VM_NAME}:/tmp/.env \
  --tunnel-through-iap \
  --zone ${GCP_ZONE} \
  --project ${GCP_PROJECT_ID}
```

On the VM:

```sh
# Move into the repo (.env is the symlinked source of truth)
sudo mv /tmp/.env /opt/cultivlab/repo/.env
sudo chmod 600 /opt/cultivlab/repo/.env

# Verify the symlink is intact — should point to the repo .env
ls -la /opt/cultivlab/.env
# Expected: /opt/cultivlab/.env -> /opt/cultivlab/repo/.env
```

If rotating a Vertex AI key file, also copy it:

```sh
# From your laptop
gcloud compute scp /path/to/new-key.json ${VM_NAME}:/opt/cultivlab/vertex-key.json \
  --tunnel-through-iap --zone ${GCP_ZONE} --project ${GCP_PROJECT_ID}

# On the VM
sudo chmod 600 /opt/cultivlab/vertex-key.json
```

---

## 4. Restart LiteLLM to pick up the new key

LiteLLM reads provider keys from environment variables at startup. Restart it — the other services
(Caddy, Postgres, Open WebUI) do not need to restart.

On the VM:

```sh
cd /opt/cultivlab/infra
sudo docker compose --env-file /opt/cultivlab/.env up -d --force-recreate litellm
```

Wait for the healthcheck to pass (up to 30 seconds):

```sh
sudo docker compose --env-file /opt/cultivlab/.env ps litellm
# Should show: (healthy)
```

---

## 5. Smoke test the new key

From your laptop:

```sh
source .env

# Anthropic (Claude)
curl -fsSL https://api.${DOMAIN}/v1/chat/completions \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":"ping"}],"max_tokens":5}' \
  | jq '.choices[0].message.content'

# OpenAI (GPT)
curl -fsSL https://api.${DOMAIN}/v1/chat/completions \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"ping"}],"max_tokens":5}' \
  | jq '.choices[0].message.content'

# Vertex AI (Gemini)
curl -fsSL https://api.${DOMAIN}/v1/chat/completions \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-2.5-flash","messages":[{"role":"user","content":"ping"}],"max_tokens":5}' \
  | jq '.choices[0].message.content'
```

Each should return a short model response. If any returns an auth error (`401` / `403`), the new key
was not picked up — check the LiteLLM logs:

```sh
sudo docker compose --env-file /opt/cultivlab/.env logs litellm --tail=50
```

---

## 6. Revoke the old key at the provider

Only after step 5 confirms the new key is working:

**Anthropic:** `https://console.anthropic.com/settings/keys` → find the old key → **Revoke**.

**OpenAI:** `https://platform.openai.com/api-keys` → find the old key → **Delete** (red trash icon).

**Vertex AI service account key:** GCP Console → IAM → Service Accounts → old key → **Delete**.

> Revoking before the smoke test passes will cause an outage. Always test first.

---

## 7. Notify via Slack (optional but recommended)

Post a brief note to `#cultivlab-platform`:

```
:key: Provider key rotated — ANTHROPIC_API_KEY updated, old key revoked.
Smoke test passed [timestamp]. No student impact.
```

---

## Troubleshooting

**LiteLLM logs show `AuthenticationError` after restart.** The new key value did not land in the
container environment. Verify the `.env` on the VM has the correct value
(`grep ANTHROPIC_API_KEY /opt/cultivlab/repo/.env`), then force-recreate LiteLLM again.

**Symlink broken after `mv /tmp/.env`.** If `/opt/cultivlab/.env` stopped pointing to the repo file:

```sh
sudo ln -sf /opt/cultivlab/repo/.env /opt/cultivlab/.env
ls -la /opt/cultivlab/.env  # confirm target
```

**Vertex AI returns `403 Permission denied` with new key file.** Confirm the service account still
has `roles/aiplatform.user` on the project:

```sh
gcloud projects get-iam-policy ${GCP_PROJECT_ID} \
  --flatten="bindings[].members" \
  --filter="bindings.members:cultivlab-vm@" \
  --format="table(bindings.role)"
```

If the role is missing, re-grant it:

```sh
gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} \
  --member="serviceAccount:cultivlab-vm@${GCP_PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/aiplatform.user"
```
