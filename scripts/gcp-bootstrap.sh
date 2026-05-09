#!/usr/bin/env bash
# scripts/gcp-bootstrap.sh
#
# Mac-side: create all GCP infrastructure for CultivLab. Idempotent.
# Re-running produces no errors and no duplicate resources.
#
# Steps:
#   1. Verify gcloud auth + project access
#   2. Enable required APIs
#   3. Create static external IP
#   4. Create VM service account
#   5. Grant roles/aiplatform.user to the SA (Vertex AI access)
#   6. Create firewall rule for HTTP/HTTPS
#   7. Create the VM with the SA and static IP attached
#   8. Print summary with VM IP and next steps
#
# Note on step ordering: the original brief listed VM creation before service
# account creation, but attaching an SA to a running VM requires the VM to be
# stopped. Creating the SA first lets us attach it at VM-create time via the
# --service-account flag, which is re-run-safe. End state is identical.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/gcp-bootstrap.sh [--dry-run] [--help]

Creates all CultivLab GCP infrastructure (idempotent).

Reads from .env (or current shell):
  GCP_PROJECT_ID, GCP_REGION, GCP_ZONE, VM_NAME, VM_MACHINE_TYPE,
  VM_DISK_SIZE_GB, STATIC_IP_NAME, DOMAIN

Flags:
  --dry-run   Log every gcloud command; make zero changes.
  --help, -h  Print this message and exit.
USAGE
}

parse_common_args "$@"
if [[ "${CULTIVLAB_HELP:-0}" == "1" ]]; then
  usage
  exit 0
fi

# Auto-load .env from repo root if it exists. Operator may also pre-export.
ENV_FILE="${SCRIPT_DIR}/../.env"
if [[ -f "${ENV_FILE}" ]]; then
  log_info "loading env from ${ENV_FILE}"
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

require_env \
  GCP_PROJECT_ID GCP_REGION GCP_ZONE \
  VM_NAME VM_MACHINE_TYPE VM_DISK_SIZE_GB \
  STATIC_IP_NAME DOMAIN

# Constants — not env-configurable. Keeps drift between code and docs minimal.
readonly VM_SA_ACCOUNT_ID="cultivlab-vm"
readonly VM_SA_EMAIL="${VM_SA_ACCOUNT_ID}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
readonly FW_RULE_NAME="cultivlab-allow-http-https"
readonly NETWORK_TAG="cultivlab-http"
readonly UBUNTU_IMAGE_FAMILY="ubuntu-2404-lts-amd64"
readonly UBUNTU_IMAGE_PROJECT="ubuntu-os-cloud"

# ----------------------------------------------------------------------------
# Step 1 — gcloud auth + project verification
# ----------------------------------------------------------------------------
verify_gcloud() {
  log_info "step 1/8: verifying gcloud authentication and project access"

  if ! command -v gcloud >/dev/null 2>&1; then
    log_error "gcloud CLI not found. install from https://cloud.google.com/sdk/docs/install"
    exit 1
  fi

  local active_account
  active_account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)"
  if [[ -z "${active_account}" ]]; then
    log_error "no active gcloud account. run: gcloud auth login"
    exit 1
  fi
  log_info "active gcloud account: ${active_account}"

  if ! gcloud projects describe "${GCP_PROJECT_ID}" >/dev/null 2>&1; then
    log_error "project ${GCP_PROJECT_ID} not found or not accessible by ${active_account}"
    exit 1
  fi
  log_info "verified project: ${GCP_PROJECT_ID}"
}

# ----------------------------------------------------------------------------
# Step 2 — Enable required APIs (idempotent: enable is a no-op if already on)
# ----------------------------------------------------------------------------
enable_apis() {
  log_info "step 2/8: enabling required APIs"
  local apis=(
    compute.googleapis.com
    iam.googleapis.com
    cloudresourcemanager.googleapis.com
    iap.googleapis.com
  )
  local api
  for api in "${apis[@]}"; do
    run_or_dry gcloud services enable "${api}" --project="${GCP_PROJECT_ID}"
  done
}

# ----------------------------------------------------------------------------
# Step 3 — Static external IP
# ----------------------------------------------------------------------------
create_static_ip() {
  log_info "step 3/8: ensuring static external IP ${STATIC_IP_NAME} exists"
  if gcloud compute addresses describe "${STATIC_IP_NAME}" \
    --region="${GCP_REGION}" \
    --project="${GCP_PROJECT_ID}" >/dev/null 2>&1; then
    log_info "static IP ${STATIC_IP_NAME} already exists; skipping"
    return 0
  fi
  run_or_dry gcloud compute addresses create "${STATIC_IP_NAME}" \
    --region="${GCP_REGION}" \
    --project="${GCP_PROJECT_ID}"
}

# ----------------------------------------------------------------------------
# Step 4 — VM service account
# ----------------------------------------------------------------------------
create_service_account() {
  log_info "step 4/8: ensuring service account ${VM_SA_EMAIL} exists"
  if gcloud iam service-accounts describe "${VM_SA_EMAIL}" \
    --project="${GCP_PROJECT_ID}" >/dev/null 2>&1; then
    log_info "service account already exists; skipping"
    return 0
  fi
  run_or_dry gcloud iam service-accounts create "${VM_SA_ACCOUNT_ID}" \
    --display-name="CultivLab VM" \
    --description="Attached to the CultivLab VM; used for Vertex AI access via ADC" \
    --project="${GCP_PROJECT_ID}"
}

# ----------------------------------------------------------------------------
# Step 5 — Grant Vertex AI role to SA
# add-iam-policy-binding is idempotent: re-binding the same role is a no-op.
# ----------------------------------------------------------------------------
grant_vertex_role() {
  log_info "step 5/8: granting roles/aiplatform.user to ${VM_SA_EMAIL}"
  run_or_dry gcloud projects add-iam-policy-binding "${GCP_PROJECT_ID}" \
    --member="serviceAccount:${VM_SA_EMAIL}" \
    --role="roles/aiplatform.user" \
    --condition=None
}

# ----------------------------------------------------------------------------
# Step 6 — Firewall rule for HTTP/HTTPS, scoped to a network tag
# ----------------------------------------------------------------------------
create_firewall_rule() {
  log_info "step 6/8: ensuring firewall rule ${FW_RULE_NAME} exists"
  if gcloud compute firewall-rules describe "${FW_RULE_NAME}" \
    --project="${GCP_PROJECT_ID}" >/dev/null 2>&1; then
    log_info "firewall rule already exists; skipping"
    return 0
  fi
  run_or_dry gcloud compute firewall-rules create "${FW_RULE_NAME}" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:80,tcp:443 \
    --source-ranges=0.0.0.0/0 \
    --target-tags="${NETWORK_TAG}" \
    --project="${GCP_PROJECT_ID}"
}

# ----------------------------------------------------------------------------
# Step 7 — VM with SA, static IP, and network tag attached
# ----------------------------------------------------------------------------
create_vm() {
  log_info "step 7/8: ensuring VM ${VM_NAME} exists"
  if gcloud compute instances describe "${VM_NAME}" \
    --zone="${GCP_ZONE}" \
    --project="${GCP_PROJECT_ID}" >/dev/null 2>&1; then
    log_info "VM ${VM_NAME} already exists; skipping"
    return 0
  fi
  run_or_dry gcloud compute instances create "${VM_NAME}" \
    --zone="${GCP_ZONE}" \
    --machine-type="${VM_MACHINE_TYPE}" \
    --image-family="${UBUNTU_IMAGE_FAMILY}" \
    --image-project="${UBUNTU_IMAGE_PROJECT}" \
    --boot-disk-size="${VM_DISK_SIZE_GB}GB" \
    --address="${STATIC_IP_NAME}" \
    --service-account="${VM_SA_EMAIL}" \
    --scopes=cloud-platform \
    --tags="${NETWORK_TAG}" \
    --metadata=enable-oslogin=TRUE \
    --project="${GCP_PROJECT_ID}"
}

# ----------------------------------------------------------------------------
# Step 8 — Print VM IP and next steps
# ----------------------------------------------------------------------------
print_summary() {
  log_info "step 8/8: bootstrap complete"

  if is_dry_run; then
    log_info "dry-run mode: no resources were created. re-run without --dry-run to apply."
    return 0
  fi

  local vm_ip
  vm_ip="$(gcloud compute instances describe "${VM_NAME}" \
    --zone="${GCP_ZONE}" \
    --project="${GCP_PROJECT_ID}" \
    --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || true)"

  log_info "VM external IP: ${vm_ip:-unknown}"
  log_info "next steps (in order):"
  log_info "  1) at your DNS registrar, add A records:"
  log_info "       api.${DOMAIN}    A    ${vm_ip:-<VM_IP>}"
  log_info "       admin.${DOMAIN}  A    ${vm_ip:-<VM_IP>}"
  log_info "  2) verify DNS propagation: dig +short api.${DOMAIN}"
  log_info "  3) ensure your account has roles/iap.tunnelAccessor and roles/compute.osLogin on the project"
  log_info "  4) SSH via IAP:"
  log_info "       gcloud compute ssh ${VM_NAME} --tunnel-through-iap --zone ${GCP_ZONE} --project ${GCP_PROJECT_ID}"
  log_info "  5) on the VM: copy .env to /home/<user>/cultivlab/.env then run scripts/bootstrap.sh"
}

main() {
  if is_dry_run; then
    log_info "DRY-RUN: no GCP resources will be created"
  fi
  verify_gcloud
  enable_apis
  create_static_ip
  create_service_account
  grant_vertex_role
  create_firewall_rule
  create_vm
  print_summary
}

main "$@"
