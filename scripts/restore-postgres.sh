#!/usr/bin/env bash
# scripts/restore-postgres.sh — download a GCS backup, verify checksum, restore.
#
# Two-phase restore:
#   Phase 1 (always): restore to a temporary database and run a sanity check,
#                     then drop the temp database.
#   Phase 2 (--force only): stop Open WebUI + LiteLLM, drop + recreate the
#                     production database, restore from backup, restart services.
#                     Requires interactive confirmation ("RESTORE") at the prompt.
#
# Usage: restore-postgres.sh <gcs-uri> [--force] [--dry-run] [--help]
#   <gcs-uri>  Full GCS path, e.g.:
#              gs://my-bucket/daily/cultivlab-2026-05-12.sql.gz
#
# See docs/runbooks/backup-restore.md for the full operator runbook.
#
# Exit codes: 0 = success, 1 = config/setup error, 2 = runtime error.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_TMP=""

# ── Logging ────────────────────────────────────────────────────────────────
log() {
  local level="$1"
  shift
  local msg="$*"
  msg="${msg//\\/\\\\}"
  msg="${msg//\"/\\\"}"
  printf '{"level":"%s","msg":"%s","ts":"%s","script":"%s"}\n' \
    "$level" "$msg" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SCRIPT_NAME"
}

# ── Temp file cleanup ──────────────────────────────────────────────────────
_cleanup() {
  if [[ -n "$BACKUP_TMP" && -f "$BACKUP_TMP" ]]; then rm -f "$BACKUP_TMP"; fi
}
trap _cleanup EXIT

# ── Arg parsing ────────────────────────────────────────────────────────────
GCS_URI=""
DRY_RUN=false
FORCE=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --force) FORCE=true ;;
    --help | -h)
      cat <<EOF
Usage: $SCRIPT_NAME <gcs-uri> [--force] [--dry-run] [--help]

Phase 1 (always): downloads backup, verifies SHA-256, restores to a temp
database, runs sanity checks, drops temp database.

Phase 2 (--force): after operator confirmation, stops Open WebUI + LiteLLM,
replaces the production database, restarts services.

Arguments:
  <gcs-uri>   GCS path to a .sql.gz backup file, e.g.:
              gs://my-bucket/daily/cultivlab-2026-05-12.sql.gz

Required env (auto-loaded from /opt/cultivlab/.env):
  POSTGRES_USER  POSTGRES_DB  POSTGRES_PASSWORD  GCS_BACKUP_BUCKET

Optional env:
  POSTGRES_CONTAINER   default: cultivlab-postgres-1
  LITELLM_CONTAINER    default: cultivlab-litellm-1
  OPENWEBUI_CONTAINER  default: cultivlab-open-webui-1

Flags:
  --force    Enable Phase 2 (production restore). Prompts for confirmation.
  --dry-run  Print intended actions; make no changes.
  --help     Show this message.
EOF
      exit 0
      ;;
    gs://*) GCS_URI="$arg" ;;
    *)
      log error "unknown argument: $arg"
      exit 1
      ;;
  esac
done

if [[ -z "$GCS_URI" ]]; then
  log error "missing required argument: <gcs-uri>"
  exit 1
fi

# ── Load .env ──────────────────────────────────────────────────────────────
ENV_FILE="/opt/cultivlab/.env"
[[ ! -f "$ENV_FILE" ]] && ENV_FILE="${REPO_ROOT}/.env"
if [[ -f "$ENV_FILE" ]]; then
  log info "loading env from $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# ── Validate required env ──────────────────────────────────────────────────
_require() {
  local missing=()
  for v in "$@"; do [[ -z "${!v:-}" ]] && missing+=("$v"); done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log error "missing required env vars: ${missing[*]}"
    exit 1
  fi
}
_require POSTGRES_USER POSTGRES_DB POSTGRES_PASSWORD

if [[ "$DRY_RUN" == "false" ]]; then
  for cmd in jq gsutil sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || {
      log error "$cmd not found on PATH"
      exit 1
    }
  done
fi

POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-cultivlab-postgres-1}"
LITELLM_CONTAINER="${LITELLM_CONTAINER:-cultivlab-litellm-1}"
OPENWEBUI_CONTAINER="${OPENWEBUI_CONTAINER:-cultivlab-open-webui-1}"

# Temp DB name: unique per-run to avoid collisions if a prior run was interrupted.
RESTORE_DB="${POSTGRES_DB}_restore_verify_$(date -u +%Y%m%d%H%M%S)"

# ── Dry-run: show intended actions and exit ────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  echo ""
  echo "=== Postgres restore dry-run ==="
  printf "  Source  : %s\n" "$GCS_URI"
  printf "  Verify  : gsutil cat %s.sha256 → sha256sum check\n" "${GCS_URI%.sql.gz}"
  printf "  Phase 1 : restore → %s, sanity check, drop\n" "$RESTORE_DB"
  if [[ "$FORCE" == "true" ]]; then
    printf "  Phase 2 : stop %s %s\n" "$LITELLM_CONTAINER" "$OPENWEBUI_CONTAINER"
    printf "            drop + recreate %s → restore → restart services\n" "$POSTGRES_DB"
  else
    echo "  Phase 2 : skipped (pass --force to enable production restore)"
  fi
  echo "================================="
  log info "dry-run complete uri=${GCS_URI}"
  exit 0
fi

# ── Phase 0: download + checksum verify ───────────────────────────────────
log info "downloading backup uri=${GCS_URI}"
BACKUP_TMP="$(mktemp /tmp/cultivlab-restore-XXXXXX.sql.gz)"

gsutil -q cp "${GCS_URI}" "${BACKUP_TMP}" || {
  log error "download failed: ${GCS_URI}"
  exit 2
}
BACKUP_SIZE="$(du -sh "$BACKUP_TMP" | cut -f1)"
log info "downloaded size=${BACKUP_SIZE}"

log info "verifying checksum"
EXPECTED="$(gsutil -q cat "${GCS_URI%.sql.gz}.sha256" 2>/dev/null)" || {
  log error "failed to fetch sidecar: ${GCS_URI%.sql.gz}.sha256"
  exit 2
}
ACTUAL="$(sha256sum "${BACKUP_TMP}" | awk '{print $1}')"
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  log error "checksum mismatch expected=${EXPECTED} actual=${ACTUAL}"
  exit 2
fi
log info "checksum OK sha256=${ACTUAL:0:16}..."

# ── psql helpers ────────────────────────────────────────────────────────────
_psql() { # _psql <db> <sql>
  docker exec -e PGPASSWORD="${POSTGRES_PASSWORD}" "${POSTGRES_CONTAINER}" \
    psql -U "${POSTGRES_USER}" -d "$1" -t -A -c "$2" 2>/dev/null
}

_psql_restore() { # pipe gunzip into psql for restore
  gunzip -c "${BACKUP_TMP}" |
    docker exec -i -e PGPASSWORD="${POSTGRES_PASSWORD}" "${POSTGRES_CONTAINER}" \
      psql -U "${POSTGRES_USER}" -d "$1" -v ON_ERROR_STOP=1 -q 2>/dev/null
}

# ── Phase 1: temp DB restore + sanity ─────────────────────────────────────
log info "phase1: creating temp database restore_db=${RESTORE_DB}"
_psql postgres "CREATE DATABASE \"${RESTORE_DB}\" OWNER \"${POSTGRES_USER}\";" || {
  log error "failed to create temp database"
  exit 2
}

log info "phase1: restoring to temp database"
_psql_restore "${RESTORE_DB}" || {
  _psql postgres "DROP DATABASE IF EXISTS \"${RESTORE_DB}\";" 2>/dev/null || true
  log error "restore to temp database failed"
  exit 2
}

# Sanity: count tables in public schema; expect at least the core LiteLLM tables.
TABLE_COUNT="$(_psql "${RESTORE_DB}" \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';")"
log info "phase1: sanity table_count=${TABLE_COUNT}"

_psql postgres "DROP DATABASE IF EXISTS \"${RESTORE_DB}\";" || true
log info "phase1: temp database dropped"

if [[ "${TABLE_COUNT:-0}" -lt 3 ]]; then
  log error "sanity check failed: only ${TABLE_COUNT} tables found in restore; aborting"
  exit 2
fi
log info "phase1: complete sanity=OK tables=${TABLE_COUNT}"

if [[ "$FORCE" == "false" ]]; then
  log info "phase2 skipped (no --force); backup verified clean"
  exit 0
fi

# ── Phase 2: production restore ────────────────────────────────────────────
cat >&2 <<'WARN'

  ╔══════════════════════════════════════════════════════════════════╗
  ║  WARNING: PRODUCTION DATABASE RESTORE                           ║
  ║  This will DROP and REPLACE the live cultivlab database.        ║
  ║  Open WebUI and LiteLLM will be stopped during the restore.     ║
  ╚══════════════════════════════════════════════════════════════════╝

WARN
printf 'Type RESTORE to confirm production database replacement: ' >&2
read -r confirmation </dev/tty
if [[ "$confirmation" != "RESTORE" ]]; then
  log info "confirmation not given; aborting production restore"
  exit 0
fi

log info "phase2: stopping services litellm=${LITELLM_CONTAINER} owui=${OPENWEBUI_CONTAINER}"
docker stop "${LITELLM_CONTAINER}" "${OPENWEBUI_CONTAINER}" 2>/dev/null || {
  log error "failed to stop services; aborting to avoid data corruption"
  exit 2
}

log info "phase2: terminating connections to ${POSTGRES_DB}"
_psql postgres \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity \
   WHERE datname='${POSTGRES_DB}' AND pid <> pg_backend_pid();" \
  >/dev/null || true

log info "phase2: dropping and recreating ${POSTGRES_DB}"
_psql postgres "DROP DATABASE IF EXISTS \"${POSTGRES_DB}\";" || {
  docker start "${LITELLM_CONTAINER}" "${OPENWEBUI_CONTAINER}" 2>/dev/null || true
  log error "failed to drop production database"
  exit 2
}
_psql postgres "CREATE DATABASE \"${POSTGRES_DB}\" OWNER \"${POSTGRES_USER}\";" || {
  log error "failed to recreate production database — manual recovery required"
  exit 2
}

log info "phase2: restoring production database"
_psql_restore "${POSTGRES_DB}" || {
  log error "production restore failed — database may be empty; manual recovery required"
  exit 2
}

log info "phase2: restarting services"
docker start "${LITELLM_CONTAINER}" "${OPENWEBUI_CONTAINER}" || {
  log error "services failed to start after restore — check docker logs"
  exit 2
}

log info "phase2: complete production restore OK"
exit 0
