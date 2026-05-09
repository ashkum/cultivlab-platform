# /project:deploy

Pre-deploy checklist and smoke test. Real deployment is not available until Sprint 1+.

## Current state (Sprint 0)

No infrastructure exists yet. Running this command produces the pre-deploy checklist only.
Actual deployment steps are added sprint by sprint as infrastructure is built.

---

## Pre-deploy checklist (run before every deployment)

### Repository state
- [ ] All changes committed and pushed
- [ ] CI passes on the current branch (lint + secrets)
- [ ] `pre-commit run --all-files` clean locally
- [ ] `gitleaks detect --source . --verbose` returns no findings
- [ ] `CHANGELOG.md` [Unreleased] section is up to date

### Configuration
- [ ] `.env` on the VM has all REQUIRED vars from `.env.example`
- [ ] No placeholder values remain in `.env` (search for "placeholder")
- [ ] Provider API keys verified (quick curl test to each)
- [ ] Slack webhooks verified (send a test message to each channel)
- [ ] `FOUNDER_ALLOWED_IP` is set to your current IP

### Pre-deployment snapshot (Sprint 1+)
```bash
# Take a VM snapshot before any risky deployment
# ./scripts/snapshot-vm.sh "pre-deploy-$(date +%Y%m%d-%H%M)"
```

---

## Smoke tests (Sprint 1+)

These are placeholders. Each sprint adds real assertions.

```bash
# Sprint 1: verify HTTPS and LiteLLM health
# curl -sf https://api.${DOMAIN}/health | jq .

# Sprint 2: verify all three providers respond
# curl -sf https://api.${DOMAIN}/v1/models | jq '.data[].id'

# Sprint 3: verify Open WebUI loads
# curl -sf -o /dev/null -w "%{http_code}" https://chat.${DOMAIN}

# Sprint 4: verify a student site loads
# curl -sf -o /dev/null -w "%{http_code}" https://test-student.${DOMAIN}

# Sprint 5.5: verify Founder Console loads
# curl -sf -o /dev/null -w "%{http_code}" https://founder.${DOMAIN}
```

---

## Post-deploy verification

- [ ] All health endpoints return 200
- [ ] Caddy logs show no certificate errors
- [ ] LiteLLM admin UI loads at `https://admin.${DOMAIN}`
- [ ] Founder Console loads at `https://founder.${DOMAIN}` (Sprint 5.5+)
- [ ] One test LLM call succeeds end-to-end
- [ ] Slack alert channels receive a test ping

## Rollback procedure (Sprint 1+)

```bash
# If something goes wrong, restore the pre-deploy VM snapshot:
# gcloud compute instances stop ${VM_NAME} --zone=${GCP_ZONE}
# gcloud compute disks create restore-disk --source-snapshot=pre-deploy-YYYYMMDD-HHMM
# (see docs/runbooks/restore.md for full steps)
```
