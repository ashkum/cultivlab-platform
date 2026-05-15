# Runbook: Deploying Updates to the VM

Covers the full procedure for pushing code changes to the production VM and the known gotchas that
have caused issues in practice.

---

## Key facts about the VM layout

These are not obvious and have caused repeated confusion:

| What                      | Actual path on VM                              |
| ------------------------- | ---------------------------------------------- |
| Repo                      | `/opt/cultivlab/repo/`                         |
| `.env` (live secrets)     | `/opt/cultivlab/.env` → symlink to repo        |
| Docker Compose file       | `/opt/cultivlab/repo/infra/docker-compose.yml` |
| **Caddyfile Caddy reads** | `/opt/cultivlab/infra/Caddyfile`               |
| Student site files        | `/srv/students/lNN/`                           |

**The Caddyfile is NOT in the repo path.** The Caddy container was originally created with a bind
mount pointing to `/opt/cultivlab/infra/Caddyfile`. `docker compose restart` reuses that original
mount. To find the actual mount path for any container, always verify with:

```bash
docker inspect cultivlab-caddy-1 | python3 -c \
  "import sys,json; [print(m['Source'],'->', m['Destination']) \
   for m in json.load(sys.stdin)[0]['Mounts']]"
```

---

## Standard deploy sequence

### 1. Sync the repo on the VM

```bash
gcloud compute ssh ${VM_NAME} --tunnel-through-iap \
  --zone ${GCP_ZONE} --project ${GCP_PROJECT_ID} \
  --command "sudo chown -R \$(whoami):\$(whoami) /opt/cultivlab/repo && \
    cd /opt/cultivlab/repo && \
    git fetch origin && \
    git reset --hard origin/main && \
    git clean -fd" \
  </dev/null
```

`git reset --hard` + `git clean -fd` is safe — the VM repo is deploy-only, never edited directly.
Gitignored files (`.env`, CSVs) are preserved by `git clean -fd` (no `-x` flag).

### 2. Rebuild a service (when Python/Dockerfile changed)

```bash
gcloud compute ssh ${VM_NAME} --tunnel-through-iap \
  --zone ${GCP_ZONE} --project ${GCP_PROJECT_ID} \
  --command "docker compose -f /opt/cultivlab/repo/infra/docker-compose.yml \
    --env-file /opt/cultivlab/.env \
    build founder-console && \
    docker compose -f /opt/cultivlab/repo/infra/docker-compose.yml \
    --env-file /opt/cultivlab/.env \
    up -d founder-console" \
  </dev/null
```

**Always use `--env-file /opt/cultivlab/.env` explicitly.** Without it, Docker Compose looks for
`.env` relative to the compose file's directory (`repo/infra/`) where it does not exist, and all
variables default to blank.

**`restart` does NOT rebuild.** Use `build` + `up -d` for code changes. Use `restart` only for
config/env changes where the image is unchanged.

### 3. Update the Caddyfile

The Caddyfile Caddy reads is `/opt/cultivlab/infra/Caddyfile` (see above). To update it:

```bash
gcloud compute ssh ${VM_NAME} --tunnel-through-iap \
  --zone ${GCP_ZONE} --project ${GCP_PROJECT_ID} \
  --command "cd /opt/cultivlab && \
    envsubst < repo/infra/Caddyfile.tmpl > infra/Caddyfile && \
    docker compose -f repo/infra/docker-compose.yml \
      --env-file /opt/cultivlab/.env restart caddy && \
    sleep 4 && docker logs cultivlab-caddy-1 --tail 5" \
  </dev/null
```

Verify the last log lines show `"serving initial configuration"` with no `Error:` lines. If Caddy
errors, it enters a restart loop — fix the Caddyfile before anything else.

---

## Caddyfile rules (learned the hard way)

1. **`header_up` is a subdirective of `reverse_proxy`, not a standalone directive.** It must be
   inside the `reverse_proxy` block:

   ```caddy
   # WRONG — header_up at handle level
   handle /upload* {
       header_up X-My-Header value
       reverse_proxy backend:8080
   }

   # CORRECT — header_up inside reverse_proxy
   handle /upload* {
       reverse_proxy backend:8080 {
           header_up X-My-Header value
       }
   }
   ```

2. **Caddy placeholders like `{labels.2}` are NOT valid inside `header_up` values in some Caddy
   versions.** If you need to pass request context to an upstream, derive it from the `Host` header
   in the app instead.

3. **`envsubst` substitutes `${VAR}` patterns only.** Caddy placeholders (`{host}`, `{labels.2}`,
   etc.) do not use `${}` and are left untouched.

4. **After any Caddyfile change, always tail the logs** to confirm Caddy started cleanly before
   declaring success.

---

## Docker Compose on the VM

The compose file is at `repo/infra/docker-compose.yml`. Always pass it explicitly with `-f`. Always
pass `--env-file /opt/cultivlab/.env`.

```bash
# Check status of all services
docker compose -f /opt/cultivlab/repo/infra/docker-compose.yml \
  --env-file /opt/cultivlab/.env ps

# Tail logs for a service
docker logs cultivlab-founder-console-1 --tail 30 -f

# Restart a service (config change only — no rebuild)
docker compose -f /opt/cultivlab/repo/infra/docker-compose.yml \
  --env-file /opt/cultivlab/.env restart <service>

# Rebuild + restart (code change)
docker compose -f /opt/cultivlab/repo/infra/docker-compose.yml \
  --env-file /opt/cultivlab/.env build <service> && \
docker compose -f /opt/cultivlab/repo/infra/docker-compose.yml \
  --env-file /opt/cultivlab/.env up -d <service>
```

---

## Common failure modes

| Symptom                               | Cause                                            | Fix                                                          |
| ------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------ |
| `git pull` permission denied          | Repo files owned by root (previous sudo pull)    | `sudo chown -R $(whoami):$(whoami) /opt/cultivlab/repo`      |
| All env vars blank in docker compose  | `--env-file` not passed; compose file not in CWD | Always pass `--env-file /opt/cultivlab/.env`                 |
| Caddy restart loop, `header_up` error | `header_up` at wrong nesting level in Caddyfile  | Move it inside the `reverse_proxy {}` block                  |
| Service code change not taking effect | Container restarted but not rebuilt              | Run `build` then `up -d`, not `restart`                      |
| `git pull` aborts: local changes      | VM repo has uncommitted changes                  | `git reset --hard origin/main && git clean -fd`              |
| `no configuration file provided`      | `docker compose` run without `-f` flag           | Always use `-f /opt/cultivlab/repo/infra/docker-compose.yml` |

---

## Deploying the student upload portal to existing slots

Used when the portal template changes or when activating the upload feature on an
already-provisioned cohort (new cohorts get it automatically via `provision-sites.sh`).

```bash
cd ~/projects/cultivlab-platform
source .env

# If COHORT_STUDENTS_CSV_PATH in .env points to the wrong file, override:
COHORT_STUDENTS_CSV_PATH=/path/to/cohort-students-cohort-1-2026.csv \
  bash scripts/deploy-portal.sh --dry-run

# Then deploy for real:
COHORT_STUDENTS_CSV_PATH=/path/to/cohort-students-cohort-1-2026.csv \
  bash scripts/deploy-portal.sh
```

The script joins `cohort-slots-${COHORT_NAME}.csv` (slot assignments) with the students CSV (litellm
keys) by slug. Both files must exist and their slugs must match.
