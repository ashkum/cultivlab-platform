#!/usr/bin/env bash
# scripts/reset-student-password.sh
#
# Reset a student's Open WebUI password.
#
# Primary:  POST /api/v1/users/{id}/update  (OW admin API)
# Fallback: bcrypt hash via OW container + direct Postgres UPDATE
#
# Reads cohort-students-${COHORT}.csv to look up the student's OW user ID.
# Updates that CSV with the new password on success.
#
# Usage:
#   bash scripts/reset-student-password.sh \
#     --cohort COHORT --slug SLUG [--password PW] [--dry-run] [--help]
#
# Exit codes: 0 = success, 1 = fatal error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/openwebui_admin.sh
. "${SCRIPT_DIR}/lib/openwebui_admin.sh"

readonly DEFAULT_PW_LEN=16
readonly DEFAULT_POSTGRES_CONTAINER="cultivlab-postgres-1"
readonly DEFAULT_OPENWEBUI_CONTAINER="cultivlab-open-webui-1"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
  cat <<'USAGE'
Usage: bash scripts/reset-student-password.sh \
         --cohort COHORT --slug SLUG [--password PW] [--dry-run] [--help]

Resets a student's Open WebUI password. Tries OW admin API first; falls back
to a direct Postgres UPDATE (via bcrypt hash generated inside the OW container)
if the API returns an error. Updates cohort-students-COHORT.csv on success.

Required flags:
  --cohort COHORT    cohort identifier matching provisioned CSV (e.g. spring-2026)
  --slug   SLUG      student slug (e.g. alice)

Optional flags:
  --password PW      explicit new password (default: random 16-char)
  --dry-run          print intended actions, make zero changes
  --help             show this message and exit

Required env (loaded from .env):
  OPENWEBUI_ADMIN_EMAIL, OPENWEBUI_ADMIN_PASSWORD, DOMAIN or OPENWEBUI_ADMIN_URL
  POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB

Optional env:
  POSTGRES_CONTAINER   container name (default: cultivlab-postgres-1)
  OPENWEBUI_CONTAINER  container name (default: cultivlab-open-webui-1)
USAGE
}

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------

parse_common_args "$@"
if [[ "${CULTIVLAB_HELP:-0}" == "1" ]]; then
  usage
  exit 0
fi

ARG_COHORT=""
ARG_SLUG=""
ARG_PASSWORD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run | --help) shift ;;
    --cohort)
      ARG_COHORT="${2:-}"
      [[ -n "${ARG_COHORT}" ]] || {
        log_error "--cohort requires a value"
        exit 1
      }
      shift 2
      ;;
    --slug)
      ARG_SLUG="${2:-}"
      [[ -n "${ARG_SLUG}" ]] || {
        log_error "--slug requires a value"
        exit 1
      }
      shift 2
      ;;
    --password)
      ARG_PASSWORD="${2:-}"
      [[ -n "${ARG_PASSWORD}" ]] || {
        log_error "--password requires a value"
        exit 1
      }
      shift 2
      ;;
    *)
      log_error "unknown flag: $1"
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${ARG_COHORT}" || -z "${ARG_SLUG}" ]]; then
  log_error "--cohort and --slug are required"
  usage >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Load env
# ---------------------------------------------------------------------------

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "${REPO_ROOT}/.env"
  set +a
fi

require_env OPENWEBUI_ADMIN_EMAIL OPENWEBUI_ADMIN_PASSWORD
require_env POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB

POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-${DEFAULT_POSTGRES_CONTAINER}}"
OPENWEBUI_CONTAINER="${OPENWEBUI_CONTAINER:-${DEFAULT_OPENWEBUI_CONTAINER}}"

# ---------------------------------------------------------------------------
# Find student in cohort-students CSV
# ---------------------------------------------------------------------------

STUDENTS_CSV="${REPO_ROOT}/cohort-students-${ARG_COHORT}.csv"
if [[ ! -f "${STUDENTS_CSV}" ]]; then
  log_error "students CSV not found: ${STUDENTS_CSV}"
  log_error "run provision-students.sh first to generate it"
  exit 1
fi

# CSV header: slug,owui_user_id,email,owui_password,litellm_key
OWUI_ID=""
STUDENT_EMAIL=""
while IFS=, read -r slug owui_id email _rest; do
  if [[ "${slug}" == "${ARG_SLUG}" ]]; then
    OWUI_ID="${owui_id}"
    STUDENT_EMAIL="${email}"
    break
  fi
done <"${STUDENTS_CSV}"

if [[ -z "${OWUI_ID}" || "${OWUI_ID}" == "owui_user_id" ]]; then
  log_error "slug '${ARG_SLUG}' not found in ${STUDENTS_CSV}"
  exit 1
fi

log_info "found: slug=${ARG_SLUG} owui_id=${OWUI_ID} email=${STUDENT_EMAIL}"

# ---------------------------------------------------------------------------
# Generate or validate password
# ---------------------------------------------------------------------------

if [[ -n "${ARG_PASSWORD}" ]]; then
  NEW_PASSWORD="${ARG_PASSWORD}"
else
  NEW_PASSWORD="$(openssl rand -base64 $((DEFAULT_PW_LEN * 2)) | tr -d '=+/' | head -c "${DEFAULT_PW_LEN}")"
fi

if [[ "${#NEW_PASSWORD}" -lt 8 ]]; then
  log_error "password must be at least 8 characters (got ${#NEW_PASSWORD})"
  exit 1
fi

if is_dry_run; then
  log_info "dry-run: would reset OW password for slug=${ARG_SLUG} (owui_id=${OWUI_ID})"
  log_info "dry-run: primary: POST /api/v1/users/${OWUI_ID}/update {password:...}"
  log_info "dry-run: fallback: bcrypt via ${OPENWEBUI_CONTAINER} + psql UPDATE auth"
  log_info "dry-run: would update ${STUDENTS_CSV} owui_password for slug=${ARG_SLUG}"
  log_info "new password would be: ${NEW_PASSWORD}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Init OW admin client + sign in
# ---------------------------------------------------------------------------

openwebui_admin_init
if ! openwebui_signin; then
  log_error "failed to sign in to Open WebUI at ${OPENWEBUI_ADMIN_URL}"
  exit 1
fi

# ---------------------------------------------------------------------------
# Attempt 1: OW admin API
# ---------------------------------------------------------------------------

_try_api_reset() {
  local body
  body="$(jq -n --arg pw "${NEW_PASSWORD}" '{password: $pw}')"
  log_info "primary: POST /api/v1/users/${OWUI_ID}/update"
  set +e
  openwebui_auth_request POST "/api/v1/users/${OWUI_ID}/update" "${body}"
  local rc=$?
  set -e
  if [[ "${rc}" -eq 0 ]]; then
    log_info "OW API reset succeeded"
    return 0
  fi
  log_warn "OW API reset returned HTTP ${OPENWEBUI_LAST_STATUS}; trying Postgres fallback"
  return 1
}

# ---------------------------------------------------------------------------
# Attempt 2: Postgres fallback via OW container bcrypt
# ---------------------------------------------------------------------------

_try_postgres_reset() {
  log_info "fallback: generating bcrypt hash inside ${OPENWEBUI_CONTAINER}"
  local pw_hash
  pw_hash="$(docker exec "${OPENWEBUI_CONTAINER}" python3 -c "
import bcrypt, sys
pw = sys.argv[1].encode()
print(bcrypt.hashpw(pw, bcrypt.gensalt(rounds=12)).decode())
" "${NEW_PASSWORD}")" || {
    log_error "bcrypt generation failed — is ${OPENWEBUI_CONTAINER} running?"
    return 1
  }

  log_info "fallback: UPDATE auth WHERE id=${OWUI_ID}"
  local result
  result="$(docker exec \
    -e PGPASSWORD="${POSTGRES_PASSWORD}" \
    "${POSTGRES_CONTAINER}" \
    psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
    -v pw_hash="${pw_hash}" -v user_id="${OWUI_ID}" \
    -c "UPDATE auth SET password = :'pw_hash' WHERE id = :'user_id';")"

  if echo "${result}" | grep -q "UPDATE 1"; then
    log_info "Postgres UPDATE succeeded"
    return 0
  fi
  if echo "${result}" | grep -q "UPDATE 0"; then
    log_error "Postgres UPDATE affected 0 rows — id=${OWUI_ID} not in auth table"
    return 1
  fi
  log_error "unexpected psql output: ${result}"
  return 1
}

# ---------------------------------------------------------------------------
# Run reset (primary → fallback)
# ---------------------------------------------------------------------------

if ! _try_api_reset; then
  if ! _try_postgres_reset; then
    log_error "both OW API and Postgres fallback failed; password NOT reset"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Update CSV with new password
# ---------------------------------------------------------------------------

log_info "updating ${STUDENTS_CSV}"
TMP_CSV="$(mktemp)"
awk -v slug="${ARG_SLUG}" -v newpw="${NEW_PASSWORD}" \
  'BEGIN{FS=OFS=","} NR==1{print; next} $1==slug{$4=newpw} {print}' \
  "${STUDENTS_CSV}" >"${TMP_CSV}"
mv "${TMP_CSV}" "${STUDENTS_CSV}"
chmod 600 "${STUDENTS_CSV}"
log_info "CSV updated"

# ---------------------------------------------------------------------------
# Done — print new password prominently
# ---------------------------------------------------------------------------

log_info "password reset complete: slug=${ARG_SLUG} email=${STUDENT_EMAIL}"
echo "NEW_PASSWORD=${NEW_PASSWORD}"
