#!/usr/bin/env bash
# scripts/install-crontab.sh — install CultivLab operational cron jobs on the VM.
#
# Writes /etc/cron.d/cultivlab-ops with three daily jobs:
#   23:00 UTC — daily-summary.sh        (Slack cost + activity report)
#   23:30 UTC — weekly-cap-enforcer.sh  (block over-budget student keys)
#   02:00 UTC — backup-postgres.sh      (pg_dump → GCS)
#
# Also writes /etc/logrotate.d/cultivlab-ops (daily rotation, 14-day retention).
# Logs land in /var/log/cultivlab/<script-name>.log
#
# Must be run as root on the VM. Idempotent — safe to re-run after script updates.
# Exit codes: 0 = success, 1 = config/setup error.
# Usage: install-crontab.sh [--dry-run] [--help]

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/var/log/cultivlab"
CRON_FILE="/etc/cron.d/cultivlab-ops"
LOGROTATE_FILE="/etc/logrotate.d/cultivlab-ops"

# ── Logging ────────────────────────────────────────────────────────────────
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

Installs /etc/cron.d/cultivlab-ops and /etc/logrotate.d/cultivlab-ops.
Must be run as root on the VM. Idempotent — safe to re-run after updates.

Cron schedule (all UTC):
  23:00 daily — daily-summary.sh        (Slack report)
  23:30 daily — weekly-cap-enforcer.sh  (cap enforcement)
  02:00 daily — backup-postgres.sh      (GCS backup)

Flags:
  --dry-run  Print what would be written; make no changes.
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

# ── Root check ─────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "false" && "$(id -u)" -ne 0 ]]; then
  log error "must be run as root: sudo ${SCRIPT_DIR}/${SCRIPT_NAME}"
  exit 1
fi

# ── Verify scripts exist and are executable ────────────────────────────────
for s in daily-summary.sh weekly-cap-enforcer.sh backup-postgres.sh; do
  if [[ ! -x "${SCRIPT_DIR}/${s}" ]]; then
    log error "script not found or not executable: ${SCRIPT_DIR}/${s}"
    exit 1
  fi
done
log info "all three scripts verified scripts_dir=${SCRIPT_DIR}"

# ── Build cron file ────────────────────────────────────────────────────────
# PATH includes /snap/bin so gsutil (Cloud SDK snap) is found by cron jobs.
CRON_CONTENTS="# CultivLab operational cron jobs
# Managed by scripts/install-crontab.sh — re-run to update after script changes.
# Installed: $(date -u +%Y-%m-%dT%H:%M:%SZ)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin

# Daily cost + activity report → #cultivlab-reports (23:00 UTC)
0 23 * * * root ${SCRIPT_DIR}/daily-summary.sh >> ${LOG_DIR}/daily-summary.log 2>&1

# Weekly rolling cap enforcer — blocks over-budget student keys (23:30 UTC)
30 23 * * * root ${SCRIPT_DIR}/weekly-cap-enforcer.sh >> ${LOG_DIR}/weekly-cap-enforcer.log 2>&1

# Postgres backup → GCS with tiered rotation (02:00 UTC)
0 2 * * * root ${SCRIPT_DIR}/backup-postgres.sh >> ${LOG_DIR}/backup-postgres.log 2>&1
"

# ── Build logrotate file ───────────────────────────────────────────────────
LOGROTATE_CONTENTS="${LOG_DIR}/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    create 640 root root
}
"

# ── Dry-run: print and exit ────────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  echo ""
  echo "=== install-crontab.sh dry-run ==="
  printf "  Would mkdir -p %s\n\n" "$LOG_DIR"
  printf "  --- %s ---\n" "$CRON_FILE"
  printf '%s' "$CRON_CONTENTS"
  printf "\n  --- %s ---\n" "$LOGROTATE_FILE"
  printf '%s' "$LOGROTATE_CONTENTS"
  echo "==================================="
  log info "dry-run complete scripts_dir=${SCRIPT_DIR}"
  exit 0
fi

# ── Create log directory ───────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
chmod 750 "$LOG_DIR"
log info "log dir ready: $LOG_DIR"

# ── Write cron file ────────────────────────────────────────────────────────
printf '%s' "$CRON_CONTENTS" >"$CRON_FILE"
chmod 644 "$CRON_FILE"
log info "cron file written: $CRON_FILE"

# ── Write logrotate file ───────────────────────────────────────────────────
printf '%s' "$LOGROTATE_CONTENTS" >"$LOGROTATE_FILE"
chmod 644 "$LOGROTATE_FILE"
log info "logrotate file written: $LOGROTATE_FILE"

# ── Verify cron daemon is running ──────────────────────────────────────────
if systemctl is-active --quiet cron 2>/dev/null ||
  systemctl is-active --quiet crond 2>/dev/null; then
  log info "cron daemon active — jobs will run on schedule"
else
  log warn "cron daemon not detected as active; verify: systemctl status cron"
fi

log info "install complete"
log info "verify with: sudo ${SCRIPT_DIR}/daily-summary.sh --dry-run"
exit 0
