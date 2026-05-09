#!/usr/bin/env bash
# smoke-test.sh — Smoke test for the CultivLab platform.
#
# Sprint 0: placeholder only. Real assertions added in Sprint 1.
#
# Usage:
#   ./tests/smoke/smoke-test.sh
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed
#
# Environment:
#   DOMAIN — required in Sprint 1+; not used in Sprint 0 placeholder

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Colour

pass() { echo -e "${GREEN}✓${NC}  $1"; }
fail() { echo -e "${RED}✗${NC}  $1"; FAILED=$((FAILED + 1)); }
skip() { echo -e "${YELLOW}—${NC}  $1 (not yet implemented)"; }

FAILED=0

echo ""
echo "CultivLab smoke tests"
echo "====================="
echo ""

# ── Sprint 0 checks (scaffold only) ──────────────────────────────────────────

# Verify required repo files exist
for FILE in \
  "README.md" \
  "CLAUDE.md" \
  ".env.example" \
  "LICENSE" \
  "CONTRIBUTING.md" \
  "CHANGELOG.md" \
  ".gitignore" \
  ".pre-commit-config.yaml" \
  "session.sh" \
  "docs/PROJECT_BRIEF.md" \
  "docs/DECISION_LOG.md" \
  "docs/architecture.md" \
  "docs/install.md" \
  "docs/operations.md" \
  "docs/student-onboarding.md" \
  "docs/security.md" \
  ".claude/settings.json" \
  ".github/workflows/lint.yml" \
  ".github/workflows/secrets.yml"; do
  if [[ -f "${FILE}" ]]; then
    pass "File exists: ${FILE}"
  else
    fail "Missing file: ${FILE}"
  fi
done

# Verify session.sh is executable
if [[ -x "session.sh" ]]; then
  pass "session.sh is executable"
else
  fail "session.sh is not executable (run: chmod +x session.sh)"
fi

# Verify CLAUDE.md is under 200 lines
CLAUDE_LINES=$(wc -l < "CLAUDE.md")
if [[ "${CLAUDE_LINES}" -le 200 ]]; then
  pass "CLAUDE.md is ${CLAUDE_LINES} lines (≤ 200)"
else
  fail "CLAUDE.md is ${CLAUDE_LINES} lines (must be ≤ 200)"
fi

# Verify all 10 ADRs are present in DECISION_LOG.md
for ADR_NUM in 001 002 003 004 005 006 007 008 009 010; do
  if grep -q "ADR-${ADR_NUM}" "docs/DECISION_LOG.md"; then
    pass "ADR-${ADR_NUM} present in DECISION_LOG.md"
  else
    fail "ADR-${ADR_NUM} missing from DECISION_LOG.md"
  fi
done

# Verify no hardcoded operator domain in scripts/config files.
# Docs and this test file itself are excluded — they reference the domain as examples.
# The pattern is split so this file does not match its own grep.
DOMAIN_PATTERN="cultivlab"
DOMAIN_SUFFIX=".com"
HARDCODED=$(grep -rl "${DOMAIN_PATTERN}${DOMAIN_SUFFIX}" \
  --include='*.sh' --include='*.yml' --include='*.yaml' \
  --include='*.json' --include='*.env*' \
  --exclude-dir='.git' \
  --exclude='smoke-test.sh' \
  . 2>/dev/null || true)
if [[ -z "${HARDCODED}" ]]; then
  pass "No hardcoded operator domain in scripts/config files"
else
  fail "Hardcoded operator domain found in: ${HARDCODED}"
fi

# Verify .env is not committed
if git ls-files --error-unmatch .env &>/dev/null 2>&1; then
  fail ".env is tracked by git — remove it immediately"
else
  pass ".env is not tracked by git"
fi

# ── Sprint 1+ checks (placeholder) ───────────────────────────────────────────
skip "DOMAIN env var set and resolves"
skip "https://api.\${DOMAIN}/health returns 200"
skip "https://chat.\${DOMAIN} returns 200"
skip "https://admin.\${DOMAIN} returns 200 (from allowed IP)"
skip "https://founder.\${DOMAIN} returns 200 (from allowed IP)"
skip "All three LLM providers respond via LiteLLM"
skip "Postgres is reachable and accepting connections"
skip "docker compose ps shows all containers healthy"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ "${FAILED}" -eq 0 ]]; then
  echo -e "${GREEN}All checks passed.${NC}"
  exit 0
else
  echo -e "${RED}${FAILED} check(s) failed.${NC}"
  exit 1
fi
