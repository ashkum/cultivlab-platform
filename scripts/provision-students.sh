#!/usr/bin/env bash
# scripts/provision-students.sh — provision Open WebUI accounts from
# cohort-keys-${COHORT_NAME}.csv (Sprint 2 output). Idempotent: re-runs detect
# existing users by email and skip creation. Exit 0 = all OK, 1 = setup failure,
# 2 = partial success (≥1 student row failed; re-run to retry).
# See --help for usage.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] [--csv PATH] [--help]

Reads cohort-keys-\${COHORT_NAME}.csv (output of provision-cohort.sh) and
provisions one Open WebUI account per row. Writes cohort-students-\${COHORT_NAME}.csv
with the Open WebUI user IDs alongside the existing LiteLLM key data.

Required env (loaded from .env at repo root if present):
  COHORT_NAME              cohort identifier (must match Sprint 2 output)
  DOMAIN                   used to derive https://chat.\${DOMAIN}
  OPENWEBUI_ADMIN_EMAIL    admin account email (created during first signup)
  OPENWEBUI_ADMIN_PASSWORD admin account password

Optional env:
  OPENWEBUI_ADMIN_URL      overrides https://chat.\${DOMAIN}
  COHORT_KEYS_CSV_PATH     overrides default cohort-keys CSV location
  STUDENT_PASSWORD_LENGTH  generated password length (default: 16)

Flags:
  --dry-run    print intended actions, make no API calls
  --csv PATH   override COHORT_KEYS_CSV_PATH for this run
  --help       show this help
EOF
}

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------

parse_common_args "$@"

CSV_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run | --help) shift ;;
    --csv)
      CSV_OVERRIDE="${2:-}"
      if [[ -z "${CSV_OVERRIDE}" ]]; then
        log_error "--csv requires a path argument"
        exit 1
      fi
      shift 2
      ;;
    *)
      log_error "unknown argument: $1"
      usage >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Auto-load .env
# ---------------------------------------------------------------------------

if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "${REPO_ROOT}/.env"
  set +a
fi

# shellcheck source=lib/openwebui_admin.sh
. "${SCRIPT_DIR}/lib/openwebui_admin.sh"

# ---------------------------------------------------------------------------
# Resolve cohort-keys.csv path
# ---------------------------------------------------------------------------

require_env COHORT_NAME

if [[ -n "${CSV_OVERRIDE}" ]]; then
  COHORT_KEYS_CSV_PATH="${CSV_OVERRIDE}"
fi
COHORT_KEYS_CSV_PATH="${COHORT_KEYS_CSV_PATH:-${REPO_ROOT}/cohort-keys-${COHORT_NAME}.csv}"

if [[ ! -f "${COHORT_KEYS_CSV_PATH}" ]]; then
  log_error "cohort-keys CSV not found at ${COHORT_KEYS_CSV_PATH}"
  log_error "run provision-cohort.sh first to generate it"
  exit 1
fi

STUDENT_PASSWORD_LENGTH="${STUDENT_PASSWORD_LENGTH:-16}"
if ! [[ "${STUDENT_PASSWORD_LENGTH}" =~ ^[0-9]+$ ]] ||
  ((STUDENT_PASSWORD_LENGTH < 12)); then
  log_error "STUDENT_PASSWORD_LENGTH must be an integer >= 12 (got: ${STUDENT_PASSWORD_LENGTH})"
  exit 1
fi

# Load existing cohort-students CSV (if any) to preserve recorded passwords on
# re-runs. Pattern mirrors _existing_key_for_slug in provision-cohort.sh.
# CSV header: slug,owui_user_id,email,owui_password,litellm_key
EXISTING_PW_SLUGS=()
EXISTING_PW_PASSWORDS=()
OUT_CSV="$(dirname "${COHORT_KEYS_CSV_PATH}")/cohort-students-${COHORT_NAME}.csv"
if [[ -f "${OUT_CSV}" ]]; then
  log_info "loading existing cohort-students.csv: ${OUT_CSV}"
  ep_first=1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ ${ep_first} -eq 1 ]]; then
      ep_first=0
      continue
    fi
    if [[ -z "$(printf '%s' "${line}" | tr -d '[:space:]')" ]]; then continue; fi
    IFS=',' read -ra ep_parts <<<"${line},__EOL__"
    unset "ep_parts[$((${#ep_parts[@]} - 1))]"
    EXISTING_PW_SLUGS+=("${ep_parts[0]:-}")
    EXISTING_PW_PASSWORDS+=("${ep_parts[3]:-}")
  done <"${OUT_CSV}"
  log_info "loaded ${#EXISTING_PW_SLUGS[@]} existing password rows"
fi

_existing_password_for_slug() {
  local slug="$1" i
  for ((i = 0; i < ${#EXISTING_PW_SLUGS[@]}; i++)); do
    if [[ "${EXISTING_PW_SLUGS[$i]}" == "${slug}" ]]; then
      printf '%s' "${EXISTING_PW_PASSWORDS[$i]}"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Init Open WebUI admin client
# ---------------------------------------------------------------------------

openwebui_admin_init

# ---------------------------------------------------------------------------
# Sign in as admin (skipped in dry-run; signin stub sets JWT to dry-run-stub-jwt)
# ---------------------------------------------------------------------------

if ! openwebui_signin; then
  log_error "could not sign in to Open WebUI at ${OPENWEBUI_ADMIN_URL}"
  log_error "verify OPENWEBUI_ADMIN_EMAIL/PASSWORD and that chat.\${DOMAIN} is reachable"
  exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_generate_password() {
  # URL-safe random password. base64 + tr to strip = / +.
  openssl rand -base64 "$((STUDENT_PASSWORD_LENGTH * 2))" |
    tr -d '=+/' |
    head -c "${STUDENT_PASSWORD_LENGTH}"
}

# ---------------------------------------------------------------------------
# Result accumulators
# ---------------------------------------------------------------------------

RESULT_SLUGS=()
RESULT_OWUI_USER_IDS=()
RESULT_EMAILS=()
RESULT_OWUI_PASSWORDS=()
RESULT_LITELLM_KEYS=()

PROVISIONED_NEW=0
PROVISIONED_KEPT=0
PROVISIONED_FAILED=0

# ---------------------------------------------------------------------------
# Provision one row (slug,name,email,parent_email,key,key_alias)
# ---------------------------------------------------------------------------

provision_one() {
  local slug="$1" name="$2" email="$3" parent_email="$4" litellm_key="$5"

  # Check existing user.
  set +e
  openwebui_user_get_by_email "${email}"
  local rc=$?
  set -e

  if [[ "${rc}" -eq 0 ]]; then
    # User exists; reconcile (in v0.5.20 we cannot read/reset their password
    # without their cooperation, so we mark this as "kept" and emit the row
    # with an empty password to signal the operator to use the recorded one).
    local owui_id
    owui_id="$(echo "${OPENWEBUI_LAST_BODY}" | jq -r '.id // empty')"
    if [[ -z "${owui_id}" ]]; then
      log_error "row slug=${slug}: existing user has no id"
      return 1
    fi
    log_info "row slug=${slug}: user already exists (id=${owui_id}); kept"
    PROVISIONED_KEPT=$((PROVISIONED_KEPT + 1))
    # Preserve the recorded password — writing empty string would destroy it.
    local preserved_pw=""
    if preserved_pw="$(_existing_password_for_slug "${slug}")"; then
      log_info "row slug=${slug}: preserved recorded password from existing CSV"
    else
      log_warn "row slug=${slug}: no recorded password found; use reset-student-password.sh to set one"
    fi
    RESULT_SLUGS+=("${slug}")
    RESULT_OWUI_USER_IDS+=("${owui_id}")
    RESULT_EMAILS+=("${email}")
    RESULT_OWUI_PASSWORDS+=("${preserved_pw}")
    RESULT_LITELLM_KEYS+=("${litellm_key}")
    return 0
  elif [[ "${rc}" -eq 2 ]]; then
    log_error "row slug=${slug}: lookup failed"
    return 1
  fi

  # User does not exist; create.
  local password
  password="$(_generate_password)"

  if ! openwebui_user_add "${email}" "${password}" "${name}" "user"; then
    log_error "row slug=${slug}: user_add failed"
    return 1
  fi

  local owui_id
  if is_dry_run; then
    owui_id="dry-run-stub-id"
  else
    owui_id="$(echo "${OPENWEBUI_LAST_BODY}" | jq -r '.id // empty')"
    if [[ -z "${owui_id}" ]]; then
      log_error "row slug=${slug}: create returned no id; body=${OPENWEBUI_LAST_BODY}"
      return 1
    fi
  fi

  log_info "row slug=${slug}: created user (id=${owui_id})"
  PROVISIONED_NEW=$((PROVISIONED_NEW + 1))
  RESULT_SLUGS+=("${slug}")
  RESULT_OWUI_USER_IDS+=("${owui_id}")
  RESULT_EMAILS+=("${email}")
  RESULT_OWUI_PASSWORDS+=("${password}")
  RESULT_LITELLM_KEYS+=("${litellm_key}")
  return 0
}

# ---------------------------------------------------------------------------
# Iterate cohort-keys.csv
# ---------------------------------------------------------------------------

# cohort-keys CSV header: slug,name,email,parent_email,key,key_alias
log_info "reading ${COHORT_KEYS_CSV_PATH}"

ROW_NUM=0
while IFS=, read -r slug name email parent_email key _key_alias; do
  ROW_NUM=$((ROW_NUM + 1))
  # Skip header row.
  if [[ "${ROW_NUM}" -eq 1 && "${slug}" == "slug" ]]; then
    continue
  fi
  if [[ -z "${slug}" || -z "${email}" ]]; then
    log_warn "row ${ROW_NUM}: empty slug or email; skipped"
    continue
  fi
  if ! provision_one "${slug}" "${name}" "${email}" "${parent_email}" "${key}"; then
    PROVISIONED_FAILED=$((PROVISIONED_FAILED + 1))
  fi
done <"${COHORT_KEYS_CSV_PATH}"

# ---------------------------------------------------------------------------
# Write cohort-students-${COHORT_NAME}.csv (live mode only)
# ---------------------------------------------------------------------------

if ! is_dry_run; then
  log_info "writing ${OUT_CSV}"
  {
    echo "slug,owui_user_id,email,owui_password,litellm_key"
    for i in "${!RESULT_SLUGS[@]}"; do
      echo "${RESULT_SLUGS[$i]},${RESULT_OWUI_USER_IDS[$i]},${RESULT_EMAILS[$i]},${RESULT_OWUI_PASSWORDS[$i]},${RESULT_LITELLM_KEYS[$i]}"
    done
  } >"${OUT_CSV}"
  chmod 600 "${OUT_CSV}"
  log_info "wrote ${#RESULT_SLUGS[@]} rows to ${OUT_CSV} (mode 600)"
fi

# ---------------------------------------------------------------------------
# Summary + exit code
# ---------------------------------------------------------------------------

log_info "summary: new=${PROVISIONED_NEW} kept=${PROVISIONED_KEPT} failed=${PROVISIONED_FAILED}"

if [[ "${PROVISIONED_FAILED}" -gt 0 ]]; then
  log_error "${PROVISIONED_FAILED} rows failed; re-run to reconcile"
  exit 2
fi
exit 0
