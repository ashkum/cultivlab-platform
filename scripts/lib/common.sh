#!/usr/bin/env bash
# scripts/lib/common.sh
# Shared bash library for all CultivLab scripts.
#
# Usage in a calling script:
#   set -euo pipefail
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=lib/common.sh
#   source "${SCRIPT_DIR}/lib/common.sh"
#
#   parse_common_args "$@"
#   require_env GCP_PROJECT_ID DOMAIN
#   run_or_dry gcloud projects describe "${GCP_PROJECT_ID}"
#
# Portable: works under bash 3.2 (default macOS) and bash 5+ (Ubuntu 24.04).

# Guard against double-sourcing.
if [[ -n "${CULTIVLAB_COMMON_LOADED:-}" ]]; then
  return 0
fi
CULTIVLAB_COMMON_LOADED=1

# Dry-run state. Scripts toggle this by calling parse_common_args "$@" or by
# setting CULTIVLAB_DRY_RUN=1 directly.
: "${CULTIVLAB_DRY_RUN:=0}"

# ----------------------------------------------------------------------------
# Internal: emit one structured JSON log line.
# Args: $1 = level (info|warn|error), $2 = message
# Writes to stdout for info/warn, stderr for error.
# ----------------------------------------------------------------------------
_log_emit() {
  local level="$1"
  local msg="$2"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Escape backslashes first, then double quotes, for JSON safety.
  local script_name="${0##*/}"
  msg="${msg//\\/\\\\}"
  msg="${msg//\"/\\\"}"
  script_name="${script_name//\\/\\\\}"
  script_name="${script_name//\"/\\\"}"

  local line
  printf -v line '{"level":"%s","msg":"%s","ts":"%s","script":"%s"}\n' \
    "${level}" "${msg}" "${ts}" "${script_name}"

  if [[ "${level}" == "error" ]]; then
    printf '%s' "${line}" >&2
  else
    printf '%s' "${line}"
  fi
}

log_info() { _log_emit "info" "$*"; }
log_warn() { _log_emit "warn" "$*"; }
log_error() { _log_emit "error" "$*"; }

# ----------------------------------------------------------------------------
# require_env VAR1 VAR2 ...
# Exits 1 with an error log line for any var that is unset or empty.
# ----------------------------------------------------------------------------
require_env() {
  local missing=()
  local var
  for var in "$@"; do
    # Indirect expansion; treat unset and empty the same.
    if [[ -z "${!var:-}" ]]; then
      missing+=("${var}")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "missing required env vars: ${missing[*]}"
    exit 1
  fi
}

# ----------------------------------------------------------------------------
# is_dry_run
# Returns 0 (true) if CULTIVLAB_DRY_RUN=1, 1 (false) otherwise.
# ----------------------------------------------------------------------------
is_dry_run() {
  [[ "${CULTIVLAB_DRY_RUN}" == "1" ]]
}

# ----------------------------------------------------------------------------
# run_or_dry CMD [ARGS...]
# In dry-run: log the command and return 0.
# Otherwise: execute the command, returning its exit status.
#
# Caveat: this runs argv directly — pipes, redirects, and shell expansions
# inside a single argument are not interpreted. For shell-syntax commands,
# either wrap with: run_or_dry bash -c 'cmd | other'
# or split into discrete steps.
# ----------------------------------------------------------------------------
run_or_dry() {
  if [[ $# -eq 0 ]]; then
    log_error "run_or_dry called with no command"
    return 1
  fi
  if is_dry_run; then
    log_info "would run: $*"
    return 0
  fi
  "$@"
}

# ----------------------------------------------------------------------------
# parse_common_args "$@"
# Scans argv for --dry-run / --help. Sets CULTIVLAB_DRY_RUN=1 when --dry-run
# is present. Sets CULTIVLAB_HELP=1 when --help / -h is present.
# Does NOT shift the caller's argv — this is a non-destructive scan.
# Unknown args are ignored here; the caller may parse them itself.
# ----------------------------------------------------------------------------
parse_common_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --dry-run)
        CULTIVLAB_DRY_RUN=1
        ;;
      --help | -h)
        # shellcheck disable=SC2034 # used by callers that source this file
        CULTIVLAB_HELP=1
        ;;
    esac
  done
}
