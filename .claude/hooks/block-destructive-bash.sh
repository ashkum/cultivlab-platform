#!/usr/bin/env bash
# PreToolUse hook — block destructive bash commands unless --dry-run is present.
#
# Patterns blocked: rm -rf /, dropdb, gcloud projects delete, DROP DATABASE.
# Exception: if the command string contains --dry-run, allow it through.
# Exit 0 = allow. Exit 1 = block.

set -euo pipefail

INPUT=$(cat)

COMMAND=$(echo "${INPUT}" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('command', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")

if [[ -z "${COMMAND}" ]]; then
  exit 0
fi

# Allow if --dry-run is present anywhere in the command.
if echo "${COMMAND}" | grep -q -- '--dry-run'; then
  exit 0
fi

DESTRUCTIVE_PATTERNS=(
  'rm -rf /'
  'rm -rf \*'
  'dropdb\b'
  'gcloud projects delete'
  'DROP DATABASE'
  'TRUNCATE.*--all'
  'firebase projects:delete'
)

for PATTERN in "${DESTRUCTIVE_PATTERNS[@]}"; do
  if echo "${COMMAND}" | grep -qiE "${PATTERN}"; then
    echo "BLOCKED: Destructive command detected: ${PATTERN}" >&2
    echo "  Add --dry-run to preview the operation, or confirm intent explicitly in chat." >&2
    exit 1
  fi
done

exit 0
