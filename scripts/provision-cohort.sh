#!/usr/bin/env bash
# scripts/provision-cohort.sh — provision LiteLLM cohort team + per-student
# virtual keys from students.csv. Idempotent (re-runs reconcile budgets &
# preserve recorded plaintext). Exit 0 = all OK, 1 = setup failure,
# 2 = partial success (team OK, ≥1 student row failed; re-run to retry).
# See --help for usage.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<USAGE
$(basename "$0") [--dry-run] [--help] [--csv <path>]

Provision LiteLLM cohort team + per-student virtual keys from STUDENTS_CSV_PATH
(.env is auto-loaded from repo root). Writes cohort-keys-\${COHORT_NAME}.csv
next to students.csv (mode 0600, columns: slug,name,email,parent_email,key,key_alias).
Idempotent: re-runs reconcile budgets and preserve plaintext recorded earlier;
keys with no recorded plaintext are logged + omitted from cohort-keys.csv.

  --dry-run    log intended actions, make zero changes (no CSV write)
  --csv PATH   override STUDENTS_CSV_PATH
  --help, -h   show this and exit
USAGE
}

# Parse flags. parse_common_args handles --dry-run / --help non-destructively.
parse_common_args "$@"
if [[ "${CULTIVLAB_HELP:-0}" == "1" ]]; then
  usage
  exit 0
fi

CSV_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --csv)
      CSV_OVERRIDE="${2:-}"
      shift 2
      ;;
    --csv=*)
      CSV_OVERRIDE="${1#--csv=}"
      shift
      ;;
    --dry-run | --help | -h) shift ;;
    *) shift ;;
  esac
done

# Auto-load .env from repo root.
ENV_FILE="${REPO_ROOT}/.env"
if [[ -f "${ENV_FILE}" ]]; then
  log_info "loading env from ${ENV_FILE}"
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

# shellcheck source=lib/students_csv.sh
source "${SCRIPT_DIR}/lib/students_csv.sh"
# shellcheck source=lib/litellm_admin.sh
source "${SCRIPT_DIR}/lib/litellm_admin.sh"

# Apply --csv override before requiring env so STUDENTS_CSV_PATH is satisfied.
if [[ -n "${CSV_OVERRIDE}" ]]; then
  STUDENTS_CSV_PATH="${CSV_OVERRIDE}"
fi

require_env \
  LITELLM_MASTER_KEY DOMAIN \
  COHORT_NAME COHORT_SIZE COHORT_MAX_BUDGET COHORT_SOFT_BUDGET \
  STUDENT_MAX_BUDGET STUDENT_SOFT_BUDGET \
  STUDENT_DAILY_BUDGET STUDENT_WEEKLY_BUDGET \
  STUDENT_RPM_LIMIT STUDENT_TPM_LIMIT \
  STUDENTS_CSV_PATH

if [[ ! -f "${STUDENTS_CSV_PATH}" ]]; then
  log_error "students.csv not found at: ${STUDENTS_CSV_PATH}"
  exit 1
fi

CSV_DIR="$(cd "$(dirname "${STUDENTS_CSV_PATH}")" && pwd)"
COHORT_KEYS_CSV="${CSV_DIR}/cohort-keys-${COHORT_NAME}.csv"

log_info "students.csv=${STUDENTS_CSV_PATH}"
log_info "cohort-keys.csv=${COHORT_KEYS_CSV}"

# Numeric equality that tolerates "200" vs "200.00" vs "200.0".
_amount_eq() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 == b + 0) }'
}

# 1. Validate students.csv up front; refuses to run on bad input.
students_csv_validate "${STUDENTS_CSV_PATH}"

# 2. Init LiteLLM admin client.
litellm_admin_init

# 3. Live-mode readiness check.
if ! is_dry_run; then
  if ! litellm_request GET /health/readiness; then
    log_error "litellm /health/readiness not reachable at ${LITELLM_ADMIN_URL}"
    exit 1
  fi
  log_info "litellm admin API reachable"
fi

# 4. Reconcile cohort team.
TEAM_ID=""
if litellm_team_get "${COHORT_NAME}"; then
  TEAM_ID="$(printf '%s' "${LITELLM_LAST_BODY}" | jq -r '.team_id // empty')"
  CURR_MAX="$(printf '%s' "${LITELLM_LAST_BODY}" | jq -r '(.max_budget // 0) | tonumber')"
  CURR_SOFT="$(printf '%s' "${LITELLM_LAST_BODY}" | jq -r '(.soft_budget // 0) | tonumber')"
  if [[ -z "${TEAM_ID}" ]]; then
    log_error "team found but missing team_id: ${LITELLM_LAST_BODY}"
    exit 1
  fi
  log_info "team exists id=${TEAM_ID} max=${CURR_MAX} soft=${CURR_SOFT}"
  if ! _amount_eq "${CURR_MAX}" "${COHORT_MAX_BUDGET}" ||
    ! _amount_eq "${CURR_SOFT}" "${COHORT_SOFT_BUDGET}"; then
    log_info "updating team: max ${CURR_MAX}->${COHORT_MAX_BUDGET}, soft ${CURR_SOFT}->${COHORT_SOFT_BUDGET}"
    litellm_team_update "${TEAM_ID}" "${COHORT_MAX_BUDGET}" "${COHORT_SOFT_BUDGET}" ||
      {
        log_error "team update failed"
        exit 1
      }
  fi
else
  log_info "team '${COHORT_NAME}' not found, creating"
  litellm_team_create "${COHORT_NAME}" "${COHORT_MAX_BUDGET}" "${COHORT_SOFT_BUDGET}" ||
    {
      log_error "team create failed"
      exit 1
    }
  TEAM_ID="$(printf '%s' "${LITELLM_LAST_BODY}" | jq -r '.team_id // empty')"
  if [[ -z "${TEAM_ID}" ]]; then
    log_error "team created but response missing team_id: ${LITELLM_LAST_BODY}"
    exit 1
  fi
  log_info "team created id=${TEAM_ID}"
fi

# 5. Load existing cohort-keys.csv (if any) so we can preserve plaintext.
EXISTING_SLUGS=()
EXISTING_KEYS=()
if [[ -f "${COHORT_KEYS_CSV}" ]]; then
  log_info "loading existing cohort-keys.csv: ${COHORT_KEYS_CSV}"
  ec_first=1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ ${ec_first} -eq 1 ]]; then
      ec_first=0
      continue
    fi
    if [[ -z "$(printf '%s' "${line}" | tr -d '[:space:]')" ]]; then continue; fi
    IFS=',' read -ra ec_parts <<<"${line},__EOL__"
    unset "ec_parts[$((${#ec_parts[@]} - 1))]"
    EXISTING_SLUGS+=("${ec_parts[0]:-}")
    EXISTING_KEYS+=("${ec_parts[4]:-}")
  done <"${COHORT_KEYS_CSV}"
  log_info "loaded ${#EXISTING_SLUGS[@]} existing key rows"
fi

_existing_key_for_slug() {
  local slug="$1" i
  for ((i = 0; i < ${#EXISTING_SLUGS[@]}; i++)); do
    if [[ "${EXISTING_SLUGS[$i]}" == "${slug}" ]]; then
      printf '%s' "${EXISTING_KEYS[$i]}"
      return 0
    fi
  done
  return 1
}

# 6. Iterate and provision. Globals accumulate result rows + counters.
RESULT_SLUGS=()
RESULT_NAMES=()
RESULT_EMAILS=()
RESULT_PARENT_EMAILS=()
RESULT_KEYS=()
RESULT_ALIASES=()
PROVISION_FAILURES=0
PROVISIONED_NEW=0
PROVISIONED_UPDATED=0
PROVISIONED_KEPT=0

provision_one() {
  local name="$1" email="$2" slug="$3" parent_email="$4"
  local max_b="$5" daily_b="$6" weekly_b="$7" rpm="$8" tpm="$9"
  local key_alias="${COHORT_NAME}-${slug}"

  local metadata
  metadata="$(jq -nc \
    --arg cohort "${COHORT_NAME}" \
    --arg slug "${slug}" \
    --arg name "${name}" \
    --arg parent_email "${parent_email}" \
    --arg daily "${daily_b}" \
    --arg weekly "${weekly_b}" \
    '{cohort:$cohort,slug:$slug,name:$name,parent_email:$parent_email,
      daily_budget:$daily,weekly_budget:$weekly}')"

  if litellm_key_get "${TEAM_ID}" "${key_alias}"; then
    local token curr_max curr_soft curr_rpm curr_tpm
    token="$(printf '%s' "${LITELLM_LAST_BODY}" | jq -r '.token // .key_id // empty')"
    if [[ -z "${token}" ]]; then
      log_error "row slug=${slug}: existing key has no token in response"
      return 1
    fi
    curr_max="$(printf '%s' "${LITELLM_LAST_BODY}" | jq -r '(.max_budget // 0) | tonumber')"
    curr_soft="$(printf '%s' "${LITELLM_LAST_BODY}" | jq -r '(.soft_budget // 0) | tonumber')"
    curr_rpm="$(printf '%s' "${LITELLM_LAST_BODY}" | jq -r '(.rpm_limit // 0) | tonumber')"
    curr_tpm="$(printf '%s' "${LITELLM_LAST_BODY}" | jq -r '(.tpm_limit // 0) | tonumber')"

    if ! _amount_eq "${curr_max}" "${max_b}" ||
      ! _amount_eq "${curr_soft}" "${STUDENT_SOFT_BUDGET}" ||
      ! _amount_eq "${curr_rpm}" "${rpm}" ||
      ! _amount_eq "${curr_tpm}" "${tpm}"; then
      log_info "row slug=${slug}: updating key budgets/limits"
      if ! litellm_key_update "${token}" "${max_b}" "${STUDENT_SOFT_BUDGET}" "${rpm}" "${tpm}" "${metadata}"; then
        log_error "row slug=${slug}: key update failed"
        return 1
      fi
      PROVISIONED_UPDATED=$((PROVISIONED_UPDATED + 1))
    else
      log_info "row slug=${slug}: existing key in sync"
      PROVISIONED_KEPT=$((PROVISIONED_KEPT + 1))
    fi

    local plaintext
    if plaintext="$(_existing_key_for_slug "${slug}")"; then
      :
    else
      plaintext=""
    fi
    if [[ -z "${plaintext}" ]]; then
      log_warn "row slug=${slug}: no recorded plaintext; row omitted from cohort-keys.csv (re-issue the key if needed)"
      return 0
    fi
    _record_row "${slug}" "${name}" "${email}" "${parent_email}" "${plaintext}" "${key_alias}"
    return 0
  fi

  log_info "row slug=${slug}: creating new key"
  if ! litellm_key_create "${TEAM_ID}" "${key_alias}" "${metadata}" \
    "${max_b}" "${STUDENT_SOFT_BUDGET}" "${rpm}" "${tpm}"; then
    log_error "row slug=${slug}: key create failed"
    return 1
  fi
  local plaintext
  plaintext="$(printf '%s' "${LITELLM_LAST_BODY}" | jq -r '.key // empty')"
  if [[ -z "${plaintext}" ]]; then
    log_error "row slug=${slug}: key create returned no plaintext"
    return 1
  fi
  PROVISIONED_NEW=$((PROVISIONED_NEW + 1))
  _record_row "${slug}" "${name}" "${email}" "${parent_email}" "${plaintext}" "${key_alias}"
  return 0
}

_record_row() {
  RESULT_SLUGS+=("$1")
  RESULT_NAMES+=("$2")
  RESULT_EMAILS+=("$3")
  RESULT_PARENT_EMAILS+=("$4")
  RESULT_KEYS+=("$5")
  RESULT_ALIASES+=("$6")
}

provision_callback() {
  if ! provision_one "$@"; then
    PROVISION_FAILURES=$((PROVISION_FAILURES + 1))
  fi
}

students_csv_iter "${STUDENTS_CSV_PATH}" provision_callback

# 7. Write cohort-keys.csv (live mode only — dry-run skips).
if is_dry_run; then
  log_info "dry-run: would write ${#RESULT_SLUGS[@]} rows to ${COHORT_KEYS_CSV} (skipped)"
else
  TMP_CSV="${COHORT_KEYS_CSV}.tmp"
  {
    printf 'slug,name,email,parent_email,key,key_alias\n'
    for ((i = 0; i < ${#RESULT_SLUGS[@]}; i++)); do
      printf '%s,%s,%s,%s,%s,%s\n' \
        "${RESULT_SLUGS[$i]}" \
        "${RESULT_NAMES[$i]}" \
        "${RESULT_EMAILS[$i]}" \
        "${RESULT_PARENT_EMAILS[$i]}" \
        "${RESULT_KEYS[$i]}" \
        "${RESULT_ALIASES[$i]}"
    done
  } >"${TMP_CSV}"
  mv "${TMP_CSV}" "${COHORT_KEYS_CSV}"
  chmod 600 "${COHORT_KEYS_CSV}"
  log_info "wrote ${#RESULT_SLUGS[@]} rows to ${COHORT_KEYS_CSV} (mode 0600)"
fi

log_info "summary new=${PROVISIONED_NEW} updated=${PROVISIONED_UPDATED} kept=${PROVISIONED_KEPT} failed=${PROVISION_FAILURES} cohort=${COHORT_NAME} team_id=${TEAM_ID}"

if [[ "${PROVISION_FAILURES}" -gt 0 ]]; then
  log_warn "provision-cohort completed with ${PROVISION_FAILURES} row failure(s) — re-run to retry"
  exit 2
fi
exit 0
