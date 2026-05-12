#!/usr/bin/env bash
# scripts/backup-postgres.sh — daily pg_dump → gzip → GCS with tiered rotation.
#
# Creates a compressed Postgres dump and uploads it to three GCS tiers:
#   daily/   → kept for 30 days  (every run)
#   weekly/  → kept for 90 days  (Sundays only, DOW=0)
#   monthly/ → kept for 365 days (1st of month only)
#
# A .sha256 sidecar is uploaded alongside each .sql.gz for restore verification.
# On exit (success or failure) a notification is posted to SLACK_WEBHOOK_PLATFORM.
#
# Designed to run as a root crontab job on the VM at 02:00 UTC daily.
# GCS bucket must be created before first run:
#   gsutil mb -p ${GCP_PROJECT_ID} -l us-central1 gs://${GCS_BACKUP_BUCKET}
# See docs/install.md §11 for full cron + bucket setup.
#
# Exit codes: 0 = success, 1 = config/setup error, 2 = runtime error.
# Usage: backup-postgres.sh [--dry-run] [--force] [--help]

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="/var/log/cultivlab"
BACKUP_TMP=""
BACKUP_STATUS="failure" # set to "success" only at the very end

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

# ── EXIT trap: temp cleanup + failure Slack ────────────────────────────────
_on_exit() {
  if [[ -n "$BACKUP_TMP" && -f "$BACKUP_TMP" ]]; then rm -f "$BACKUP_TMP"; fi
  if [[ -n "$BACKUP_TMP" && -f "${BACKUP_TMP}.sha256" ]]; then rm -f "${BACKUP_TMP}.sha256"; fi
  if [[ "$BACKUP_STATUS" != "success" && "${DRY_RUN:-false}" == "false" &&
    -n "${SLACK_WEBHOOK_PLATFORM:-}" ]]; then
    local fail_msg
    fail_msg="❌ *CultivLab Postgres Backup FAILED — $(date -u +%Y-%m-%d)*
Check cron logs: $LOG_DIR/backup-postgres.log"
    curl -sSf -o /dev/null -X POST -H 'Content-Type: application/json' \
      --data-raw "$(jq -nc --arg t "$fail_msg" '{text: $t}')" \
      "${SLACK_WEBHOOK_PLATFORM}" 2>/dev/null || true
  fi
}
trap _on_exit EXIT

# ── Arg parsing ────────────────────────────────────────────────────────────
DRY_RUN=false
FORCE=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --force) FORCE=true ;;
    --help | -h)
      cat <<EOF
Usage: $SCRIPT_NAME [--dry-run] [--force] [--help]

Dumps Postgres, compresses with gzip, uploads to GCS with tiered rotation.
Designed to run at 02:00 UTC daily (see docs/install.md §11).

Required env (auto-loaded from /opt/cultivlab/.env):
  POSTGRES_USER  POSTGRES_DB  POSTGRES_PASSWORD
  GCS_BACKUP_BUCKET  SLACK_WEBHOOK_PLATFORM

Optional env:
  POSTGRES_CONTAINER  Docker container name (default: cultivlab-postgres-1)

Flags:
  --dry-run  Print intended actions; make no changes to DB or GCS.
  --force    Upload even if today's backup already exists in GCS.
  --help     Show this message.
EOF
      BACKUP_STATUS="success" # prevent spurious failure Slack on --help
      exit 0
      ;;
    *)
      log error "unknown argument: $arg"
      exit 1
      ;;
  esac
done

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
_require POSTGRES_USER POSTGRES_DB POSTGRES_PASSWORD \
  GCS_BACKUP_BUCKET SLACK_WEBHOOK_PLATFORM

if [[ "$DRY_RUN" == "false" ]]; then
  for cmd in jq gsutil; do
    command -v "$cmd" >/dev/null 2>&1 || {
      log error "$cmd not found on PATH"
      exit 1
    }
  done
fi
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-cultivlab-postgres-1}"

# Only create log dir in live mode.
[[ "$DRY_RUN" == "false" ]] && mkdir -p "$LOG_DIR"

# ── Date + GCS path setup ──────────────────────────────────────────────────
DATE_UTC="$(date -u +%Y-%m-%d)"
DOW="$(date -u +%w)" # 0 = Sunday
DOM="$(date -u +%d)" # 01–31
FNAME="cultivlab-${DATE_UTC}.sql.gz"
GCS_BASE="gs://${GCS_BACKUP_BUCKET}"
GCS_DAILY="${GCS_BASE}/daily/${FNAME}"

log info "date=${DATE_UTC} dow=${DOW} dom=${DOM} bucket=${GCS_BACKUP_BUCKET} dry_run=${DRY_RUN}"

# ── Dry-run: show intended actions and exit ────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  echo ""
  echo "=== Postgres backup dry-run ==="
  printf "  Dump   : docker exec %s pg_dump -U %s %s | gzip\n" \
    "$POSTGRES_CONTAINER" "$POSTGRES_USER" "$POSTGRES_DB"
  printf "  Upload : %s\n" "$GCS_DAILY"
  [[ "$DOW" == "0" ]] && printf "  Upload : %s/weekly/%s  (Sunday)\n" "$GCS_BASE" "$FNAME"
  [[ "$DOM" == "01" ]] && printf "  Upload : %s/monthly/%s (1st of month)\n" "$GCS_BASE" "$FNAME"
  echo "  Rotate : daily/ >30d, weekly/ >90d, monthly/ >365d"
  echo "================================"
  log info "dry-run complete"
  BACKUP_STATUS="success"
  exit 0
fi

# ── Preflight: verify GCS bucket is accessible ─────────────────────────────
gsutil -q ls "${GCS_BASE}" 2>/dev/null || {
  log error "GCS bucket not accessible: ${GCS_BASE}"
  log error "Create with: gsutil mb -p \${GCP_PROJECT_ID} -l us-central1 ${GCS_BASE}"
  exit 1
}

# ── Idempotency: skip if today's daily backup already exists ───────────────
if [[ "$FORCE" == "false" ]] && gsutil -q stat "${GCS_DAILY}" 2>/dev/null; then
  log info "backup already exists: ${GCS_DAILY}; skipping (use --force to overwrite)"
  BACKUP_STATUS="success"
  exit 0
fi

# ── pg_dump → gzip → temp file ─────────────────────────────────────────────
BACKUP_TMP="$(mktemp /tmp/cultivlab-backup-XXXXXX.sql.gz)"
log info "starting pg_dump db=${POSTGRES_DB}"

docker exec \
  -e PGPASSWORD="${POSTGRES_PASSWORD}" \
  "${POSTGRES_CONTAINER}" \
  pg_dump -U "${POSTGRES_USER}" "${POSTGRES_DB}" |
  gzip >"${BACKUP_TMP}" || {
  log error "pg_dump failed"
  exit 2
}

BACKUP_SIZE="$(du -sh "$BACKUP_TMP" | cut -f1)"
log info "pg_dump complete size=${BACKUP_SIZE}"

# SHA-256 checksum sidecar
sha256sum "${BACKUP_TMP}" | awk '{print $1}' >"${BACKUP_TMP}.sha256"
CHECKSUM="$(cat "${BACKUP_TMP}.sha256")"
log info "sha256=${CHECKSUM}"

# ── GCS upload helper ──────────────────────────────────────────────────────
_upload() {
  local dest="$1"
  gsutil -q cp "${BACKUP_TMP}" "${dest}" || {
    log error "upload failed: ${dest}"
    exit 2
  }
  gsutil -q cp "${BACKUP_TMP}.sha256" "${dest%.sql.gz}.sha256" || {
    log error "sidecar failed: ${dest}"
    exit 2
  }
  log info "uploaded: ${dest}"
}

_upload "${GCS_DAILY}"
if [[ "$DOW" == "0" ]]; then
  _upload "${GCS_BASE}/weekly/${FNAME}"
  log info "Sunday — weekly tier uploaded"
fi
if [[ "$DOM" == "01" ]]; then
  _upload "${GCS_BASE}/monthly/${FNAME}"
  log info "1st — monthly tier uploaded"
fi

# ── Rotation ───────────────────────────────────────────────────────────────
# rotate_tier <gs_prefix> <days_to_keep>
# Deletes .sql.gz (+ .sha256 sidecar) where filename date < cutoff.
rotate_tier() {
  local prefix="$1" keep_days="$2" count=0
  local cutoff
  cutoff="$(date -u -d "${keep_days} days ago" +%Y-%m-%d)"
  while IFS= read -r uri; do
    [[ -z "$uri" ]] && continue
    local fname date_part
    fname="$(basename "$uri")"
    date_part="${fname#cultivlab-}"
    date_part="${date_part%.sql.gz}"
    if [[ "$date_part" < "$cutoff" ]]; then
      gsutil -q rm "$uri" "${uri%.sql.gz}.sha256" 2>/dev/null || true
      log info "rotated: $uri"
      ((count++)) || true
    fi
  done < <(gsutil ls "${prefix}*.sql.gz" 2>/dev/null || true)
  log info "rotation tier=${prefix} cutoff=${cutoff} deleted=${count}"
}

rotate_tier "${GCS_BASE}/daily/" 30
rotate_tier "${GCS_BASE}/weekly/" 90
rotate_tier "${GCS_BASE}/monthly/" 365

# ── Slack success notification ─────────────────────────────────────────────
MSG="✅ *CultivLab Postgres Backup — ${DATE_UTC}*
*DB:* ${POSTGRES_DB} | *Size:* ${BACKUP_SIZE} | *SHA256:* \`${CHECKSUM:0:16}...\`
*Path:* ${GCS_DAILY}"

HTTP_CODE="$(curl -sSf -o /dev/null -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' \
  --data-raw "$(jq -nc --arg t "$MSG" '{text: $t}')" \
  "${SLACK_WEBHOOK_PLATFORM}" 2>/dev/null || echo "000")"

if [[ "$HTTP_CODE" != "200" ]]; then
  log error "Slack post failed HTTP=${HTTP_CODE}"
  exit 2
fi

BACKUP_STATUS="success"
log info "backup complete date=${DATE_UTC} size=${BACKUP_SIZE}"
exit 0
