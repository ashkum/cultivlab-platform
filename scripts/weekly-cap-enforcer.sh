#!/usr/bin/env bash
# scripts/weekly-cap-enforcer.sh — block student keys over their 7-day rolling budget.
#
# Queries LiteLLM_SpendLogs for each student's spend over the last 7 days. If
# spend exceeds STUDENT_WEEKLY_BUDGET, the key is blocked via a direct Postgres
# UPDATE on LiteLLM_VerificationToken. LiteLLM's in-memory cache clears within
# ~60 seconds, after which new requests from that student are rejected.
#
# Blocking rationale (ADR-011 / D1 research):
#   Plaintext student keys are never stored on the VM (captured at creation to
#   cohort-keys-*.csv on operator's Mac only). The /key/block API requires the
#   plaintext key; therefore blocking is done via direct Postgres UPDATE on the
#   hashed token column. This is idempotent: blocking an already-blocked key
#   is a no-op at the DB level.
#
# Designed to run daily at 23:30 UTC (see docs/install.md §11).
# Exit codes: 0 = success (including zero violations), 1 = config/setup error,
#             2 = runtime error (DB write or Slack post failed).
# Usage: weekly-cap-enforcer.sh [--dry-run] [--help]

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="/var/log/cultivlab"

# ── Logging (JSON, matches Sprint 2–4 pattern) ─────────────────────────────
log() {
  local level="$1"
  shift
  local msg="$*"
  msg="${msg//\\/\\\\}"
  msg="${msg//\"/\\\"}"
  printf '{"level":"%s","msg":"%s","ts":"%s","script":"%s"}\n' \
    "$level" "$msg" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SCRIPT_NAME"
}

# ── Arg parsing ────────────────────────────────────────────────────────────
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --help | -h)
      cat <<EOF
Usage: $SCRIPT_NAME [--dry-run] [--help]

Blocks student virtual keys whose 7-day rolling spend exceeds STUDENT_WEEKLY_BUDGET.
Runs daily at 23:30 UTC; idempotent (already-blocked keys are skipped).

Required env (auto-loaded from /opt/cultivlab/.env):
  POSTGRES_USER  POSTGRES_DB  POSTGRES_PASSWORD
  SLACK_WEBHOOK_BUDGET  COHORT_NAME  STUDENT_WEEKLY_BUDGET

Optional env:
  POSTGRES_CONTAINER  Docker container name (default: cultivlab-postgres-1)

Flags:
  --dry-run  Print which keys would be blocked; make no DB changes.
  --help     Show this message.
EOF
      exit 0
      ;;
    *)
      log error "unknown argument: $arg"
      exit 1
      ;;
  esac
done

# ── Load .env ──────────────────────────────────────────────────────────────
ENV_FILE="/opt/cultivlab/.env"
[[ ! -f "$ENV_FILE" ]] && ENV_FILE="${REPO_ROOT}/.env"
if [[ -f "$ENV_FILE" ]]; then
  log info "loading env from $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# ── Validate required env ──────────────────────────────────────────────────
_require() {
  local missing=()
  for v in "$@"; do [[ -z "${!v:-}" ]] && missing+=("$v"); done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log error "missing required env vars: ${missing[*]}"
    exit 1
  fi
}
_require POSTGRES_USER POSTGRES_DB POSTGRES_PASSWORD \
  SLACK_WEBHOOK_BUDGET COHORT_NAME STUDENT_WEEKLY_BUDGET

if ! command -v jq >/dev/null 2>&1; then
  log error "jq is required (sudo apt-get install -y jq)"
  exit 1
fi
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-cultivlab-postgres-1}"

# Only create log dir in live mode; dry-run must not touch /var/log/cultivlab.
[[ "$DRY_RUN" == "false" ]] && mkdir -p "$LOG_DIR"

# ── psql helpers ────────────────────────────────────────────────────────────
_sql_esc() { printf '%s' "$1" | sed "s/'/''/g"; }
COHORT_SQL="$(_sql_esc "$COHORT_NAME")"

# run_psql <sql> — SELECT queries; returns pipe-delimited rows; propagates errors.
run_psql() {
  docker exec \
    -e PGPASSWORD="${POSTGRES_PASSWORD}" \
    "${POSTGRES_CONTAINER}" \
    psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
    -t -A -F'|' -c "$1" 2>/dev/null
}

# run_psql_cmd <sql> — DML (UPDATE/DELETE); returns psql output; propagates errors.
run_psql_cmd() {
  docker exec \
    -e PGPASSWORD="${POSTGRES_PASSWORD}" \
    "${POSTGRES_CONTAINER}" \
    psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
    -t -A -c "$1" 2>/dev/null
}

# ── Query: 7-day rolling spend per student key in cohort ───────────────────
log info "querying 7-day rolling spend cohort=${COHORT_NAME} budget=${STUDENT_WEEKLY_BUDGET}"

STUDENT_ROWS=""
if [[ "$DRY_RUN" == "false" ]]; then
  STUDENT_ROWS="$(run_psql "
    SELECT
      vt.token,
      COALESCE(vt.metadata->>'name', vt.key_alias)  AS name,
      COALESCE(vt.metadata->>'slug', vt.key_alias)  AS slug,
      ROUND(COALESCE(SUM(sl.spend),0)::numeric,6)   AS weekly_spend,
      COALESCE(vt.blocked::text,'false')             AS blocked
    FROM \"LiteLLM_VerificationToken\" vt
    LEFT JOIN \"LiteLLM_SpendLogs\" sl
      ON sl.api_key = vt.token
     AND sl.\"startTime\" >= NOW() - INTERVAL '7 days'
    WHERE vt.team_id = (
      SELECT team_id FROM \"LiteLLM_TeamTable\"
      WHERE team_alias = '${COHORT_SQL}' LIMIT 1
    )
    GROUP BY vt.token, vt.key_alias, vt.metadata, vt.blocked
    ORDER BY weekly_spend DESC;")" || {
    log error "psql query failed — cannot enforce caps"
    exit 2
  }
else
  # Stub: alice over budget, bob under, carol already blocked.
  STUDENT_ROWS="$(printf '%s\n' \
    "hash-alice|Alice Smith|alice-smith|9.500000|false" \
    "hash-bob|Bob Jones|bob-jones|3.200000|false" \
    "hash-carol|Carol Lee|carol-lee|11.000000|true")"
fi

# ── Enforce caps ────────────────────────────────────────────────────────────
NEWLY_BLOCKED=()
ALREADY_BLOCKED=()
UNDER_BUDGET=()
ERRORS=()

while IFS='|' read -r token _name slug weekly_spend blocked; do
  [[ -z "${token:-}" ]] && continue

  over="$(awk -v s="$weekly_spend" -v b="$STUDENT_WEEKLY_BUDGET" \
    'BEGIN { print (s+0 > b+0) ? "1" : "0" }')"

  if [[ "$over" == "0" ]]; then
    log info "under budget slug=${slug} weekly_spend=${weekly_spend}"
    UNDER_BUDGET+=("${slug}:\$${weekly_spend}")
    continue
  fi

  if [[ "$blocked" == "true" ]]; then
    log info "already blocked slug=${slug} weekly_spend=${weekly_spend}"
    ALREADY_BLOCKED+=("${slug}:\$${weekly_spend}")
    continue
  fi

  # Over budget and not yet blocked.
  log info "blocking slug=${slug} weekly_spend=${weekly_spend} budget=${STUDENT_WEEKLY_BUDGET} dry_run=${DRY_RUN}"

  if [[ "$DRY_RUN" == "true" ]]; then
    NEWLY_BLOCKED+=("${slug}:\$${weekly_spend}")
  else
    TOKEN_SQL="$(_sql_esc "$token")"
    UPDATE_OUT="$(run_psql_cmd \
      "UPDATE \"LiteLLM_VerificationToken\" SET blocked = true WHERE token = '${TOKEN_SQL}';" \
      2>&1)" || {
      log error "DB block failed slug=${slug}"
      ERRORS+=("$slug")
      continue
    }
    log info "blocked slug=${slug} pg=${UPDATE_OUT}"
    NEWLY_BLOCKED+=("${slug}:\$${weekly_spend}")
  fi
done <<<"$STUDENT_ROWS"

log info "complete newly_blocked=${#NEWLY_BLOCKED[@]} already_blocked=${#ALREADY_BLOCKED[@]} under_budget=${#UNDER_BUDGET[@]} errors=${#ERRORS[@]}"

# ── Dry-run exit ────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  echo ""
  echo "=== Weekly cap enforcer dry-run ==="
  printf "  Budget : \$%s / 7 days\n" "$STUDENT_WEEKLY_BUDGET"
  printf "  Would block    (%d) : %s\n" "${#NEWLY_BLOCKED[@]}" "${NEWLY_BLOCKED[*]:-none}"
  printf "  Already blocked(%d) : %s\n" "${#ALREADY_BLOCKED[@]}" "${ALREADY_BLOCKED[*]:-none}"
  printf "  Under budget   (%d) : %s\n" "${#UNDER_BUDGET[@]}" "${UNDER_BUDGET[*]:-none}"
  echo "==================================="
  exit 0
fi

# ── Skip Slack if nothing actionable happened ──────────────────────────────
if [[ ${#NEWLY_BLOCKED[@]} -eq 0 && ${#ERRORS[@]} -eq 0 ]]; then
  log info "no new violations; skipping Slack post"
  exit 0
fi

# ── Build Slack alert ───────────────────────────────────────────────────────
DATE_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BLOCKED_LIST=""
for entry in "${NEWLY_BLOCKED[@]}"; do
  BLOCKED_LIST+="  • ${entry}"$'\n'
done

ERROR_SECTION=""
if [[ ${#ERRORS[@]} -gt 0 ]]; then
  ERROR_SECTION=$'\n'"⚠️ *Block failures — manual action required:*"$'\n'
  for slug in "${ERRORS[@]}"; do
    ERROR_SECTION+="  • ${slug}"$'\n'
  done
fi

MSG="⛔ *CultivLab Weekly Cap Enforcer — ${DATE_UTC}*
*Cohort:* ${COHORT_NAME} | *Budget:* \$${STUDENT_WEEKLY_BUDGET}/7 days

*Newly blocked (${#NEWLY_BLOCKED[@]}):*
${BLOCKED_LIST:-  (none)}${ERROR_SECTION}
_Keys block within ~60 s as LiteLLM cache expires._"

# ── Post Slack alert ────────────────────────────────────────────────────────
log info "posting Slack alert to SLACK_WEBHOOK_BUDGET"
HTTP_CODE="$(curl -sSf -o /dev/null -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' \
  --data-raw "$(jq -nc --arg t "$MSG" '{text: $t}')" \
  "${SLACK_WEBHOOK_BUDGET}" 2>/dev/null || echo "000")"

if [[ "$HTTP_CODE" != "200" ]]; then
  log error "Slack post failed HTTP=${HTTP_CODE}"
  exit 2
fi
log info "Slack alert posted HTTP=${HTTP_CODE}"

# Exit non-zero if any block errors remain (alerts operator to act manually).
if [[ ${#ERRORS[@]} -gt 0 ]]; then
  log error "completed with ${#ERRORS[@]} block failure(s) — manual intervention required"
  exit 2
fi
exit 0
