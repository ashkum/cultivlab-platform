#!/usr/bin/env bash
#
# deploy-portal.sh — renders and deploys the student portal (index.html) to
# existing slot directories on the VM.
#
# Use this when:
#   - You are activating the upload feature on an already-provisioned cohort
#   - You want to re-deploy the portal after a template change
#
# For new cohorts, provision-sites.sh handles this automatically.
#
# Inputs:
#   - cohort-students-${COHORT_NAME}.csv  (slug + litellm_key)
#   - cohort-slots-${COHORT_NAME}.csv     (slug + slot mapping)
#   - templates/student-portal/index.html
#   - .env (DOMAIN, GCP_PROJECT_ID, GCP_ZONE, VM_NAME, COHORT_NAME)
#
# Exit codes:
#   0 — success
#   1 — input/validation error
#   2 — runtime error (gcloud failure)

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
log() {
  local level="$1"
  local msg="$2"
  printf '{"level":"%s","msg":"%s","ts":"%s","script":"%s"}\n' \
    "$level" \
    "$(printf '%s' "$msg" | sed 's/"/\\"/g')" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$SCRIPT_NAME"
}

# ─── Arg parsing ─────────────────────────────────────────────────────────────
DRY_RUN="false"
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN="true" ;;
    --help | -h)
      cat <<EOF
Usage: $SCRIPT_NAME [--dry-run]

Renders and deploys the student portal (index.html) to all existing slots
for the current cohort. Joins cohort-students and cohort-slots CSVs by slug.

Required env vars (from .env):
  COHORT_NAME, DOMAIN, GCP_PROJECT_ID, GCP_ZONE, VM_NAME

Flags:
  --dry-run   Validate inputs and show what would be deployed; no VM changes.
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

# ─── Env ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

if [[ -f "$ENV_FILE" ]]; then
  # Preserve any inline-set overrides across the source.
  _saved_students="${COHORT_STUDENTS_CSV_PATH:-}"
  _saved_slots="${COHORT_SLOTS_CSV_PATH:-}"
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
  [[ -n "$_saved_students" ]] && COHORT_STUDENTS_CSV_PATH="$_saved_students"
  [[ -n "$_saved_slots" ]] && COHORT_SLOTS_CSV_PATH="$_saved_slots"
  unset _saved_students _saved_slots
fi

require_var() {
  [[ -n "${!1:-}" ]] || {
    log error "required env var $1 is not set"
    exit 1
  }
}

require_var COHORT_NAME
require_var DOMAIN
require_var GCP_PROJECT_ID
require_var GCP_ZONE
require_var VM_NAME

STUDENTS_CSV="${COHORT_STUDENTS_CSV_PATH:-$REPO_ROOT/cohort-students-${COHORT_NAME}.csv}"
SLOTS_CSV="${COHORT_SLOTS_CSV_PATH:-$REPO_ROOT/cohort-slots-${COHORT_NAME}.csv}"
PORTAL_TEMPLATE="$REPO_ROOT/templates/student-portal/index.html"

# ─── Validate inputs ─────────────────────────────────────────────────────────
log info "step 1/4: validating inputs"

[[ -f "$STUDENTS_CSV" ]] || {
  log error "not found: $STUDENTS_CSV"
  exit 1
}
[[ -f "$SLOTS_CSV" ]] || {
  log error "not found: $SLOTS_CSV (run provision-sites.sh first)"
  exit 1
}
[[ -f "$PORTAL_TEMPLATE" ]] || {
  log error "not found: $PORTAL_TEMPLATE"
  exit 1
}

# Accept both old (slug,slot,site_url,name) and new (slug,slot,site_url,name,litellm_key) formats
STUDENTS_HEADER="$(head -1 "$STUDENTS_CSV")"

if [[ "$STUDENTS_HEADER" != "slug,owui_user_id,email,owui_password,litellm_key" ]]; then
  log error "unexpected cohort-students CSV header: $STUDENTS_HEADER"
  exit 1
fi

log info "students CSV: $STUDENTS_CSV"
log info "slots CSV:    $SLOTS_CSV"
log info "template:     $PORTAL_TEMPLATE"

# ─── gcloud check ────────────────────────────────────────────────────────────
log info "step 2/4: verifying gcloud auth"
if [[ "$DRY_RUN" == "false" ]]; then
  gcloud auth list --filter='status:ACTIVE' --format='value(account)' >/dev/null 2>&1 || {
    log error "gcloud not authenticated — run: gcloud auth login"
    exit 2
  }
  log info "gcloud auth ok"
else
  log info "skipped (dry-run)"
fi

# ─── Build slug → key lookup from students CSV ───────────────────────────────
log info "step 3/4: rendering portal for each slot"

render_dir="$(mktemp -d)"
trap 'rm -rf "$render_dir"' EXIT

# Read slots CSV — columns may be 4 (old) or 5 (new); slot is always col 2
tail -n +2 "$SLOTS_CSV" | while IFS=, read -r slug slot site_url name _rest; do
  # Look up litellm_key from students CSV by slug
  litellm_key="$(awk -F, -v s="$slug" 'NR>1 && $1==s {print $5}' "$STUDENTS_CSV")"

  if [[ -z "$litellm_key" ]]; then
    log error "  no litellm_key found for slug '$slug' — skipping slot $slot"
    continue
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log info "  DRY RUN: would deploy portal to $slot for $slug (key: ${litellm_key:0:8}...)"
    continue
  fi

  slot_dir="$render_dir/$slot"
  mkdir -p "$slot_dir"

  # Render portal with per-student values
  sed \
    -e "s|__STUDENT_NAME__|${name}|g" \
    -e "s|__STUDENT_API_KEY__|${litellm_key}|g" \
    -e "s|__STUDENT_SLOT__|${slot}|g" \
    "$PORTAL_TEMPLATE" >"$slot_dir/index.html"

  log info "  deploying portal to $slot ($slug) → $site_url"

  # scp rendered file to /tmp on VM
  gcloud compute scp \
    --tunnel-through-iap \
    --zone="$GCP_ZONE" \
    --project="$GCP_PROJECT_ID" \
    "$slot_dir/index.html" \
    "${VM_NAME}:/tmp/${slot}-index.html" </dev/null >/dev/null 2>&1 || {
    log error "  scp failed for $slot"
    exit 2
  }

  # sudo-move into place
  gcloud compute ssh \
    --tunnel-through-iap \
    --zone="$GCP_ZONE" \
    --project="$GCP_PROJECT_ID" \
    "$VM_NAME" \
    --command="sudo mv /tmp/${slot}-index.html /srv/students/${slot}/index.html && sudo chmod 644 /srv/students/${slot}/index.html" \
    </dev/null >/dev/null 2>&1 || {
    log error "  ssh+sudo-move failed for $slot"
    exit 2
  }

  log info "  ✓ $slot portal live at $site_url"
done

# ─── Done ────────────────────────────────────────────────────────────────────
log info "step 4/4: deploy-portal complete"
if [[ "$DRY_RUN" == "true" ]]; then
  log info "DRY RUN — no changes made to VM"
fi
