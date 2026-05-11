#!/usr/bin/env bash
#
# generate-cards.sh — produces per-student onboarding markdown cards.
#
# Inputs:
#   - cohort-students-${COHORT_NAME}.csv (Sprint 3 output): slug, owui_user_id, email, owui_password, litellm_key
#   - cohort-slots-${COHORT_NAME}.csv    (Sprint 4 D4 output): slug, slot, site_url, name
#   - templates/continue-config/config.yaml.tmpl (Sprint 4 D5)
#
# Outputs:
#   - onboarding-cards-${COHORT_NAME}/ directory containing:
#       - onboarding-<slug>.md  (mode 600, one per student)
#       - README.md             (index of cards)
#
# Idempotent: re-running overwrites existing cards.
#
# Exit codes:
#   0 — success
#   1 — input/validation error
#   2 — runtime error

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
    --dry-run) DRY_RUN="true" ;;
    --help | -h)
      cat <<EOF
Usage: $SCRIPT_NAME [--dry-run]

Generates per-student onboarding markdown cards from the cohort CSVs.

Required env vars (from .env or inline):
  COHORT_NAME, DOMAIN
  COHORT_STUDENTS_CSV_PATH  (optional; defaults to ./cohort-students-\${COHORT_NAME}.csv)
  COHORT_SLOTS_CSV_PATH     (optional; defaults to ./cohort-slots-\${COHORT_NAME}.csv)

Flags:
  --dry-run   Validate inputs without writing card files.
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

# ─── Env loading ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

if [[ -f "$ENV_FILE" ]]; then
  log info "loading env from $ENV_FILE"
  _saved_cohort="${COHORT_NAME:-}"
  _saved_students_path="${COHORT_STUDENTS_CSV_PATH:-}"
  _saved_slots_path="${COHORT_SLOTS_CSV_PATH:-}"
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
  [[ -n "$_saved_cohort" ]] && COHORT_NAME="$_saved_cohort"
  [[ -n "$_saved_students_path" ]] && COHORT_STUDENTS_CSV_PATH="$_saved_students_path"
  [[ -n "$_saved_slots_path" ]] && COHORT_SLOTS_CSV_PATH="$_saved_slots_path"
  unset _saved_cohort _saved_students_path _saved_slots_path
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

STUDENTS_CSV="${COHORT_STUDENTS_CSV_PATH:-$REPO_ROOT/cohort-students-${COHORT_NAME}.csv}"
SLOTS_CSV="${COHORT_SLOTS_CSV_PATH:-$REPO_ROOT/cohort-slots-${COHORT_NAME}.csv}"
OUTPUT_DIR="$REPO_ROOT/onboarding-cards-${COHORT_NAME}"
CONFIG_TEMPLATE="$REPO_ROOT/templates/continue-config/config.yaml.tmpl"

# ─── Input validation ─────────────────────────────────────────────────────
log info "step 1/4: validating inputs"

for f in "$STUDENTS_CSV" "$SLOTS_CSV" "$CONFIG_TEMPLATE"; do
  if [[ ! -f "$f" ]]; then
    log error "required file not found: $f"
    exit 1
  fi
done

# Verify headers
STUDENTS_HEADER="$(head -1 "$STUDENTS_CSV")"
SLOTS_HEADER="$(head -1 "$SLOTS_CSV")"
EXPECTED_STUDENTS="slug,owui_user_id,email,owui_password,litellm_key"
EXPECTED_SLOTS="slug,slot,site_url,name"

if [[ "$STUDENTS_HEADER" != "$EXPECTED_STUDENTS" ]]; then
  log error "cohort-students CSV header mismatch"
  log error "  expected: $EXPECTED_STUDENTS"
  log error "  actual:   $STUDENTS_HEADER"
  exit 1
fi

if [[ "$SLOTS_HEADER" != "$EXPECTED_SLOTS" ]]; then
  log error "cohort-slots CSV header mismatch"
  log error "  expected: $EXPECTED_SLOTS"
  log error "  actual:   $SLOTS_HEADER"
  exit 1
fi

STUDENT_COUNT=$(($(wc -l <"$STUDENTS_CSV") - 1))
SLOT_COUNT=$(($(wc -l <"$SLOTS_CSV") - 1))

if [[ "$STUDENT_COUNT" -ne "$SLOT_COUNT" ]]; then
  log error "row count mismatch: $STUDENT_COUNT students vs $SLOT_COUNT slots"
  log error "ensure provision-students.sh and provision-sites.sh have both run successfully"
  exit 1
fi

log info "found $STUDENT_COUNT students with matching slot assignments"

# ─── Render cards ─────────────────────────────────────────────────────────
log info "step 2/4: rendering cards"

if [[ "$DRY_RUN" == "true" ]]; then
  log info "DRY RUN — skipping card rendering"
else
  mkdir -p "$OUTPUT_DIR"
  chmod 700 "$OUTPUT_DIR"
fi

# Build joined CSV (students + slots on slug) using awk
# Output columns: slug,email,owui_password,litellm_key,slot,site_url,name
JOINED_CSV="$(mktemp)"
trap 'rm -f "$JOINED_CSV"' EXIT

awk -F, 'BEGIN { OFS="," }
  FNR == 1 { next }  # skip headers
  NR == FNR { slots[$1] = $2 OFS $3 OFS $4; next }
  ($1 in slots) { print $1, $3, $4, $5, slots[$1] }
' "$SLOTS_CSV" "$STUDENTS_CSV" >"$JOINED_CSV"

JOINED_COUNT=$(wc -l <"$JOINED_CSV")
if [[ "$JOINED_COUNT" -ne "$STUDENT_COUNT" ]]; then
  log error "join produced $JOINED_COUNT rows but expected $STUDENT_COUNT"
  log error "check that every student in $STUDENTS_CSV has a matching slug in $SLOTS_CSV"
  exit 1
fi

cards_written=0

while IFS=, read -r slug email owui_password litellm_key slot site_url name; do

  log info "  rendering card for $slug → $slot ($email)"

  if [[ "$DRY_RUN" == "true" ]]; then
    cards_written=$((cards_written + 1))
    continue
  fi

  card_path="$OUTPUT_DIR/onboarding-${slug}.md"

  # Render Continue.dev config snippet inline (needs ${DOMAIN} and ${STUDENT_LITELLM_KEY})
  config_snippet=$(DOMAIN="$DOMAIN" STUDENT_LITELLM_KEY="$litellm_key" \
    envsubst <"$CONFIG_TEMPLATE")

  cat >"$card_path" <<CARDEOF
# Welcome to CultivLab, $name! 🌱

You're part of cohort **$COHORT_NAME**. This card has everything you need to get started.

⚠️ **Keep this card private.** It has your login password and API key.

---

## 1. Your chat with Claude

Open this URL in your browser:

> **https://chat.$DOMAIN**

Log in with:

- **Email:** \`$email\`
- **Password:** \`$owui_password\`

Tip: change your password once you're logged in (top-right profile menu).

---

## 2. Your website

You have your own website at:

> **$site_url**

Right now it shows a starter page. Over the next 3 weeks, you'll edit it
to make it your own. We'll show you how!

---

## 3. VS Code with Continue.dev (optional, for week 2+)

Continue.dev is a free VS Code extension that lets Claude help you write
code directly in your editor.

To set it up:

1. Install VS Code: https://code.visualstudio.com/
2. Install the Continue.dev extension from the VS Code marketplace
3. Save the following YAML at \`~/.continue/config.yaml\`:

\`\`\`yaml
$config_snippet
\`\`\`

Now you can press \`Cmd+L\` (Mac) or \`Ctrl+L\` (Windows/Linux) in VS Code
to chat with Claude about your code.

---

## 4. What to try first

Once you're logged in, try asking Claude:

- "Help me change the title on my website to my name"
- "What does \`<h1>\` mean?"
- "Make the button on my site say 'Hi friends!'"

Claude is here to help. There are no dumb questions. 🤖

---

## 5. Getting help

If you get stuck:

1. Ask Claude in chat
2. Look at the README in your website's folder
3. Ask your instructor

Have fun! 🚀
CARDEOF

  chmod 600 "$card_path"
  cards_written=$((cards_written + 1))
done <"$JOINED_CSV"

# ─── Write index README ───────────────────────────────────────────────────
log info "step 3/4: writing index README"

if [[ "$DRY_RUN" == "false" ]]; then
  cat >"$OUTPUT_DIR/README.md" <<READMEEOF
# Onboarding Cards — Cohort $COHORT_NAME

Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by \`scripts/generate-cards.sh\`.

## Cards

$(while IFS=, read -r slug _email _pw _key slot _url name; do
    echo "- \`onboarding-${slug}.md\` — $name ($slot)"
  done <"$JOINED_CSV")

## Distribution

These files contain student credentials and should be:

- Printed and handed to each student in person, OR
- Sent to each student's parent via secure channel (email is acceptable for ages 8-12)
- NEVER posted publicly or shared with the wrong student

The directory has mode 700 and individual cards have mode 600.

READMEEOF
  chmod 600 "$OUTPUT_DIR/README.md"
fi

# ─── Summary ──────────────────────────────────────────────────────────────
log info "step 4/4: generate-cards complete"
log info "  cohort: $COHORT_NAME"
log info "  cards: $cards_written"
if [[ "$DRY_RUN" == "false" ]]; then
  log info "  output: $OUTPUT_DIR/"
  log info "verify:"
  log info "  ls -la $OUTPUT_DIR/"
fi
