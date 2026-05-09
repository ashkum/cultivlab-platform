#!/usr/bin/env bash
# session.sh — Build a focused Claude session context and copy it to the clipboard.
#
# Usage:
#   ./session.sh                              # CLAUDE.md + PROJECT_BRIEF.md only
#   ./session.sh scripts/bootstrap.sh         # + one extra file
#   ./session.sh infra/docker-compose.yml \
#                infra/litellm/config.yaml    # + multiple files
#
# Output: clipboard (macOS pbcopy) + token estimate printed to stdout.
#
# Requires: macOS (pbcopy). On Linux, swap pbcopy for xclip or xsel.

set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────────────────
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CLAUDE_MD="${REPO_ROOT}/CLAUDE.md"
readonly PROJECT_BRIEF="${REPO_ROOT}/docs/PROJECT_BRIEF.md"

# Characters per token (conservative estimate for Claude / GPT tokenisers).
readonly CHARS_PER_TOKEN=4

# ── Helpers ───────────────────────────────────────────────────────────────────

# wrap_file <display_path> <absolute_path>
# Appends the file content inside XML-style tags to CONTEXT.
wrap_file() {
  local display_path="$1"
  local abs_path="$2"

  if [[ ! -f "${abs_path}" ]]; then
    echo "WARNING: file not found, skipping: ${display_path}" >&2
    return
  fi

  CONTEXT+="<file path=\"${display_path}\">"$'\n'
  CONTEXT+="$(cat "${abs_path}")"$'\n'
  CONTEXT+="</file>"$'\n\n'
}

# estimate_tokens <string>
# Prints a rough token count based on character length.
estimate_tokens() {
  local chars
  chars=$(printf '%s' "$1" | wc -c | tr -d ' ')
  echo $(( chars / CHARS_PER_TOKEN ))
}

# ── Build context ──────────────────────────────────────────────────────────────
CONTEXT=""

# Always-included: CLAUDE.md
wrap_file "CLAUDE.md" "${CLAUDE_MD}"

# Always-included: PROJECT_BRIEF.md
wrap_file "docs/PROJECT_BRIEF.md" "${PROJECT_BRIEF}"

# Additional files passed as arguments
EXTRA_COUNT=0
for ARG in "$@"; do
  # Resolve relative paths from repo root
  if [[ "${ARG}" == /* ]]; then
    ABS_PATH="${ARG}"
    DISPLAY_PATH="${ARG}"
  else
    ABS_PATH="${REPO_ROOT}/${ARG}"
    DISPLAY_PATH="${ARG}"
  fi

  wrap_file "${DISPLAY_PATH}" "${ABS_PATH}"
  (( EXTRA_COUNT++ )) || true
done

# ── Copy to clipboard ─────────────────────────────────────────────────────────
if ! command -v pbcopy &>/dev/null; then
  echo "ERROR: pbcopy not found. This script requires macOS." >&2
  echo "       On Linux, replace 'pbcopy' with 'xclip -selection clipboard' or 'xsel --clipboard'." >&2
  exit 1
fi

printf '%s' "${CONTEXT}" | pbcopy

# ── Report ────────────────────────────────────────────────────────────────────
TOKEN_EST=$(estimate_tokens "${CONTEXT}")
CHAR_COUNT=$(printf '%s' "${CONTEXT}" | wc -c | tr -d ' ')

echo ""
echo "✓  Context copied to clipboard"
echo "   Always included : CLAUDE.md, docs/PROJECT_BRIEF.md"
if [[ ${EXTRA_COUNT} -gt 0 ]]; then
  echo "   Extra files     : ${EXTRA_COUNT} file(s)"
fi
echo "   Characters      : ${CHAR_COUNT}"
echo "   Estimated tokens: ~${TOKEN_EST}  (${CHARS_PER_TOKEN} chars/token)"
echo ""
echo "Paste at the start of your Claude session."
echo ""
