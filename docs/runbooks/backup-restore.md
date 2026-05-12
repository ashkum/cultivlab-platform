# Runbook: Postgres Backup and Restore

**Audience:** Operator (solo founder). **When to use:** Scheduled verification, data-loss incident,
VM migration.

---

## Backup overview

`scripts/backup-postgres.sh` runs daily at 02:00 UTC via `/etc/cron.d/cultivlab-ops`. It:

1. Runs `pg_dump` inside the `cultivlab-postgres-1` container, piped through `gzip`.
2. Uploads the compressed dump + SHA-256 sidecar to GCS in three tiers:

| Tier       | GCS prefix                           | Kept for | When uploaded         |
| ---------- | ------------------------------------ | -------- | --------------------- |
| `daily/`   | `gs://${GCS_BACKUP_BUCKET}/daily/`   | 30 days  | Every run             |
| `weekly/`  | `gs://${GCS_BACKUP_BUCKET}/weekly/`  | 90 days  | Sundays (DOW=0)       |
| `monthly/` | `gs://${GCS_BACKUP_BUCKET}/monthly/` | 365 days | 1st of month (DOM=01) |

3. Posts success/failure notification to `#cultivlab-platform` (Slack).
4. Rotates old files in each tier (deletes backups older than the retention window).

Backup logs: `/var/log/cultivlab/backup-postgres.log`

---

## Verifying a backup exists

```sh
source /opt/cultivlab/.env

# List recent daily backups
gsutil ls -l "gs://${GCS_BACKUP_BUCKET}/daily/" | sort

# Check the SHA-256 sidecar of the latest backup
LATEST="$(gsutil ls gs://${GCS_BACKUP_BUCKET}/daily/*.sql.gz | sort | tail -1)"
gsutil cat "${LATEST%.sql.gz}.sha256"
```

---

## Phase 1 restore — sanity check (safe, non-destructive)

Phase 1 downloads a backup, verifies its SHA-256 checksum, restores it to a temporary database,
counts tables to confirm the dump is coherent, then drops the temp database. It does **not** touch
the production database.

**Run this after every manual backup and at least once before each cohort starts.**

```sh
source /opt/cultivlab/.env

# Find a backup URI to restore
LATEST="$(gsutil ls gs://${GCS_BACKUP_BUCKET}/daily/*.sql.gz | sort | tail -1)"
echo "Restoring: ${LATEST}"

# Preview (no downloads, no DB changes)
sudo bash scripts/restore-postgres.sh "${LATEST}" --dry-run

# Live Phase 1 (downloads, verifies checksum, restores to temp DB, drops temp DB)
sudo bash scripts/restore-postgres.sh "${LATEST}"
```

Expected output (truncated):

```
{"level":"info","msg":"downloading backup ..."}
{"level":"info","msg":"downloaded size=2.1M"}
{"level":"info","msg":"checksum OK sha256=3a7f1b2c..."}
{"level":"info","msg":"phase1: creating temp database ..."}
{"level":"info","msg":"phase1: restoring to temp database"}
{"level":"info","msg":"phase1: sanity table_count=18"}
{"level":"info","msg":"phase1: temp database dropped"}
{"level":"info","msg":"phase1: complete sanity=OK tables=18"}
```

If `table_count` is < 3, the dump is corrupt — do not proceed to Phase 2.

---

## Phase 2 restore — production database replacement

**This is destructive. Read all steps before running. Test with Phase 1 first.**

Phase 2 stops Open WebUI and LiteLLM, drops and recreates the production database, restores from the
backup, then restarts both services. Downtime is typically 2–5 minutes.

### When to use Phase 2

- Data-loss incident (accidental delete, table corruption).
- VM migration: Phase 1 on the new VM, then Phase 2 if checksums match.
- Disaster recovery drill (recommended quarterly).

### Pre-restore checklist

1. Confirm Phase 1 on the same backup file succeeds (`sanity=OK`).
2. Notify students that the platform will be briefly unavailable (if cohort is running).
3. Note the current production DB table count for comparison after restore:

```sh
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" cultivlab-postgres-1 \
  psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
  -t -A -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';"
```

### Execute Phase 2

```sh
source /opt/cultivlab/.env

BACKUP_URI="gs://${GCS_BACKUP_BUCKET}/daily/cultivlab-2026-05-12.sql.gz"  # adjust date

# Dry-run shows both Phase 1 and Phase 2 intended actions
sudo bash scripts/restore-postgres.sh "${BACKUP_URI}" --dry-run --force

# Live run — will prompt: type RESTORE to confirm
sudo bash scripts/restore-postgres.sh "${BACKUP_URI}" --force
```

At the confirmation prompt, type exactly `RESTORE` and press Enter. Any other input aborts without
touching the database.

### Post-restore verification

```sh
# Confirm LiteLLM is healthy
curl -s http://localhost:4000/health/liveliness

# Confirm table count matches pre-restore baseline
docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" cultivlab-postgres-1 \
  psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
  -t -A -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';"

# Confirm Open WebUI is responding
curl -s -o /dev/null -w "%{http_code}" http://localhost:3000
```

---

## Forcing an out-of-schedule backup

```sh
# Force re-run even if today's backup already exists in GCS
sudo bash scripts/backup-postgres.sh --force
```

---

## Manually triggering rotation

Rotation runs automatically at the end of each backup run. If needed, trigger it manually by running
the backup with `--force` (it uploads + rotates in one pass).

---

## Troubleshooting

| Symptom                              | Likely cause                                   | Fix                                                                   |
| ------------------------------------ | ---------------------------------------------- | --------------------------------------------------------------------- |
| `GCS bucket not accessible`          | Bucket doesn't exist or VM SA lacks permission | See `docs/install.md §11.2`                                           |
| `pg_dump failed`                     | Postgres container not running                 | `docker ps`; `docker compose up -d postgres`                          |
| `checksum mismatch`                  | Corrupt download or truncated upload           | Re-download; if persistent, file is corrupt — use an earlier backup   |
| `sanity check failed: only N tables` | Dump is empty or from wrong DB                 | Verify `POSTGRES_DB` env var matches the running DB name              |
| Services fail to start after Phase 2 | Restore partial or schema mismatch             | Check `docker logs cultivlab-litellm-1`; try `docker compose restart` |
