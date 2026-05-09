#!/usr/bin/env bash
# PostToolUse hook — auto-format edited files.
#
# .md files  → prettier
# .sh files  → shfmt -w
#
# Runs silently on success. Warnings go to stderr but do not fail.

set -uo pipefail

INPUT=$(cat)

FILE_PATH=$(echo "${INPUT}" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    # PostToolUse wraps input under tool_input key
    ti = d.get('tool_input', d)
    print(ti.get('file_path', ti.get('path', '')))
except Exception:
    print('')
" 2>/dev/null || echo "")

if [[ -z "${FILE_PATH}" ]]; then
  exit 0
fi

if [[ "${FILE_PATH}" == *.md ]]; then
  if command -v prettier &>/dev/null; then
    prettier --write "${FILE_PATH}" --prose-wrap always --print-width 100 2>/dev/null || true
  fi
elif [[ "${FILE_PATH}" == *.sh ]]; then
  if command -v shfmt &>/dev/null; then
    shfmt -w -i 2 -ci "${FILE_PATH}" 2>/dev/null || true
  fi
fi

exit 0
