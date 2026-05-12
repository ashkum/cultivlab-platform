#!/usr/bin/env bash
# scripts/provision-all.sh — full cohort provisioning in one command.
#
# Runs all four provisioning steps in order:
#   1. provision-cohort.sh  — LiteLLM team + virtual keys
#   2. provision-students.sh — Open WebUI accounts
#   3. provision-sites.sh   — Firebase slot assignment
#   4. generate-cards.sh    — onboarding cards
#   5. push-env.sh          — update VM with new COHORT_NAME
#
# Usage:
#   bash scripts/provision-all.sh --dir ~/Desktop/cultivlab-cohort-1-2026
#   bash scripts/provision-all.sh --dir ~/Desktop/cultivlab-cohort-1-2026 --dry-run
#
# Required .env vars:
#   COHORT_NAME, COHORT_SIZE, COHORT_START, COHORT_END
#   DOMAIN, VM_NAME, GCP_ZONE, GCP_PROJECT_ID
#   LITELLM_MASTER_KEY, OPENWEBUI_ADMIN_EMAIL, OPENWEBUI_ADMIN_PASSWORD
#
# Exit codes: 0 = success, 1 = error

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() {
  local level="$1" msg="$2"
  printf '{"level":"%s","msg":"%s","ts":"%s","script":"%s"}\n' \
    "$level" \
    "$(printf '%s' "$msg" | sed 's/"/\\"/g')" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$SCRIPT_NAME"
}

# ── Parse flags ──────────────────────────────────────────────────────────────
DRY_RUN="false"
COHORT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --dir)
      COHORT_DIR="${2:-}"
      if [[ -z "${COHORT_DIR}" ]]; then
        log error "--dir requires a path argument"
        exit 1
      fi
      shift 2
      ;;
    --help | -h)
      cat <<EOF
Usage: $SCRIPT_NAME --dir PATH [--dry-run]

Full cohort provisioning: keys → OW accounts → sites → cards → push to VM.

Required:
  --dir PATH   Path to cohort directory containing students.csv

Optional:
  --dry-run    Validate + simulate all steps without making changes.
  --help       Show this message.

Example:
  bash scripts/provision-all.sh --dir ~/Desktop/cultivlab-cohort-2-2026
EOF
      exit 0
      ;;
    *)
      log error "unknown argument: $1"
      exit 1
      ;;
  esac
done

if [[ -z "${COHORT_DIR}" ]]; then
  log error "--dir is required. Example: --dir ~/Desktop/cultivlab-cohort-1-2026"
  exit 1
fi

# Expand ~ in path
COHORT_DIR="${COHORT_DIR/#\~/$HOME}"

if [[ ! -d "${COHORT_DIR}" ]]; then
  log error "cohort directory not found: ${COHORT_DIR}"
  exit 1
fi

# ── Load .env ────────────────────────────────────────────────────────────────
ENV_FILE="${REPO_ROOT}/.env"
if [[ ! -f "${ENV_FILE}" ]]; then
  log error ".env not found at ${ENV_FILE}"
  exit 1
fi
set -a
# shellcheck disable=SC1090
. "${ENV_FILE}"
set +a

# ── Validate required vars ───────────────────────────────────────────────────
for var in COHORT_NAME COHORT_SIZE; do
  if [[ -z "${!var:-}" ]]; then
    log error "missing required env var: ${var}"
    exit 1
  fi
done

# ── Derive all CSV paths ─────────────────────────────────────────────────────
STUDENTS_CSV="${COHORT_DIR}/students.csv"
COHORT_KEYS_CSV="${COHORT_DIR}/cohort-keys-${COHORT_NAME}.csv"
COHORT_STUDENTS_CSV="${COHORT_DIR}/cohort-students-${COHORT_NAME}.csv"
COHORT_SLOTS_CSV="${COHORT_DIR}/cohort-slots-${COHORT_NAME}.csv"
CARDS_DIR="${COHORT_DIR}/onboarding-cards-${COHORT_NAME}"

if [[ ! -f "${STUDENTS_CSV}" ]]; then
  log error "students.csv not found at: ${STUDENTS_CSV}"
  exit 1
fi

log info "=== CultivLab cohort provisioning ==="
log info "cohort:      ${COHORT_NAME}"
log info "cohort dir:  ${COHORT_DIR}"
log info "students:    ${COHORT_SIZE}"
log info "dry-run:     ${DRY_RUN}"

DRY_FLAG=""
[[ "${DRY_RUN}" == "true" ]] && DRY_FLAG="--dry-run"

# ── Step 1: provision-cohort.sh ──────────────────────────────────────────────
log info "--- step 1/5: provision-cohort.sh ---"
STUDENTS_CSV="${STUDENTS_CSV}" \
  bash "${SCRIPT_DIR}/provision-cohort.sh" ${DRY_FLAG}

# ── Step 2: provision-students.sh ────────────────────────────────────────────
log info "--- step 2/5: provision-students.sh ---"
COHORT_STUDENTS_CSV_PATH="${COHORT_STUDENTS_CSV}" \
  bash "${SCRIPT_DIR}/provision-students.sh" ${DRY_FLAG} \
  --csv "${COHORT_KEYS_CSV}"

# ── Step 3: provision-sites.sh ───────────────────────────────────────────────
log info "--- step 3/5: provision-sites.sh ---"
COHORT_STUDENTS_CSV_PATH="${COHORT_STUDENTS_CSV}" \
  COHORT_SLOTS_CSV_PATH="${COHORT_SLOTS_CSV}" \
  bash "${SCRIPT_DIR}/provision-sites.sh" ${DRY_FLAG}

# provision-sites.sh writes cohort-slots CSV to repo root — copy to cohort dir
# so generate-cards.sh finds it at the expected path.
REPO_SLOTS_CSV="${REPO_ROOT}/cohort-slots-${COHORT_NAME}.csv"
if [[ -f "${REPO_SLOTS_CSV}" ]] && [[ "${REPO_SLOTS_CSV}" != "${COHORT_SLOTS_CSV}" ]]; then
  cp "${REPO_SLOTS_CSV}" "${COHORT_SLOTS_CSV}"
fi

# ── Step 4: generate-cards.sh ────────────────────────────────────────────────
log info "--- step 4/5: generate-cards.sh ---"
COHORT_STUDENTS_CSV_PATH="${COHORT_STUDENTS_CSV}" \
  COHORT_SLOTS_CSV_PATH="${COHORT_SLOTS_CSV}" \
  ONBOARDING_CARDS_DIR="${CARDS_DIR}" \
  bash "${SCRIPT_DIR}/generate-cards.sh" ${DRY_FLAG}

# ── Step 5: push-env.sh ──────────────────────────────────────────────────────
if [[ "${DRY_RUN}" == "true" ]]; then
  log info "--- step 5/5: push-env.sh (dry-run: skipped) ---"
  log info "dry-run complete — no changes made"
else
  log info "--- step 5/5: push-env.sh ---"
  bash "${SCRIPT_DIR}/push-env.sh"
fi

log info "=== provisioning complete ==="
log info "onboarding cards: ${CARDS_DIR}/"
log info "verify Founder Console: https://founder.${DOMAIN:-cultivlab.com}"
