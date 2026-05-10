#!/usr/bin/env bash
# scripts/lib/openwebui_admin.sh
#
# Open WebUI admin API helpers. Sourced by provision-students.sh.
#
# Functions in this file follow the same pattern as scripts/lib/litellm_admin.sh:
#   - *_init() validates env, derives URL, checks dependencies.
#   - <action>_request() is the low-level wrapper (dry-run aware).
#   - High-level helpers (signin, user_get, user_add) return parsed JSON
#     fields via globals OPENWEBUI_LAST_BODY / OPENWEBUI_LAST_STATUS.
#
# Required env when sourced:
#   OPENWEBUI_ADMIN_URL      (e.g. https://chat.${DOMAIN}) OR
#   DOMAIN                   (we derive https://chat.${DOMAIN})
#   OPENWEBUI_ADMIN_EMAIL    admin account email
#   OPENWEBUI_ADMIN_PASSWORD admin account password
#
# Globals set after each request:
#   OPENWEBUI_LAST_BODY      response body (string)
#   OPENWEBUI_LAST_STATUS    HTTP status code (string)
#
# Globals set after signin:
#   OPENWEBUI_JWT            bearer token used by subsequent requests

# ---------------------------------------------------------------------------
# Init
# ---------------------------------------------------------------------------

openwebui_admin_init() {
  require_env OPENWEBUI_ADMIN_EMAIL
  require_env OPENWEBUI_ADMIN_PASSWORD

  if [[ -z "${OPENWEBUI_ADMIN_URL:-}" ]]; then
    require_env DOMAIN
    OPENWEBUI_ADMIN_URL="https://chat.${DOMAIN}"
  fi
  OPENWEBUI_ADMIN_URL="${OPENWEBUI_ADMIN_URL%/}"

  if ! command -v curl >/dev/null 2>&1; then
    log_error "curl is required but not found on PATH"
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    log_error "jq is required but not found on PATH (install: brew install jq)"
    exit 1
  fi

  export OPENWEBUI_ADMIN_URL
}

# ---------------------------------------------------------------------------
# Low-level request
# ---------------------------------------------------------------------------

# openwebui_request <METHOD> <PATH> [<JSON_BODY>] [<EXTRA_HEADER>]
# Dry-run: logs intended call, sets OPENWEBUI_LAST_BODY="" + STATUS=200, returns 0.
# Live:    populates OPENWEBUI_LAST_BODY + OPENWEBUI_LAST_STATUS; returns 0 on
#          2xx, 1 with structured error log on non-2xx.
openwebui_request() {
  if [[ $# -lt 2 ]]; then
    log_error "openwebui_request: usage <METHOD> <PATH> [<JSON_BODY>] [<EXTRA_HEADER>]"
    return 1
  fi
  local method="$1" path="$2" body="${3:-}" extra="${4:-}"
  if [[ "${path:0:1}" != "/" ]]; then
    log_error "openwebui_request: path must start with '/' (got: ${path})"
    return 1
  fi
  local url="${OPENWEBUI_ADMIN_URL}${path}"

  if is_dry_run; then
    if [[ -n "${body}" ]]; then
      log_info "would call ${method} ${url} body=${body}"
    else
      log_info "would call ${method} ${url}"
    fi
    OPENWEBUI_LAST_BODY=""
    # shellcheck disable=SC2034
    OPENWEBUI_LAST_STATUS="200"
    return 0
  fi

  local tmp http_code curl_args=()
  tmp="$(mktemp)"
  curl_args=(-sS -o "${tmp}" -w '%{http_code}' -X "${method}"
    -H "Content-Type: application/json")
  if [[ -n "${extra}" ]]; then
    curl_args+=(-H "${extra}")
  fi
  if [[ -n "${body}" ]]; then
    curl_args+=(-d "${body}")
  fi
  curl_args+=("${url}")

  http_code="$(curl "${curl_args[@]}")"
  OPENWEBUI_LAST_BODY="$(cat "${tmp}")"
  # shellcheck disable=SC2034 # exposed to callers that source this file
  OPENWEBUI_LAST_STATUS="${http_code}"
  rm -f "${tmp}"

  if [[ "${http_code:0:1}" != "2" ]]; then
    log_error "openwebui_request: ${method} ${path} returned HTTP ${http_code} body=${OPENWEBUI_LAST_BODY}"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Authenticated request (after signin)
# ---------------------------------------------------------------------------

# openwebui_auth_request <METHOD> <PATH> [<JSON_BODY>]
# Like openwebui_request, but adds Authorization: Bearer ${OPENWEBUI_JWT}.
openwebui_auth_request() {
  if [[ -z "${OPENWEBUI_JWT:-}" ]]; then
    log_error "openwebui_auth_request: OPENWEBUI_JWT not set; call openwebui_signin first"
    return 1
  fi
  openwebui_request "$1" "$2" "${3:-}" "Authorization: Bearer ${OPENWEBUI_JWT}"
}

# ---------------------------------------------------------------------------
# High-level helpers
# ---------------------------------------------------------------------------

# openwebui_signin
# Signs in as admin, populates OPENWEBUI_JWT.
openwebui_signin() {
  local body
  body="$(jq -n \
    --arg email "${OPENWEBUI_ADMIN_EMAIL}" \
    --arg password "${OPENWEBUI_ADMIN_PASSWORD}" \
    '{email: $email, password: $password}')"

  if is_dry_run; then
    log_info "would sign in to ${OPENWEBUI_ADMIN_URL} as ${OPENWEBUI_ADMIN_EMAIL}"
    OPENWEBUI_JWT="dry-run-stub-jwt"
    return 0
  fi

  if ! openwebui_request POST /api/v1/auths/signin "${body}"; then
    log_error "openwebui_signin: failed to sign in as ${OPENWEBUI_ADMIN_EMAIL}"
    return 1
  fi

  OPENWEBUI_JWT="$(echo "${OPENWEBUI_LAST_BODY}" | jq -r '.token // empty')"
  if [[ -z "${OPENWEBUI_JWT}" ]]; then
    log_error "openwebui_signin: response did not contain token; body=${OPENWEBUI_LAST_BODY}"
    return 1
  fi
  log_info "signed in as ${OPENWEBUI_ADMIN_EMAIL}"
  return 0
}

# openwebui_user_get_by_email <EMAIL>
# Looks up a user by email; sets OPENWEBUI_LAST_BODY to the user JSON or empty.
# Returns 0 if found, 1 if not found, 2 on error.
openwebui_user_get_by_email() {
  local email="$1"
  if is_dry_run; then
    log_info "would look up user by email=${email}"
    OPENWEBUI_LAST_BODY=""
    return 1
  fi

  # Open WebUI v0.5.20 has no public /users?email= filter; we list all and grep.
  # OK for cohorts < 100. Replace if a future version exposes a search endpoint.
  if ! openwebui_auth_request GET /api/v1/users/; then
    return 2
  fi
  local match
  match="$(echo "${OPENWEBUI_LAST_BODY}" |
    jq -c --arg email "$(echo "${email}" | tr '[:upper:]' '[:lower:]')" \
      '.[] | select((.email | ascii_downcase) == $email)')"
  if [[ -z "${match}" ]]; then
    OPENWEBUI_LAST_BODY=""
    return 1
  fi
  OPENWEBUI_LAST_BODY="${match}"
  return 0
}

# openwebui_user_add <EMAIL> <PASSWORD> <NAME> <ROLE>
# Creates a new user via admin /auths/add. Sets OPENWEBUI_LAST_BODY to response.
# Role must be one of: user, admin (Open WebUI roles).
openwebui_user_add() {
  if [[ $# -ne 4 ]]; then
    log_error "openwebui_user_add: usage <EMAIL> <PASSWORD> <NAME> <ROLE>"
    return 1
  fi
  local email="$1" password="$2" name="$3" role="$4"
  local body
  body="$(jq -n \
    --arg email "${email}" \
    --arg password "${password}" \
    --arg name "${name}" \
    --arg role "${role}" \
    '{email: $email, password: $password, name: $name, role: $role}')"

  if is_dry_run; then
    log_info "would create user email=${email} name=${name} role=${role}"
    OPENWEBUI_LAST_BODY=""
    return 0
  fi

  openwebui_auth_request POST /api/v1/auths/add "${body}"
}
