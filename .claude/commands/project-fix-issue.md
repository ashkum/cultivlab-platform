# /project:fix-issue <issue-number>

Workflow for fetching a GitHub issue, planning the fix, implementing it, and preparing the PR.

## Usage

```
/project:fix-issue 42
```

## Steps

### 1. Fetch the issue

```bash
gh issue view <issue-number> --json title,body,labels,assignees,comments
```

Print the full issue title, body, and any comments. Confirm you understand what is being
asked before proceeding.

### 2. Identify affected files

- List files that are likely affected based on the issue description.
- Read each relevant file before writing any code.
- Check `docs/DECISION_LOG.md` for any ADRs that constrain the solution.

### 3. Plan the fix

State the following before writing any code:

- **What changes:** describe the change in one sentence
- **Files touched:** list every file that will be created or modified
- **Side effects:** any downstream scripts, docs, or configs that need updating
- **New env vars:** any new env vars (will need `.env.example` update)
- **Unclear:** anything ambiguous — stop and ask rather than assume

Wait for operator confirmation if the plan involves more than 3 files or any architectural
decision.

### 4. Implement

- Create a branch: `git checkout -b sprint-N/fix-<issue-number>-short-description`
- Implement the fix following all engineering rules in `CLAUDE.md`
- Commit with: `[sprint-N] fix #<issue-number>: <short description>`

### 5. Self-review

Run `/project:review` on the branch and fix any issues before proceeding.

### 6. Prepare PR

```bash
gh pr create \
  --title "[sprint-N] fix #<issue-number>: <short description>" \
  --body "$(cat <<'PRBODY'
## What changed
<one paragraph>

## Files touched
- file1
- file2

## How to test manually
1. step one
2. step two

## Checklist
- [ ] .env.example updated (if new env vars)
- [ ] docs/install.md updated (if new install steps)
- [ ] docs/architecture.md updated (if new components)
- [ ] CHANGELOG.md [Unreleased] updated
- [ ] pre-commit run --all-files passes
- [ ] gitleaks clean
PRBODY
)"
```
