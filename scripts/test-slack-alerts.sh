#!/usr/bin/env bash
# scripts/test-slack-alerts.sh — post one synthetic message to each of the five
# Slack incoming webhooks defined in .env. Run-once smoke test for the operator.
#
# Tests the WEBHOOKS THEMSELVES, not LiteLLM's wiring to them. SLACK_WEBHOOK_SAFETY
# is not yet routed via LiteLLM's alert_types (Sprint 3 moderation flow uses it),
# so this script only confirms the webhook URL is live; LiteLLM-to-Slack routing
# for the other four channels is verified end-to-end in Sprint 5 spend reports.
#
# Exit codes:
#   0  all five webhooks returned 200
#   1  one or more webhooks failed (non-200 or unreachable)
#
# Usage: ./test-slack-alerts.sh [--dry-run] [--help]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<USAGE
$(basename "$0") [--dry-run] [--help]

Posts a Sprint 2 smoke-test message to each of the five SLACK_WEBHOOK_* URLs
read from .env. Tests the webhooks directly (not LiteLLM's wiring to them).

  --dry-run    log intended POSTs, send nothing
  --help, -h   show this and exit
USAGE
}

parse_common_args "$@"
if [[ "${CULTIVLAB_HELP:-0}" == "1" ]]; then
  usage
  exit 0
fi

ENV_FILE="${REPO_ROOT}/.env"
if [[ -f "${ENV_FILE}" ]]; then
  log_info "loading env from ${ENV_FILE}"
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

require_env \
  SLACK_WEBHOOK_BUDGET \
  SLACK_WEBHOOK_REPORTS \
  SLACK_WEBHOOK_EXCEPTIONS \
  SLACK_WEBHOOK_SAFETY \
  SLACK_WEBHOOK_PLATFORM

if ! command -v curl >/dev/null 2>&1; then
  log_error "curl is required but not found on PATH"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  log_error "jq is required but not found on PATH (install: brew install jq)"
  exit 1
fi

# (channel-label, webhook-url, body-suffix) tuples as parallel arrays.
LABELS=(budget reports exceptions safety platform)
URLS=(
  "${SLACK_WEBHOOK_BUDGET}"
  "${SLACK_WEBHOOK_REPORTS}"
  "${SLACK_WEBHOOK_EXCEPTIONS}"
  "${SLACK_WEBHOOK_SAFETY}"
  "${SLACK_WEBHOOK_PLATFORM}"
)
SUFFIXES=(
  "(budget alerts: 80% / 100% thresholds, cohort cap)"
  "(daily / weekly spend reports)"
  "(provider errors, slow LLM responses, DB issues)"
  "(Sprint 3 moderation alerts — webhook only, no LiteLLM wiring yet)"
  "(VM disk, Postgres, SSL cert expiry)"
)

failures=0

for ((i = 0; i < ${#LABELS[@]}; i++)); do
  label="${LABELS[$i]}"
  url="${URLS[$i]}"
  suffix="${SUFFIXES[$i]}"

  payload="$(jq -nc --arg text "[CultivLab Sprint 2 smoke test] #cultivlab-${label} ${suffix}" \
    '{text: $text}')"

  if is_dry_run; then
    log_info "would POST to #cultivlab-${label} url=${url%%/services/*}/services/... payload=${payload}"
    continue
  fi

  http_code="$(curl -sS -o /dev/null -w '%{http_code}' \
    -X POST \
    -H 'Content-Type: application/json' \
    --data-raw "${payload}" \
    "${url}" || echo "000")"

  if [[ "${http_code}" == "200" ]]; then
    log_info "channel=${label} status=${http_code}"
  else
    log_error "channel=${label} status=${http_code} (webhook may be revoked or misconfigured)"
    failures=$((failures + 1))
  fi

  sleep 1
done

if is_dry_run; then
  log_info "dry-run: no messages sent"
  exit 0
fi

if [[ "${failures}" -gt 0 ]]; then
  log_error "${failures} of ${#LABELS[@]} webhooks failed; regenerate failing webhook(s) in Slack admin"
  exit 1
fi
log_info "all ${#LABELS[@]} Slack webhooks responded with 200"
exit 0
