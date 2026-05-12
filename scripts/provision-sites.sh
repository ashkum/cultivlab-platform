#!/usr/bin/env bash
#
# provision-sites.sh — assigns cohort students to slot subdomains l01..lNN and
# deploys the student-starter template to each slot on the VM filesystem.
#
# Inputs:
#   - cohort-students-${COHORT_NAME}.csv (Sprint 3 output) with columns:
#       slug,owui_user_id,email,owui_password,litellm_key
#   - templates/student-starter/{index.html,README.md}
#   - .env (DOMAIN, GCP_PROJECT_ID, GCP_ZONE, VM_NAME, COHORT_NAME)
#
# Outputs:
#   - /srv/students/lNN/index.html on VM (customized per student)
#   - /srv/students/lNN/README.md on VM (unchanged from template)
#   - cohort-slots-${COHORT_NAME}.csv (mode 600) with columns:
#       slug,slot,site_url,name
#
# Idempotent: re-running with same COHORT_NAME re-renders + re-uploads;
# operator can safely re-run.
#
# Exit codes:
#   0 — success
#   1 — input/validation error (CSV missing, slot capacity exceeded, etc.)
#   2 — runtime error (scp failure, gcloud not authenticated, etc.)

set -euo pipefail

# ─── Logging (matches Sprint 2/3 JSON pattern) ─────────────────────────────
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

# ─── Arg parsing ──────────────────────────────────────────────────────────
DRY_RUN="false"
for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN="true"
      ;;
    --help | -h)
      cat <<EOF
Usage: $SCRIPT_NAME [--dry-run]

Provisions cohort students into slot subdomains l01..lNN.
Reads cohort-students-\${COHORT_NAME}.csv and deploys the starter template
to each student's slot on the VM at /srv/students/lNN/.

Required env vars (typically from .env):
  COHORT_NAME, DOMAIN
  GCP_PROJECT_ID, GCP_ZONE, VM_NAME
  COHORT_STUDENTS_CSV_PATH  (optional; defaults to ./cohort-students-\${COHORT_NAME}.csv)

Flags:
  --dry-run   Validate inputs + simulate slot assignment without uploading.
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

# ─── Env loading + validation ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

if [[ -f "$ENV_FILE" ]]; then
  log info "loading env from $ENV_FILE"
  # Inline env vars take precedence over .env values.
  # Capture any already-set values, source .env, then restore inline values.
  _saved_cohort="${COHORT_NAME:-}"
  _saved_csv_path="${COHORT_STUDENTS_CSV_PATH:-}"
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
  [[ -n "$_saved_cohort" ]] && COHORT_NAME="$_saved_cohort"
  [[ -n "$_saved_csv_path" ]] && COHORT_STUDENTS_CSV_PATH="$_saved_csv_path"
  unset _saved_cohort _saved_csv_path
fi

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    log error "required env var $name is not set"
    exit 1
  fi
}

require_var COHORT_NAME
require_var DOMAIN
require_var GCP_PROJECT_ID
require_var GCP_ZONE
require_var VM_NAME

CSV_PATH="${COHORT_STUDENTS_CSV_PATH:-$REPO_ROOT/cohort-students-${COHORT_NAME}.csv}"
TEMPLATE_DIR="${TEMPLATE_DIR:-$REPO_ROOT/templates/student-starter}"
OUTPUT_CSV="${OUTPUT_CSV:-$REPO_ROOT/cohort-slots-${COHORT_NAME}.csv}"
MAX_SLOTS="${MAX_SLOTS:-12}"

# ─── Input validation ─────────────────────────────────────────────────────
log info "step 1/6: validating inputs"

if [[ ! -f "$CSV_PATH" ]]; then
  log error "cohort students CSV not found: $CSV_PATH"
  log error "run scripts/provision-students.sh first"
  exit 1
fi

if [[ ! -d "$TEMPLATE_DIR" ]]; then
  log error "template directory not found: $TEMPLATE_DIR"
  exit 1
fi

for required_file in index.html README.md; do
  if [[ ! -f "$TEMPLATE_DIR/$required_file" ]]; then
    log error "required template file missing: $TEMPLATE_DIR/$required_file"
    exit 1
  fi
done

# Verify header matches Sprint 3 output schema
EXPECTED_HEADER="slug,owui_user_id,email,owui_password,litellm_key"
ACTUAL_HEADER="$(head -1 "$CSV_PATH")"
if [[ "$ACTUAL_HEADER" != "$EXPECTED_HEADER" ]]; then
  log error "CSV header mismatch"
  log error "  expected: $EXPECTED_HEADER"
  log error "  actual:   $ACTUAL_HEADER"
  exit 1
fi

# Count students (lines minus header)
STUDENT_COUNT=$(($(wc -l <"$CSV_PATH") - 1))
if [[ "$STUDENT_COUNT" -lt 1 ]]; then
  log error "CSV has no student rows: $CSV_PATH"
  exit 1
fi

if [[ "$STUDENT_COUNT" -gt "$MAX_SLOTS" ]]; then
  log error "cohort has $STUDENT_COUNT students but only $MAX_SLOTS slots available"
  log error "extend the Caddyfile slot list and DNS records, then re-run"
  exit 1
fi

log info "found $STUDENT_COUNT students in cohort $COHORT_NAME (max $MAX_SLOTS slots)"

# ─── gcloud check ─────────────────────────────────────────────────────────
log info "step 2/6: verifying gcloud auth"
if [[ "$DRY_RUN" == "false" ]]; then
  if ! gcloud auth list --filter='status:ACTIVE' --format='value(account)' >/dev/null 2>&1; then
    log error "gcloud is not authenticated; run: gcloud auth login"
    exit 2
  fi
  # Test that we can describe the VM (cheap permission check)
  if ! gcloud compute instances describe "$VM_NAME" \
    --project="$GCP_PROJECT_ID" --zone="$GCP_ZONE" \
    --format='value(name)' >/dev/null 2>&1; then
    log error "cannot access VM $VM_NAME in $GCP_ZONE; check IAM permissions"
    exit 2
  fi
  log info "gcloud auth ok"
else
  log info "skipped (dry-run)"
fi

# ─── Slot assignment ──────────────────────────────────────────────────────
log info "step 3/6: assigning slots l01..l$(printf '%02d' "$STUDENT_COUNT")"

TEMP_OUTPUT="$(mktemp)"
trap 'rm -f "$TEMP_OUTPUT"' EXIT

echo "slug,slot,site_url,name" >"$TEMP_OUTPUT"

slot_num=1
# Read CSV body (skip header)
tail -n +2 "$CSV_PATH" | while IFS=, read -r slug _owui_user_id email _owui_pw _litellm_key; do
  slot=$(printf 'l%02d' "$slot_num")

  # Default student name from slug if no first-name lookup available
  # (Sprint 3 CSV doesn't carry name; we'll humanize the slug here)
  name="$slug"

  site_url="https://${slot}.${DOMAIN}"
  log info "slot ${slot} → ${slug} (${email})"
  echo "${slug},${slot},${site_url},${name}" >>"$TEMP_OUTPUT"

  slot_num=$((slot_num + 1))
done

# ─── Render + upload ──────────────────────────────────────────────────────
log info "step 4/6: rendering + uploading templates"

if [[ "$DRY_RUN" == "true" ]]; then
  log info "DRY RUN — skipping template render + scp + .student manifest; no remote changes"
else
  render_dir="$(mktemp -d)"
  trap 'rm -rf "$render_dir" "$TEMP_OUTPUT"' EXIT

  # Iterate the OUTPUT csv (which has the slot mapping).
  # Use process substitution to avoid subshell from pipe; lets exit 2
  # propagate from inside the loop.
  while IFS=, read -r slug slot site_url name; do
    slot_dir="$render_dir/$slot"
    mkdir -p "$slot_dir"

    # Customize index.html with student's name (replace the placeholder greeting)
    sed "s|Hi, I'm a CultivLab student!|Hi, I'm ${name} — welcome to my site!|" \
      "$TEMPLATE_DIR/index.html" >"$slot_dir/index.html"

    # README.md unchanged
    cp "$TEMPLATE_DIR/README.md" "$slot_dir/README.md"

    # scp to /tmp/$slot/ then sudo-cp into /srv/students/$slot/
    log info "  uploading $slot files to VM"

    # Upload to /tmp/ first (no sudo needed for scp target)
    gcloud compute scp \
      --tunnel-through-iap \
      --zone="$GCP_ZONE" \
      --project="$GCP_PROJECT_ID" \
      --recurse \
      "$slot_dir" \
      "${VM_NAME}:/tmp/" </dev/null >/dev/null 2>&1 || {
      log error "  scp failed for $slot"
      exit 2
    }

    # Move from /tmp/$slot/ to /srv/students/$slot/ via ssh+sudo
    gcloud compute ssh \
      --tunnel-through-iap \
      --zone="$GCP_ZONE" \
      --project="$GCP_PROJECT_ID" \
      "$VM_NAME" \
      --command="sudo mkdir -p /srv/students/$slot && sudo cp /tmp/$slot/*.html /tmp/$slot/*.md /srv/students/$slot/ && sudo rm -rf /tmp/$slot" </dev/null >/dev/null 2>&1 || {
      log error "  ssh+sudo-copy failed for $slot"
      exit 2
    }

    # Write slug manifest for Founder Console slot lookup (ADR-008 / Sprint 5.5)
    gcloud compute ssh \
      --tunnel-through-iap \
      --zone="$GCP_ZONE" \
      --project="$GCP_PROJECT_ID" \
      "$VM_NAME" \
      --command="printf '%s' '${slug}' | sudo tee /srv/students/$slot/.student > /dev/null" </dev/null >/dev/null 2>&1 || {
      log error "  .student manifest write failed for $slot"
      exit 2
    }

    log info "  $slot deployed → $site_url"
  done < <(tail -n +2 "$TEMP_OUTPUT")

  rm -rf "$render_dir"
fi

# ─── Write output CSV ─────────────────────────────────────────────────────
log info "step 5/6: writing output CSV"

if [[ "$DRY_RUN" == "true" ]]; then
  log info "DRY RUN — would write $OUTPUT_CSV with $STUDENT_COUNT rows"
else
  mv "$TEMP_OUTPUT" "$OUTPUT_CSV"
  chmod 600 "$OUTPUT_CSV"
  trap 'rm -f' EXIT # disarm previous trap
  log info "wrote $OUTPUT_CSV (mode 600, $STUDENT_COUNT students)"
fi

# ─── Summary ──────────────────────────────────────────────────────────────
log info "step 6/6: provision-sites complete"
log info "  cohort: $COHORT_NAME"
log info "  students: $STUDENT_COUNT"
log info "  slots assigned: l01-l$(printf '%02d' "$STUDENT_COUNT")"
if [[ "$DRY_RUN" == "false" ]]; then
  log info "  output CSV: $OUTPUT_CSV"
  log info "verify:"
  log info "  curl -sI https://l01.${DOMAIN} | head -1"
fi
