#!/usr/bin/env bash
# scripts/bootstrap.sh
#
# VM-side: bring up the CultivLab core stack. Idempotent.
# Run from the repository root via SSH after DNS is pointed at the VM IP.
#
#   sudo bash scripts/bootstrap.sh           # apply
#   sudo bash scripts/bootstrap.sh --dry-run # preview
#
# Steps:
#   1. Validate env vars
#   2. Install Docker + Compose plugin if missing (Ubuntu 24.04)
#   3. Stage /opt/cultivlab/infra (from local clone or git REPO_URL)
#   4. Render Caddyfile from Caddyfile.tmpl via envsubst
#   5. docker compose pull
#   6. docker compose up -d
#   7. Wait up to 60s for LiteLLM container to become healthy
#   8. Self-test: curl https://api.${DOMAIN}/health/liveliness, assert 200
#   9. Print summary

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

readonly INSTALL_DIR="/opt/cultivlab"
readonly WORK_DIR="${INSTALL_DIR}/infra"
readonly ENV_TARGET="${INSTALL_DIR}/.env"
readonly LITELLM_HEALTH_TIMEOUT_SEC=60
readonly LITELLM_HEALTH_INTERVAL_SEC=3

usage() {
  cat <<'USAGE'
Usage: sudo bash scripts/bootstrap.sh [--dry-run] [--help]

Brings up the CultivLab core stack on a VM. Idempotent.

Reads from the .env at the repo root (or current shell):
  DOMAIN, FOUNDER_ADMIN_EMAIL, FOUNDER_ALLOWED_IP,
  LITELLM_MASTER_KEY, LITELLM_SALT_KEY,
  POSTGRES_PASSWORD, POSTGRES_DB, POSTGRES_USER,
  ANTHROPIC_API_KEY, OPENAI_API_KEY,
  VERTEX_AI_PROJECT, VERTEX_AI_LOCATION,
  SLACK_WEBHOOK_BUDGET, SLACK_WEBHOOK_REPORTS,
  SLACK_WEBHOOK_EXCEPTIONS, SLACK_WEBHOOK_SAFETY, SLACK_WEBHOOK_PLATFORM,
  CADDY_VERSION, LITELLM_VERSION, POSTGRES_VERSION

Optional:
  REPO_URL    If set, git clone/pull this URL into /opt/cultivlab/repo
              and stage from there. Otherwise stages from the local repo.

Flags:
  --dry-run   Log every command; make zero changes.
  --help, -h  Print this message and exit.
USAGE
}

parse_common_args "$@"
if [[ "${CULTIVLAB_HELP:-0}" == "1" ]]; then
  usage
  exit 0
fi

# Auto-load .env from repo root if it exists.
ENV_FILE="${REPO_ROOT}/.env"
if [[ -f "${ENV_FILE}" ]]; then
  log_info "loading env from ${ENV_FILE}"
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

require_env \
  DOMAIN FOUNDER_ADMIN_EMAIL FOUNDER_ALLOWED_IP \
  LITELLM_MASTER_KEY LITELLM_SALT_KEY \
  POSTGRES_PASSWORD POSTGRES_DB POSTGRES_USER \
  ANTHROPIC_API_KEY OPENAI_API_KEY \
  VERTEX_AI_PROJECT VERTEX_AI_LOCATION \
  SLACK_WEBHOOK_BUDGET SLACK_WEBHOOK_REPORTS SLACK_WEBHOOK_EXCEPTIONS \
  SLACK_WEBHOOK_SAFETY SLACK_WEBHOOK_PLATFORM \
  CADDY_VERSION LITELLM_VERSION POSTGRES_VERSION

# ----------------------------------------------------------------------------
# Privilege check — needed for /opt, apt, docker socket.
# In dry-run we skip the EUID check since no real changes happen.
# ----------------------------------------------------------------------------
if ! is_dry_run; then
  if [[ "${EUID}" -ne 0 ]]; then
    log_error "must be run as root (sudo bash scripts/bootstrap.sh) to manage /opt and docker"
    exit 1
  fi
fi

# ----------------------------------------------------------------------------
# Step 2: Docker + Compose plugin
# ----------------------------------------------------------------------------
install_docker_if_missing() {
  log_info "step 2/9: ensuring Docker and Compose plugin are installed"
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log_info "docker and compose plugin already present; skipping install"
    return 0
  fi
  log_info "docker not found; installing via get.docker.com"
  run_or_dry bash -c 'curl -fsSL https://get.docker.com | sh'
  run_or_dry systemctl enable --now docker
}

# ----------------------------------------------------------------------------
# Step 3: Stage infra/ into /opt/cultivlab/infra
# ----------------------------------------------------------------------------
stage_install_dir() {
  log_info "step 3/9: staging ${WORK_DIR}"
  run_or_dry mkdir -p "${INSTALL_DIR}"

  local source_infra
  if [[ -n "${REPO_URL:-}" ]]; then
    local repo_dir="${INSTALL_DIR}/repo"
    if [[ -d "${repo_dir}/.git" ]]; then
      log_info "repo already cloned; pulling latest from ${REPO_URL}"
      run_or_dry git -C "${repo_dir}" pull --ff-only
    else
      log_info "git cloning ${REPO_URL} into ${repo_dir}"
      run_or_dry git clone "${REPO_URL}" "${repo_dir}"
    fi
    source_infra="${repo_dir}/infra"
  else
    source_infra="${REPO_ROOT}/infra"
  fi

  if ! is_dry_run && [[ ! -d "${source_infra}" ]]; then
    log_error "source infra dir not found: ${source_infra}"
    exit 1
  fi

  # cp -R is idempotent in result; -T-equivalent via trailing slash + dir.
  run_or_dry rm -rf "${WORK_DIR}"
  run_or_dry cp -R "${source_infra}" "${WORK_DIR}"

  # Place .env at /opt/cultivlab/.env so docker compose --env-file finds it.
  if [[ -f "${ENV_FILE}" ]]; then
    run_or_dry cp "${ENV_FILE}" "${ENV_TARGET}"
    run_or_dry chmod 600 "${ENV_TARGET}"
  else
    log_warn ".env not found at ${ENV_FILE}; relying on shell env for compose"
  fi
}

# ----------------------------------------------------------------------------
# Step 4: Render Caddyfile from template
#
# FOUNDER_ALLOWED_IP may be comma-separated in .env (per .env.example example).
# Caddy's remote_ip matcher uses space separation, so we normalize before
# envsubst. envsubst doesn't expand vars not in its allowlist — pass them all.
# ----------------------------------------------------------------------------
render_caddyfile() {
  log_info "step 4/9: rendering ${WORK_DIR}/Caddyfile from Caddyfile.tmpl"
  if ! command -v envsubst >/dev/null 2>&1; then
    log_info "envsubst missing; installing gettext-base"
    run_or_dry apt-get update
    run_or_dry apt-get install -y gettext-base
  fi
  # Normalize commas → spaces inside FOUNDER_ALLOWED_IP for Caddy syntax.
  local normalized_ip="${FOUNDER_ALLOWED_IP//,/ }"
  if is_dry_run; then
    log_info "would render Caddyfile (FOUNDER_ALLOWED_IP normalized to: ${normalized_ip})"
    return 0
  fi
  FOUNDER_ALLOWED_IP="${normalized_ip}" \
    envsubst '${DOMAIN} ${FOUNDER_ADMIN_EMAIL} ${FOUNDER_ALLOWED_IP}' \
    <"${WORK_DIR}/Caddyfile.tmpl" \
    >"${WORK_DIR}/Caddyfile"
  log_info "Caddyfile rendered ($(wc -l <"${WORK_DIR}/Caddyfile") lines)"
}

# ----------------------------------------------------------------------------
# Step 5: docker compose pull
# ----------------------------------------------------------------------------
compose_pull() {
  log_info "step 5/9: docker compose pull"
  run_or_dry docker compose --env-file "${ENV_TARGET}" \
    -f "${WORK_DIR}/docker-compose.yml" pull
}

# ----------------------------------------------------------------------------
# Step 6: docker compose up -d
# ----------------------------------------------------------------------------
compose_up() {
  log_info "step 6/9: docker compose up -d"
  run_or_dry docker compose --env-file "${ENV_TARGET}" \
    -f "${WORK_DIR}/docker-compose.yml" up -d
}

# ----------------------------------------------------------------------------
# Step 7: Wait for LiteLLM container health
# Polls /health/liveliness from inside the container — no DNS/TLS dependency.
# ----------------------------------------------------------------------------
wait_for_litellm_health() {
  log_info "step 7/9: waiting for LiteLLM health (max ${LITELLM_HEALTH_TIMEOUT_SEC}s)"
  if is_dry_run; then
    log_info "dry-run: would poll docker compose exec litellm curl /health/liveliness"
    return 0
  fi
  local attempts=$((LITELLM_HEALTH_TIMEOUT_SEC / LITELLM_HEALTH_INTERVAL_SEC))
  local i
  for ((i = 1; i <= attempts; i++)); do
    if docker compose --env-file "${ENV_TARGET}" \
      -f "${WORK_DIR}/docker-compose.yml" \
      exec -T litellm curl -fsS http://localhost:4000/health/liveliness \
      >/dev/null 2>&1; then
      log_info "litellm healthy (attempt ${i}/${attempts})"
      return 0
    fi
    sleep "${LITELLM_HEALTH_INTERVAL_SEC}"
  done
  log_error "litellm did not become healthy within ${LITELLM_HEALTH_TIMEOUT_SEC}s"
  log_error "inspect: docker compose -f ${WORK_DIR}/docker-compose.yml logs litellm"
  exit 1
}

# ----------------------------------------------------------------------------
# Step 8: Public self-test through Caddy
# ----------------------------------------------------------------------------
self_test_public() {
  log_info "step 8/9: self-test https://api.${DOMAIN}/health/liveliness"
  if is_dry_run; then
    log_info "dry-run: would curl https://api.${DOMAIN}/health/liveliness"
    return 0
  fi
  # First HTTPS request triggers Let's Encrypt cert issuance — give it room.
  local attempts=10
  local i
  for ((i = 1; i <= attempts; i++)); do
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' \
      "https://api.${DOMAIN}/health/liveliness" || echo "000")"
    if [[ "${code}" == "200" ]]; then
      log_info "self-test passed (HTTP 200) on attempt ${i}/${attempts}"
      return 0
    fi
    log_info "self-test attempt ${i}/${attempts}: HTTP ${code} (caddy may still be issuing certs)"
    sleep 6
  done
  log_error "self-test failed after ${attempts} attempts"
  exit 1
}

# ----------------------------------------------------------------------------
# Step 9: Summary
# ----------------------------------------------------------------------------
print_summary() {
  log_info "step 9/9: bootstrap complete"
  if is_dry_run; then
    log_info "dry-run: no real changes were made"
    return 0
  fi
  log_info "service URLs:"
  log_info "  api:   https://api.${DOMAIN}/"
  log_info "  admin: https://admin.${DOMAIN}/   (allowed from: ${FOUNDER_ALLOWED_IP})"
  log_info "next:"
  log_info "  list models:  curl -H \"Authorization: Bearer \$LITELLM_MASTER_KEY\" https://api.${DOMAIN}/v1/models"
  log_info "  view logs:    docker compose -f ${WORK_DIR}/docker-compose.yml logs -f"
}

main() {
  if is_dry_run; then
    log_info "DRY-RUN: no real changes will be made"
  fi
  log_info "step 1/9: env validation passed"
  install_docker_if_missing
  stage_install_dir
  render_caddyfile
  compose_pull
  compose_up
  wait_for_litellm_health
  self_test_public
  print_summary
}

main "$@"
