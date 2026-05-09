# CultivLab — Operations Runbook

**Status:** Skeleton — sections filled in sprint by sprint.
For incident-specific procedures, see `docs/runbooks/`.

---

## Daily operations (during cohort)

_Filled in Sprint 5._

Morning check (5 min): Founder Console dashboard review, Slack channel scan, budget status.
Evening check (5 min): daily spend report review, budget adjustments if needed.

---

## Weekly operations

_Filled in Sprint 5._

Weekly tasks: `docs/PROJECT_BRIEF.md` update, `decision-gate.md` signal review,
incident log review, Postgres backup verification.

---

## Backup

_Filled in Sprint 5._

Daily automated Postgres dump to GCS. Retention policy. How to verify a backup is valid.
VM snapshot procedure before risky operations (`scripts/snapshot-vm.sh`).

---

## Restore

_Filled in Sprint 5. Full procedure in `docs/runbooks/restore.md`._

How to restore Postgres from a GCS dump. How to restore the VM from a snapshot.
Estimated recovery time. How to verify restoration was successful.

---

## Container management

_Filled in Sprint 1._

Starting, stopping, and restarting individual containers. Viewing logs. Checking container
health. Upgrading a single container to a new pinned version.

```bash
# Common commands (filled in Sprint 1)
# docker compose ps
# docker compose logs -f litellm
# docker compose restart caddy
# docker compose pull && docker compose up -d
```

---

## Upgrading the stack

_Filled in Sprint 1 (procedure), updated each sprint._

How to upgrade container versions: update the version env var in `.env`, pull new image,
restart the affected container, verify health. Rollback procedure if upgrade fails.

---

## Cohort start checklist

_Filled in Sprint 6._

Pre-cohort steps: fresh VM snapshot, verify all 12 student keys, verify all 12 sites deploy,
verify Slack alerts fire, verify daily summary delivers, verify console loads on mobile.

---

## Cohort end checklist

_Filled in Sprint 3 (scripts), Sprint 6 (full procedure)._

Running `scripts/cohort-status.sh`, taking a final snapshot, running
`scripts/cohort-cleanup.sh --dry-run` then for real, archiving demo day artifacts.

---

## Incident response

_Filled in Sprint 6. Full flowchart in `docs/runbooks/incident-response.md`._

Decision tree: provider down → VM down → student abuse → cost spike. Each branch with
step-by-step resolution and escalation path.

---

## Cost review

_Filled in Sprint 5._

Monthly top-5 cost line item review. GCP billing console walkthrough. LiteLLM spend report
interpretation. When to investigate vs. when cost is expected.
