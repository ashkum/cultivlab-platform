# infra/open-webui/

Open WebUI configuration assets for CultivLab.

## Contents

### `functions/`

Python Filter Functions installed into Open WebUI's runtime.

- **`cultivlab_user_injection.py`** — injects the OpenAI `user` field into chat completion requests
  using the logged-in Open WebUI user's identifier. Required for per-student spend attribution. See
  ADR-011 for rationale.

## Installation

Filter Functions are loaded into Open WebUI via the admin panel:

1. Open `https://admin.${DOMAIN}` (or `https://chat.${DOMAIN}` if admin shares the route)
2. Sign in with admin credentials
3. Navigate to **Admin Panel → Functions**
4. Click **Import Functions** → paste the contents of the `.py` file
5. Save, then enable the function as a Global Filter (applies to all models)

Sprint 3 `scripts/provision-students.sh` will automate this via Open WebUI's admin API where
possible. Manual installation is the fallback.

## Why this is in the repo

Filter Functions are platform code. Versioning them alongside compose configs and scripts means:

- Every cohort runs the same filter logic
- Future Claude sessions can find and update the source
- Rollback is `git checkout <commit>` rather than UI restoration

## When updating the filter

1. Edit the `.py` file
2. Test locally if possible (Open WebUI dev environment)
3. Commit + push
4. Re-import the updated function into running Open WebUI (admin panel or API)

The running container does NOT auto-reload changed function files; manual re-import is required
after each edit.
