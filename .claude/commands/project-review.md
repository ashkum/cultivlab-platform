# /project:review

Self-review the current branch before opening a PR.

## What this command does

Run a structured review of every changed file in the current branch against the project's
engineering standards. This is not a merge gate — it is a quality check you run yourself before
asking for human review.

## Steps

1. **List changed files**

   ```bash
   git diff --name-only main
   ```

2. **Lint checks**

   - Run `pre-commit run --all-files` and report any failures.
   - For `.sh` files: confirm `shellcheck` passes with no warnings.
   - For `.md` files: confirm `prettier --check` passes.

3. **Secret scan**

   ```bash
   gitleaks detect --source . --verbose
   ```

   Report clean or list any findings.

4. **Engineering standards check** — for each changed file, verify:

   - [ ] No hardcoded values (operator domain, real keys, real names)
   - [ ] No magic strings or numbers — named constants used
   - [ ] Error handling is explicit — no silent failures
   - [ ] File is under 300 lines
   - [ ] If a script: `--dry-run` flag is present and works
   - [ ] If a script: idempotent (running twice produces same result)

5. **`.env.example` sync check**

   - List any env vars referenced in changed files.
   - Confirm each one is documented in `.env.example` with a comment.
   - Flag any missing entries as a blocking issue.

6. **`docs/install.md` sync check**

   - If the diff adds a new tool, service, or setup step, confirm `docs/install.md` is updated.

7. **`docs/architecture.md` sync check**

   - If the diff adds a new component or changes a routing decision, confirm `docs/architecture.md`
     reflects the change.

8. **CHANGELOG.md check**

   - Confirm the `[Unreleased]` section has an entry for the change.

9. **Breaking change scan**
   - List any interface changes (env var renames, script flag changes, API changes).
   - Flag if any downstream scripts or docs need updating.

## Output format

Produce a short structured report:

```
## Review: <branch-name>

### Lint        ✓ / ✗ (details)
### Secrets     ✓ clean / ✗ findings
### Standards   ✓ / ✗ (list violations)
### .env.example sync  ✓ / ✗ (missing vars)
### docs sync   ✓ / ✗ (what needs updating)
### CHANGELOG   ✓ / ✗
### Breaking changes  none / <list>

### Summary
<one-paragraph overall assessment and list of blockers before PR>
```
