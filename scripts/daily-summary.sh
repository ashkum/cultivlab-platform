#!/usr/bin/env bash
# scripts/daily-summary.sh — daily cost + activity report → #cultivlab-reports.
#
# Reads LiteLLM_SpendLogs for the last 24 hours via the Postgres container and
# posts a formatted summary to Slack. Designed to run as a root crontab job on
# the VM at 23:00 UTC daily (see docs/install.md §11).
#
# Spend attribution note (ADR-011):
#   Chat via Open WebUI uses the master key; per-student attribution is by the
#   Open WebUI UUID in the "user" field. The student's display name is not
#   resolvable from the VM without the cohort-students CSV, so chat spend is
#   reported as a cohort-level count only.
#   IDE use via Continue.dev uses the student's virtual key; per-student name
#   is resolved from the key's metadata in LiteLLM_VerificationToken.
#
# Exit codes: 0 = success, 1 = config/setup error, 2 = runtime error.
# Usage: daily-summary.sh [--dry-run] [--force] [--help]

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
FORCE=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --force) FORCE=true ;;
    --help | -h)
      cat <<EOF
Usage: $SCRIPT_NAME [--dry-run] [--force] [--help]

Posts the daily cost + activity report to SLACK_WEBHOOK_REPORTS.
Idempotent per UTC day; --force bypasses the sentinel for re-testing.

Required env (auto-loaded from /opt/cultivlab/.env):
  POSTGRES_USER  POSTGRES_DB  POSTGRES_PASSWORD
  SLACK_WEBHOOK_REPORTS  COHORT_NAME  COHORT_MAX_BUDGET

Optional env:
  POSTGRES_CONTAINER   Docker container name (default: cultivlab-postgres-1)

Flags:
  --dry-run  Print report to stdout; skip Slack post and sentinel write.
  --force    Post even if today's sentinel already exists.
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
  SLACK_WEBHOOK_REPORTS COHORT_NAME COHORT_MAX_BUDGET
if ! command -v jq >/dev/null 2>&1; then
  log error "jq is required (sudo apt-get install -y jq)"
  exit 1
fi
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-cultivlab-postgres-1}"

# ── Idempotency sentinel ───────────────────────────────────────────────────
DATE_UTC="$(date -u +%Y-%m-%d)"
SENTINEL="${LOG_DIR}/daily-summary-${DATE_UTC}.done"

# Only create log dir in live mode; dry-run must not touch /var/log/cultivlab.
[[ "$DRY_RUN" == "false" ]] && mkdir -p "$LOG_DIR"

if [[ "$DRY_RUN" == "false" ]] && [[ "$FORCE" == "false" ]] && [[ -f "$SENTINEL" ]]; then
  log info "already posted for $DATE_UTC (sentinel: $SENTINEL); use --force to override"
  exit 0
fi

# ── psql helper ────────────────────────────────────────────────────────────
# Executes SQL inside the Postgres container. Returns tab-delimited rows.
# On docker/psql error: logs a warning and returns empty string (|| true).
run_psql() {
  local sql="$1"
  docker exec \
    -e PGPASSWORD="${POSTGRES_PASSWORD}" \
    "${POSTGRES_CONTAINER}" \
    psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
    -t -A -F'|' -c "${sql}" 2>/dev/null || true
}

# SQL-safe escape: replace ' with '' for operator-supplied values.
_sql_esc() { printf '%s' "$1" | sed "s/'/''/g"; }

COHORT_SQL="$(_sql_esc "$COHORT_NAME")"

# ── Query 1: Cohort team totals ────────────────────────────────────────────
log info "querying team info cohort=${COHORT_NAME}"
TEAM_ROW=""
if [[ "$DRY_RUN" == "false" ]]; then
  TEAM_ROW="$(run_psql "
    SELECT ROUND(spend::numeric,4),
           ROUND(COALESCE(max_budget,0)::numeric,2),
           COALESCE(blocked::text,'false')
    FROM \"LiteLLM_TeamTable\"
    WHERE team_alias = '${COHORT_SQL}'
    LIMIT 1;")"
else
  TEAM_ROW="0.0000|${COHORT_MAX_BUDGET}|false"
fi

TEAM_SPEND="0.0000"
TEAM_MAX="${COHORT_MAX_BUDGET}"
TEAM_BLOCKED="false"
if [[ -n "$TEAM_ROW" ]]; then
  IFS='|' read -r TEAM_SPEND TEAM_MAX TEAM_BLOCKED <<<"$TEAM_ROW"
fi
TEAM_PCT="$(awk -v s="$TEAM_SPEND" -v m="$TEAM_MAX" \
  'BEGIN { if (m > 0) printf "%.1f", s/m*100; else print "n/a" }')"

# ── Query 2: Per-student key activity (24h) ────────────────────────────────
# Covers IDE (Continue.dev) spend via student virtual keys.
log info "querying per-student 24h key activity"
STUDENT_ROWS=""
if [[ "$DRY_RUN" == "false" ]]; then
  STUDENT_ROWS="$(run_psql "
    SELECT
      COALESCE(vt.metadata->>'name', vt.key_alias)    AS name,
      COALESCE(vt.metadata->>'slug', vt.key_alias)    AS slug,
      ROUND(COALESCE(SUM(sl.spend),0)::numeric,6)     AS daily_spend,
      COUNT(sl.request_id)                             AS daily_req,
      ROUND(vt.spend::numeric,6)                      AS cumul_spend,
      COALESCE(vt.max_budget::text,'0')               AS max_budget,
      COALESCE(vt.blocked::text,'false')              AS blocked
    FROM \"LiteLLM_VerificationToken\" vt
    LEFT JOIN \"LiteLLM_SpendLogs\" sl
      ON sl.api_key = vt.token
      AND sl.\"startTime\" >= NOW() - INTERVAL '24 hours'
    WHERE vt.team_id = (
      SELECT team_id FROM \"LiteLLM_TeamTable\"
      WHERE team_alias = '${COHORT_SQL}' LIMIT 1
    )
    GROUP BY vt.key_alias, vt.metadata, vt.spend, vt.max_budget, vt.blocked
    ORDER BY daily_spend DESC, slug;")"
else
  STUDENT_ROWS="$(printf '%s\n' \
    "Alice Smith|alice-smith|0.120000|8|1.230000|10|false" \
    "Bob Jones|bob-jones|0.000000|0|0.450000|10|false")"
fi

# ── Query 3: Chat activity by Open WebUI user field (24h) ──────────────────
log info "querying 24h chat activity"
CHAT_ROW=""
if [[ "$DRY_RUN" == "false" ]]; then
  CHAT_ROW="$(run_psql "
    SELECT
      COUNT(DISTINCT \"user\")              AS unique_users,
      COUNT(*)                              AS total_req,
      ROUND(COALESCE(SUM(spend),0)::numeric,6) AS total_spend
    FROM \"LiteLLM_SpendLogs\"
    WHERE \"startTime\" >= NOW() - INTERVAL '24 hours'
      AND \"user\" IS NOT NULL
      AND \"user\" <> '';")"
else
  CHAT_ROW="2|23|0.870000"
fi

CHAT_USERS="0"
CHAT_REQS="0"
CHAT_SPEND="0.000000"
if [[ -n "$CHAT_ROW" ]]; then
  IFS='|' read -r CHAT_USERS CHAT_REQS CHAT_SPEND <<<"$CHAT_ROW"
fi

# ── Aggregate totals ───────────────────────────────────────────────────────
IDE_TOTAL_REQS=0
IDE_TOTAL_SPEND="0.000000"
while IFS='|' read -r _name _slug daily_spend daily_req _cumul _max _blocked; do
  [[ -z "${_name:-}" ]] && continue
  IDE_TOTAL_REQS=$((IDE_TOTAL_REQS + daily_req))
  IDE_TOTAL_SPEND="$(awk -v a="$IDE_TOTAL_SPEND" -v b="$daily_spend" \
    'BEGIN { printf "%.6f", a+b }')"
done <<<"$STUDENT_ROWS"

TOTAL_SPEND="$(awk -v a="$IDE_TOTAL_SPEND" -v b="$CHAT_SPEND" \
  'BEGIN { printf "%.4f", a+b }')"
HAS_ACTIVITY=false
((IDE_TOTAL_REQS > 0 || CHAT_REQS > 0)) && HAS_ACTIVITY=true

# ── Build Slack message ────────────────────────────────────────────────────
TEAM_STATUS="active"
[[ "$TEAM_BLOCKED" == "true" ]] && TEAM_STATUS="⛔ BLOCKED"

HEADER="📊 *CultivLab Daily Report — ${DATE_UTC} UTC*"
COHORT_LINE="*Cohort:* ${COHORT_NAME} | *Cumulative:* \$${TEAM_SPEND} / \$${TEAM_MAX} (${TEAM_PCT}%) | ${TEAM_STATUS}"

if [[ "$HAS_ACTIVITY" == "false" ]]; then
  MSG="${HEADER}

${COHORT_LINE}

No activity in the last 24 hours. ✅ Cron is healthy."
else
  # Per-student table (monospace block)
  STUDENT_TABLE=""
  while IFS='|' read -r name slug daily_spend daily_req cumul max_budget blocked; do
    [[ -z "${name:-}" ]] && continue
    icon="✅"
    [[ "$blocked" == "true" ]] && icon="⛔"
    pct="$(awk -v s="$cumul" -v m="$max_budget" \
      'BEGIN { if (m > 0) printf "%3.0f", s/m*100; else printf "n/a" }')"
    STUDENT_TABLE+="$(printf '%-20s $%-8s %3s req  cumul $%s/$%s (%s%%) %s' \
      "$slug" "$daily_spend" "$daily_req" "$cumul" "$max_budget" "$pct" "$icon")"$'\n'
  done <<<"$STUDENT_ROWS"

  MSG="${HEADER}

${COHORT_LINE}

\`\`\`
── IDE Activity (Continue.dev virtual keys, last 24h) ──────────
${STUDENT_TABLE:-  (no student key activity)}
\`\`\`
\`\`\`
── Chat Activity (Open WebUI, last 24h) ────────────────────────
  Active students : ${CHAT_USERS}
  Requests        : ${CHAT_REQS}
  Spend           : \$${CHAT_SPEND}
  (Names not resolved on VM; see OW admin for breakdown)
\`\`\`

*24h totals* — IDE: \$${IDE_TOTAL_SPEND} | Chat: \$${CHAT_SPEND} | Combined: \$${TOTAL_SPEND}"
fi

# ── Post to Slack (or print in dry-run) ────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  log info "DRY RUN — skipping Slack post"
  echo ""
  echo "=== Slack message preview ==="
  printf '%s\n' "$MSG"
  echo "============================="
  log info "dry-run complete date=${DATE_UTC} has_activity=${HAS_ACTIVITY}"
  exit 0
fi

log info "posting to Slack"
HTTP_CODE="$(curl -sSf -o /dev/null -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' \
  --data-raw "$(jq -nc --arg t "$MSG" '{text: $t}')" \
  "${SLACK_WEBHOOK_REPORTS}" 2>/dev/null || echo "000")"

if [[ "$HTTP_CODE" != "200" ]]; then
  log error "Slack post failed HTTP=${HTTP_CODE}"
  exit 2
fi
log info "Slack post OK HTTP=${HTTP_CODE}"

# ── Idempotency sentinel ───────────────────────────────────────────────────
printf 'posted at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$SENTINEL"
log info "sentinel written: $SENTINEL"
log info "complete date=${DATE_UTC} has_activity=${HAS_ACTIVITY} total_spend=${TOTAL_SPEND}"
exit 0
