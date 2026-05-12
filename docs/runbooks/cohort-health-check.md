# Runbook: Cohort Health Check

**Audience:** Operator (solo founder). **Cadence:** Run before cohort starts (pre-flight), daily
during cohort, and after any incident.

---

## Automated daily checks

These run without operator involvement via `/etc/cron.d/cultivlab-ops`:

| Time (UTC) | Script                   | What it checks                                         | Alert channel         |
| ---------- | ------------------------ | ------------------------------------------------------ | --------------------- |
| 02:00      | `backup-postgres.sh`     | pg_dump success, GCS upload, checksum                  | `#cultivlab-platform` |
| 23:00      | `daily-summary.sh`       | Per-cohort + per-student 24h spend and request counts  | `#cultivlab-reports`  |
| 23:30      | `weekly-cap-enforcer.sh` | 7-day rolling spend vs `STUDENT_WEEKLY_BUDGET` per key | `#cultivlab-budget`   |

**If a Slack notification stops arriving:** check the cron log for that script:

```sh
tail -50 /var/log/cultivlab/daily-summary.log
tail -50 /var/log/cultivlab/backup-postgres.log
tail -50 /var/log/cultivlab/weekly-cap-enforcer.log
```

---

## Manual health check — full stack

Run this before starting a cohort and after any platform change.

### 1. VM and Docker status

```sh
# All five containers should be Up and healthy
docker ps --format "table {{.Names}}\t{{.Status}}"

# Expected output:
# cultivlab-caddy-1       Up X hours
# cultivlab-litellm-1     Up X hours (healthy)
# cultivlab-open-webui-1  Up X hours
# cultivlab-postgres-1    Up X hours (healthy)
```

### 2. Public endpoint smoke test (from laptop)

```sh
source .env   # on your laptop
curl -fsSL "https://api.${DOMAIN}/health/liveliness" && echo "LiteLLM OK"
curl -fsSL -o /dev/null -w "%{http_code}" "https://chat.${DOMAIN}" && echo ""  # expect 200
```

### 3. Postgres reachability

```sh
# On the VM
source /opt/cultivlab/.env
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" cultivlab-postgres-1 \
  psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
  -t -A -c "SELECT NOW();"
```

### 4. LiteLLM spend logs are being written

```sh
source /opt/cultivlab/.env
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" cultivlab-postgres-1 \
  psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
  -t -A -c "SELECT COUNT(*) FROM \"LiteLLM_SpendLogs\" WHERE \"startTime\" > NOW() - INTERVAL '24 hours';"
```

Zero rows before any student activity is expected. Non-zero rows confirm attribution is working.

### 5. Student virtual keys are active

```sh
source /opt/cultivlab/.env
# List all keys in the cohort team, showing blocked status
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" cultivlab-postgres-1 \
  psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
  -t -A -F'|' -c "
    SELECT COALESCE(metadata->>'slug', key_alias), spend, blocked
    FROM \"LiteLLM_VerificationToken\"
    WHERE team_id = (
      SELECT team_id FROM \"LiteLLM_TeamTable\"
      WHERE team_alias = '${COHORT_NAME}' LIMIT 1
    )
    ORDER BY key_alias;"
```

### 6. Cohort budget status

```sh
source /opt/cultivlab/.env
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" cultivlab-postgres-1 \
  psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
  -t -A -c "
    SELECT team_alias, ROUND(spend::numeric,4) AS spend,
           ROUND(max_budget::numeric,2) AS max_budget, blocked
    FROM \"LiteLLM_TeamTable\"
    WHERE team_alias = '${COHORT_NAME}';"
```

### 7. Recent backup exists and is valid

```sh
source /opt/cultivlab/.env
LATEST="$(gsutil ls gs://${GCS_BACKUP_BUCKET}/daily/*.sql.gz | sort | tail -1)"
echo "Latest backup: ${LATEST}"
# Quick Phase 1 restore (non-destructive sanity check)
sudo bash scripts/restore-postgres.sh "${LATEST}"
```

### 8. Run daily-summary in dry-run (confirm report logic)

```sh
sudo bash scripts/daily-summary.sh --dry-run
```

Review the preview output. Confirm student names and spend numbers look plausible.

### 9. Slack webhooks are live

```sh
source /opt/cultivlab/.env
# Test the reports webhook (posts to #cultivlab-reports)
curl -sSf -X POST "${SLACK_WEBHOOK_REPORTS}" \
  -H 'Content-Type: application/json' \
  -d '{"text":"[health-check] #cultivlab-reports webhook OK"}'
```

Repeat for `SLACK_WEBHOOK_BUDGET` and `SLACK_WEBHOOK_PLATFORM`. Expect HTTP 200 from each.

---

## Pre-cohort checklist

Run at least 24 hours before students log in for the first time.

- [ ] All five Docker containers Up and healthy (`docker ps`)
- [ ] `https://chat.${DOMAIN}` returns 200 from a student browser (incognito)
- [ ] `https://api.${DOMAIN}/health/liveliness` returns 200
- [ ] All student virtual keys present, unblocked, and at \$0.00 spend
- [ ] Cohort team at \$0.00 spend, max_budget matches `COHORT_MAX_BUDGET`
- [ ] Phase 1 restore succeeds on most recent backup
- [ ] `daily-summary.sh --dry-run` shows expected student list
- [ ] `weekly-cap-enforcer.sh --dry-run` shows all students under budget
- [ ] Slack webhooks receive test messages in all three channels
- [ ] Cron entries present: `cat /etc/cron.d/cultivlab-ops`
- [ ] VM disk ≥ 30% free: `df -h /`

---

## During-cohort daily checks (2 minutes)

1. Open `#cultivlab-reports` in Slack — confirm last night's summary arrived.
2. Scan for any ⛔ (blocked student) or anomalous spend.
3. Open `#cultivlab-budget` — confirm no unexpected blocks fired.
4. Open `#cultivlab-platform` — confirm backup success notification.

If the backup notification is missing: check `/var/log/cultivlab/backup-postgres.log` and run
`sudo bash scripts/backup-postgres.sh --force` to recover.

---

## Unblocking a student manually

If a student was blocked by `weekly-cap-enforcer.sh` and an exception is warranted:

```sh
source /opt/cultivlab/.env
# Replace 'alice-smith' with the student's slug (= key_alias suffix after COHORT_NAME-)
KEY_ALIAS="${COHORT_NAME}-alice-smith"

docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" cultivlab-postgres-1 \
  psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
  -c "UPDATE \"LiteLLM_VerificationToken\"
      SET blocked = false
      WHERE key_alias = '${KEY_ALIAS}';"
```

The unblock takes effect within ~60 seconds as LiteLLM's cache expires. Post a note in
`#cultivlab-budget` explaining the exception.
