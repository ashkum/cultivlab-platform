# Session Starter Template

Use this template to brief Claude at the start of every task. Copy, fill in the sections, and paste
after the system prompt and project context.

Generate the project context automatically with:

```bash
./session.sh [relevant-file-1] [relevant-file-2]
```

---

## Template

```
## System prompt
<paste contents of docs/CLAUDE_SYSTEM_PROMPT.md>

---

## Project context
<paste output of ./session.sh — includes CLAUDE.md + PROJECT_BRIEF.md + any extra files>

---

## Today's task

**Sprint:** Sprint N
**Task:** <one-sentence description of what needs to be built or fixed>

### Background
<why this task exists; what problem it solves; any relevant decisions already made>

### Acceptance criteria
- [ ] criterion 1 — specific, verifiable
- [ ] criterion 2
- [ ] criterion 3

### Constraints
- <any constraints not already in engineering standards, e.g. "must not require Docker restart">
- <any dependencies that must be in place first>

### Relevant files
<list the key files Claude should read before starting — these are also passed to session.sh>

- infra/docker-compose.yml
- scripts/lib/common.sh
- docs/DECISION_LOG.md (if an ADR is relevant)

### Out of scope
<anything this task explicitly does NOT include, to prevent scope creep>
```

---

## Example (filled in)

```
## System prompt
[contents of docs/CLAUDE_SYSTEM_PROMPT.md]

---

## Project context
[output of ./session.sh scripts/bootstrap.sh infra/docker-compose.yml]

---

## Today's task

**Sprint:** Sprint 1
**Task:** Write an idempotent GCP bootstrap script that creates the VM, static IP, and
firewall rules from env vars.

### Background
We need a reproducible way to provision the GCP infrastructure without Terraform. The script
must run cleanly on a fresh GCP project and be safe to re-run if interrupted.

### Acceptance criteria
- [ ] script accepts --dry-run flag and prints all gcloud commands without running them
- [ ] running the script twice on a live project produces no errors and no duplicates
- [ ] all values (project ID, region, zone, VM name, machine type, disk size) come from env vars
- [ ] structured JSON log line emitted for each action taken
- [ ] script exits non-zero and logs an error if a required env var is missing

### Constraints
- bash only (no Python, no Terraform)
- must work on macOS (developer machine) and Ubuntu 24.04 (CI runner)
- under 300 lines; extract helper functions to scripts/lib/ if needed

### Relevant files
- .env.example (for the list of GCP env vars)
- docs/DECISION_LOG.md (ADR-002: single VM + Docker Compose)
- docs/architecture.md (current state diagram)

### Out of scope
- Docker installation (that's bootstrap.sh, not gcp-bootstrap.sh)
- DNS configuration (operator does that manually at their registrar)
- Firebase setup (Sprint 4)
```
