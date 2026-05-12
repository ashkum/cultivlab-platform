#!/usr/bin/env bash
# scripts/push-env.sh — push local .env to VM and restart affected services.
#
# Run this any time you change .env locally (e.g. new COHORT_NAME, rotated key).
# Services restarted: founder-console (always), litellm (if --all flag passed).
#
# Usage:
#   bash scripts/push-env.sh           # push .env + restart founder-console
#   bash scripts/push-env.sh --all     # also restart litellm (use after key rotation)
#   bash scripts/push-env.sh --dry-run # print what would happen, no changes
#
# Exit codes: 0 = success, 1 = error

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

log() {
  local level="$1" msg="$2"
  printf '{"level":"%s","msg":"%s","ts":"%s","script":"%s"}\n' \
    "$level" \
    "$(printf '%s' "$msg" | sed 's/"/\\"/g')" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$SCRIPT_NAME"
}

# ── Parse flags ─────────────────────────────────────────────────────────────
DRY_RUN="false"
RESTART_ALL="false"

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN="true" ;;
    --all) RESTART_ALL="true" ;;
    --help | -h)
      cat <<EOF
Usage: $SCRIPT_NAME [--dry-run] [--all]

Push local .env to VM and restart affected services.

Flags:
  --dry-run   Print what would happen; make no changes.
  --all       Also restart litellm (use after rotating provider keys).
  --help      Show this message.
EOF
      exit 0
      ;;
    *)
      log error "unknown argument: $arg"
      exit 1
      ;;
  esac
done

# ── Load .env ────────────────────────────────────────────────────────────────
if [[ ! -f "${ENV_FILE}" ]]; then
  log error ".env not found at ${ENV_FILE}"
  exit 1
fi

set -a
# shellcheck disable=SC1090
. "${ENV_FILE}"
set +a

# ── Validate required vars ───────────────────────────────────────────────────
for var in VM_NAME GCP_ZONE GCP_PROJECT_ID COHORT_NAME; do
  if [[ -z "${!var:-}" ]]; then
    log error "missing required env var: ${var}"
    exit 1
  fi
done

log info "pushing .env to VM (COHORT_NAME=${COHORT_NAME})"
log info "VM=${VM_NAME} zone=${GCP_ZONE} project=${GCP_PROJECT_ID}"

if [[ "${DRY_RUN}" == "true" ]]; then
  log info "dry-run: would scp .env → ${VM_NAME}:/tmp/.env"
  log info "dry-run: would mv /tmp/.env /opt/cultivlab/repo/.env on VM"
  log info "dry-run: would restart founder-console"
  [[ "${RESTART_ALL}" == "true" ]] && log info "dry-run: would also restart litellm"
  log info "dry-run complete — no changes made"
  exit 0
fi

# ── SCP .env to VM ──────────────────────────────────────────────────────────
log info "step 1/3: copying .env to VM"
gcloud compute scp "${ENV_FILE}" "${VM_NAME}:/tmp/.env" \
  --tunnel-through-iap \
  --zone "${GCP_ZONE}" \
  --project "${GCP_PROJECT_ID}" \
  </dev/null

# ── Apply on VM ──────────────────────────────────────────────────────────────
log info "step 2/3: applying .env on VM"

REMOTE_CMD="sudo mv /tmp/.env /opt/cultivlab/repo/.env && sudo chmod 600 /opt/cultivlab/repo/.env"
gcloud compute ssh "${VM_NAME}" \
  --tunnel-through-iap \
  --zone "${GCP_ZONE}" \
  --project "${GCP_PROJECT_ID}" \
  --command "${REMOTE_CMD}" \
  </dev/null

# ── Restart services ─────────────────────────────────────────────────────────
log info "step 3/3: restarting services"

SERVICES="founder-console"
[[ "${RESTART_ALL}" == "true" ]] && SERVICES="litellm founder-console"

RESTART_CMD="cd /opt/cultivlab/infra && sudo docker compose --env-file /opt/cultivlab/.env up -d --force-recreate ${SERVICES}"
gcloud compute ssh "${VM_NAME}" \
  --tunnel-through-iap \
  --zone "${GCP_ZONE}" \
  --project "${GCP_PROJECT_ID}" \
  --command "${RESTART_CMD}" \
  </dev/null

log info "done — founder-console is now using COHORT_NAME=${COHORT_NAME}"
log info "verify: https://founder.${DOMAIN}"
