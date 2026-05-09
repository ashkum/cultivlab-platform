# Contributing

This document covers the development environment, workflow conventions, and commit format for this
project.

---

## Prerequisites

The following tools must be installed on your machine before doing any work on this repo:

- **Docker Desktop** (for the core stack)
- **gcloud CLI** (GCP operations)
- **Firebase CLI** (`firebase-tools`) (student site deployment)
- **GitHub CLI** (`gh`) (PR workflow)
- **pre-commit** (`brew install pre-commit`) (local hooks)
- **gitleaks** (`brew install gitleaks`) (secret scanning)
- **shellcheck** (`brew install shellcheck`) (shell linting)
- **shfmt** (`brew install shfmt`) (shell formatting)
- **Prettier** (`npm install -g prettier`) (markdown formatting)
- **Python 3.11+** (for services introduced in later sprints)
- **Node 20+** (for tooling only; no Node services in this repo)

---

## First-time setup

```bash
# 1. Clone the repo
git clone <repo-url>
cd cultivlab-platform

# 2. Install pre-commit hooks
pre-commit install

# 3. Copy env template
cp .env.example .env
# Edit .env — fill in REQUIRED values before running anything

# 4. Verify hooks pass on current state
pre-commit run --all-files
```

---

## Branch naming

```
sprint-0/description-of-change
sprint-1/feature-or-fix-name
fix/short-description
chore/what-youre-doing
```

One branch per logical change. Branches are short-lived — merged and deleted after PR approval.

---

## Commit message format

Every commit message **must** begin with a sprint prefix:

```
[sprint-0] short imperative description

Optional longer body. Explain *why*, not *what*.
Wrap at 72 characters.

Refs: #issue-number (if applicable)
```

Examples:

```
[sprint-0] add .env.example with all 7-sprint variables
[sprint-1] add idempotent VM bootstrap script
[sprint-1] fix Caddyfile not picking up DOMAIN env var
```

Rules:

- Imperative mood in the subject line ("add", not "added" or "adds")
- No period at the end of the subject line
- Subject line under 72 characters
- Reference issues where relevant

---

## Pull request conventions

- PRs are the unit of review — no direct pushes to `main`
- PR title follows the same format as a commit message
- PR description must include:
  - What changed and why
  - Files touched
  - Manual test steps taken
  - Any new env vars added (confirm `.env.example` updated)
  - Any new install steps (confirm `docs/install.md` updated)
- CI must pass before merge

---

## Code standards (binding)

These apply to all code in this repo, regardless of language:

- **No magic strings or numbers** — use named constants and env vars
- **Explicit error handling** — validate inputs, handle failures
- **Idempotent scripts** — running twice must produce the same result, no duplicates
- **Every script must have `--dry-run`** — prints intended actions, makes no changes
- **Files under 300 lines** — if longer, propose a split with justification
- **DRY** — if logic is written twice, extract to a shared function/lib
- **No secrets in code** — env vars only; pre-commit catches leaks
- **New env vars** must be added to `.env.example` in the same commit
- **Structured JSON logging** to stdout from all scripts and services

---

## Self-deployability discipline

Every PR that introduces a structural change must also update:

- `.env.example` — if new env vars were added
- `docs/install.md` — if new install or setup steps were added
- `docs/architecture.md` — if a new component was added

CI will fail if `.env.example` is out of sync. Don't skip these updates.

---

## Running pre-commit manually

```bash
# Run all hooks on all files
pre-commit run --all-files

# Run a specific hook
pre-commit run gitleaks --all-files
pre-commit run shellcheck --all-files
pre-commit run shfmt --all-files
pre-commit run prettier --all-files
```

---

## Questions

Open a GitHub issue with the `question` label, or reach out directly. No question is too small.
