#!/usr/bin/env bash
# PreToolUse hook — block writes to .env, secrets/, and .git/.
#
# Called by Claude Code before any Write or Edit tool use.
# Reads tool input as JSON from stdin.
# Exit 0 = allow. Exit 1 = block (message shown to Claude).

set -euo pipefail

INPUT=$(cat)

FILE_PATH=$(echo "${INPUT}" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('file_path', d.get('path', '')))
except Exception:
    print('')
" 2>/dev/null || echo "")

if [[ -z "${FILE_PATH}" ]]; then
  exit 0
fi

BLOCKED_PATTERNS=(
  '(^|/)\.env$'
  '(^|/)\.env\.'
  '(^|/)\.env\.local'
  '(^|/)secrets/'
  '(^|/)\.git/'
)

for PATTERN in "${BLOCKED_PATTERNS[@]}"; do
  if echo "${FILE_PATH}" | grep -qE "${PATTERN}"; then
    echo "BLOCKED: Claude Code may not write to '${FILE_PATH}'." >&2
    echo "  .env, .env.local, secrets/, and .git/ must be edited manually by the operator." >&2
    exit 1
  fi
done

exit 0
