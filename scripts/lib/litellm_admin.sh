#!/usr/bin/env bash
# scripts/lib/litellm_admin.sh
# Thin wrapper around LiteLLM's admin API. All Sprint 2+ admin calls go through
# this — no inline curl in provisioning scripts. Requires curl + jq.
#
# Note on signatures: the brief listed
#   litellm_key_create <team_id> <key_alias> <metadata_json> <max_budget> <rpm> <tpm> <budget_duration>
# but ADR-009 requires soft_budget on every key. To keep this lib uncoupled
# from a specific env-var name, soft_budget is a positional arg here. Same for
# litellm_team_{create,update}.

if [[ -n "${CULTIVLAB_LITELLM_ADMIN_LOADED:-}" ]]; then
  return 0
fi
CULTIVLAB_LITELLM_ADMIN_LOADED=1

_LITELLM_ADMIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${CULTIVLAB_COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "${_LITELLM_ADMIN_DIR}/common.sh"
fi

# Last-response cache. Callers parse LITELLM_LAST_BODY after a successful call.
LITELLM_LAST_BODY=""
LITELLM_LAST_STATUS=""

# Resolve LITELLM_ADMIN_URL (defaults to https://api.${DOMAIN}); validate deps.
litellm_admin_init() {
  require_env LITELLM_MASTER_KEY
  if [[ -z "${LITELLM_ADMIN_URL:-}" ]]; then
    require_env DOMAIN
    LITELLM_ADMIN_URL="https://api.${DOMAIN}"
  fi
  LITELLM_ADMIN_URL="${LITELLM_ADMIN_URL%/}"

  if ! command -v curl >/dev/null 2>&1; then
    log_error "curl is required but not found on PATH"
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    log_error "jq is required but not found on PATH (install: brew install jq)"
    exit 1
  fi

  export LITELLM_ADMIN_URL
}

# litellm_request <METHOD> <PATH> [<JSON_BODY>]
# Dry-run: logs intended call, sets LITELLM_LAST_BODY="" + STATUS=200, returns 0.
# Live:    populates LITELLM_LAST_BODY + LITELLM_LAST_STATUS; returns 0 on 2xx,
#          1 with structured error log on non-2xx (includes response body).
litellm_request() {
  if [[ $# -lt 2 ]]; then
    log_error "litellm_request: usage <METHOD> <PATH> [<JSON_BODY>]"
    return 1
  fi
  local method="$1" path="$2" body="${3:-}"
  if [[ "${path:0:1}" != "/" ]]; then
    log_error "litellm_request: path must start with '/' (got: ${path})"
    return 1
  fi
  local url="${LITELLM_ADMIN_URL}${path}"

  if is_dry_run; then
    if [[ -n "${body}" ]]; then
      log_info "would call ${method} ${url} body=${body}"
    else
      log_info "would call ${method} ${url}"
    fi
    LITELLM_LAST_BODY=""
    LITELLM_LAST_STATUS="200"
    return 0
  fi

  local tmp http_code
  tmp="$(mktemp)"
  if [[ -n "${body}" ]]; then
    http_code="$(curl -sS -o "${tmp}" -w '%{http_code}' \
      -X "${method}" \
      -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
      -H "Content-Type: application/json" \
      --data-raw "${body}" \
      "${url}" || echo "000")"
  else
    http_code="$(curl -sS -o "${tmp}" -w '%{http_code}' \
      -X "${method}" \
      -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
      "${url}" || echo "000")"
  fi

  LITELLM_LAST_STATUS="${http_code}"
  if [[ -s "${tmp}" ]]; then
    LITELLM_LAST_BODY="$(cat "${tmp}")"
  else
    LITELLM_LAST_BODY=""
  fi
  rm -f "${tmp}"

  if [[ "${http_code}" =~ ^2 ]]; then
    return 0
  fi
  log_error "litellm ${method} ${path} HTTP=${http_code} body=${LITELLM_LAST_BODY}"
  return 1
}

# Filter LITELLM_LAST_BODY to a single object with field == value. Defensive
# against multiple LiteLLM response shapes (top-level array | .teams | .keys
# | .data). Sets LITELLM_LAST_BODY to the matched object on hit, returns 1
# on miss without overwriting the body.
_litellm_filter_one() {
  local field="$1" value="$2"
  if [[ -z "${LITELLM_LAST_BODY}" ]]; then
    return 1
  fi
  local match
  match="$(printf '%s' "${LITELLM_LAST_BODY}" | jq -c \
    --arg f "${field}" --arg v "${value}" '
      (if type == "array" then . else (.teams // .keys // .data // []) end)
      | map(select(.[$f] == $v))
      | first // empty
    ' 2>/dev/null || echo "")"
  if [[ -z "${match}" ]]; then
    return 1
  fi
  LITELLM_LAST_BODY="${match}"
  return 0
}

# litellm_team_get <team_alias> — sets LITELLM_LAST_BODY to team JSON or returns 1.
litellm_team_get() {
  local team_alias="$1"
  litellm_request GET /team/list || return 1
  _litellm_filter_one team_alias "${team_alias}"
}

# litellm_team_create <team_alias> <max_budget> <soft_budget>
# Dry-run: synthesizes team_id="dry-run-team-id" so callers trace the full path.
litellm_team_create() {
  local team_alias="$1" max_budget="$2" soft_budget="$3"
  local body
  body="$(jq -nc \
    --arg alias "${team_alias}" \
    --argjson max "${max_budget}" \
    --argjson soft "${soft_budget}" \
    '{team_alias: $alias, max_budget: $max, soft_budget: $soft}')"

  if is_dry_run; then
    log_info "would create team alias=${team_alias} max_budget=${max_budget} soft_budget=${soft_budget}"
    LITELLM_LAST_BODY="$(printf '%s' "${body}" | jq -c '. + {team_id: "dry-run-team-id"}')"
    LITELLM_LAST_STATUS="200"
    return 0
  fi
  litellm_request POST /team/new "${body}"
}

# litellm_team_update <team_id> <max_budget> <soft_budget>
litellm_team_update() {
  local team_id="$1" max_budget="$2" soft_budget="$3"
  local body
  body="$(jq -nc \
    --arg id "${team_id}" \
    --argjson max "${max_budget}" \
    --argjson soft "${soft_budget}" \
    '{team_id: $id, max_budget: $max, soft_budget: $soft}')"

  if is_dry_run; then
    log_info "would update team id=${team_id} max_budget=${max_budget} soft_budget=${soft_budget}"
    LITELLM_LAST_BODY="${body}"
    LITELLM_LAST_STATUS="200"
    return 0
  fi
  litellm_request POST /team/update "${body}"
}

# litellm_key_get <team_id> <key_alias> — sets LITELLM_LAST_BODY to key JSON or returns 1.
litellm_key_get() {
  local team_id="$1" key_alias="$2"
  litellm_request GET "/key/list?team_id=${team_id}&size=200&return_full_object=true" || return 1
  _litellm_filter_one key_alias "${key_alias}"
}

# litellm_key_create <team_id> <key_alias> <metadata_json> <max_budget> <soft_budget> <rpm> <tpm> [<budget_duration>]
# <metadata_json> must be a valid JSON object string.
# <budget_duration> empty/omitted = total cap (no reset).
# Dry-run: synthesizes a fake plaintext "sk-dry-run-<alias>" so the caller traces
# the happy path; cohort-keys.csv writer recognizes this prefix and elides it.
litellm_key_create() {
  local team_id="$1" key_alias="$2" metadata_json="$3"
  local max_budget="$4" soft_budget="$5" rpm="$6" tpm="$7"
  local budget_duration="${8:-}"

  local body_base
  body_base="$(jq -nc \
    --arg team "${team_id}" --arg alias "${key_alias}" \
    --argjson meta "${metadata_json}" \
    --argjson max "${max_budget}" --argjson soft "${soft_budget}" \
    --argjson rpm "${rpm}" --argjson tpm "${tpm}" \
    '{team_id: $team, key_alias: $alias, metadata: $meta,
      max_budget: $max, soft_budget: $soft,
      rpm_limit: $rpm, tpm_limit: $tpm}')"

  local body
  if [[ -n "${budget_duration}" ]]; then
    body="$(printf '%s' "${body_base}" | jq -c --arg dur "${budget_duration}" '. + {budget_duration: $dur}')"
  else
    body="${body_base}"
  fi

  if is_dry_run; then
    log_info "would create key team=${team_id} alias=${key_alias} max=${max_budget} rpm=${rpm} tpm=${tpm}"
    LITELLM_LAST_BODY="$(jq -nc \
      --arg alias "${key_alias}" --arg team "${team_id}" \
      --argjson max "${max_budget}" \
      '{key: ("sk-dry-run-" + $alias), token: ("dry-run-token-" + $alias),
        key_alias: $alias, team_id: $team, max_budget: $max}')"
    LITELLM_LAST_STATUS="200"
    return 0
  fi
  litellm_request POST /key/generate "${body}"
}

# litellm_key_update <key_token> <max_budget> <soft_budget> <rpm> <tpm> [<metadata_json>]
# <key_token> is the LiteLLM token (hashed key id) returned alongside the
# plaintext at creation. Used on re-runs to reconcile budgets/limits without
# regenerating the key.
litellm_key_update() {
  local key_token="$1" max_budget="$2" soft_budget="$3"
  local rpm="$4" tpm="$5" metadata_json="${6:-}"

  local body_base
  body_base="$(jq -nc \
    --arg key "${key_token}" \
    --argjson max "${max_budget}" --argjson soft "${soft_budget}" \
    --argjson rpm "${rpm}" --argjson tpm "${tpm}" \
    '{key: $key, max_budget: $max, soft_budget: $soft,
      rpm_limit: $rpm, tpm_limit: $tpm}')"

  local body
  if [[ -n "${metadata_json}" ]]; then
    body="$(printf '%s' "${body_base}" | jq -c --argjson meta "${metadata_json}" '. + {metadata: $meta}')"
  else
    body="${body_base}"
  fi

  if is_dry_run; then
    log_info "would update key token=${key_token} max=${max_budget} rpm=${rpm} tpm=${tpm}"
    LITELLM_LAST_BODY="${body}"
    LITELLM_LAST_STATUS="200"
    return 0
  fi
  litellm_request POST /key/update "${body}"
}
