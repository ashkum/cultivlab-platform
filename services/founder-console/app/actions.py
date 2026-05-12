"""
services/founder-console/app/actions.py

Postgres write actions for the Founder Console.

All writes use direct SQL UPDATE on LiteLLM_VerificationToken /
LiteLLM_TeamTable. The LiteLLM admin API (/key/block, /key/update) requires
the plaintext virtual key, which is not stored on the VM — only the hashed
token is available. Direct DB writes match the pattern established in
scripts/weekly-cap-enforcer.sh (Sprint 5).

LiteLLM's in-memory key cache expires in ~60 seconds, so blocks and
budget changes take effect within one minute of the UPDATE.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request

from .db import get_conn


# ---------------------------------------------------------------------------
# Open WebUI admin API helpers (best-effort — see Sprint 6 / ADR-008)
# ---------------------------------------------------------------------------


class OWError(Exception):
    """Raised when an Open WebUI API call fails."""


def _ow_signin(ow_url: str, email: str, password: str) -> str:
    """POST /api/v1/auths/signin → JWT string. Raises OWError on failure."""
    body = json.dumps({"email": email, "password": password}).encode()
    req = urllib.request.Request(
        f"{ow_url}/api/v1/auths/signin",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read())
    except Exception as exc:
        raise OWError(f"OW signin failed: {exc}") from exc
    token = data.get("token") or data.get("jwt")
    if not token:
        raise OWError("OW signin: no token in response")
    return str(token)


def _ow_find_user(ow_url: str, jwt: str, name: str) -> dict | None:
    """GET /api/v1/users/ → find user by name (case-insensitive). Returns full user dict or None."""
    req = urllib.request.Request(
        f"{ow_url}/api/v1/users/",
        headers={"Authorization": f"Bearer {jwt}"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            users = json.loads(resp.read())
    except Exception as exc:
        raise OWError(f"OW list users failed: {exc}") from exc
    name_lower = name.lower()
    for user in users:
        if (user.get("name") or "").lower() == name_lower:
            return user
    return None


def _ow_set_role(ow_url: str, jwt: str, user: dict, role: str) -> None:
    """POST /api/v1/users/{id}/update with full UserUpdateForm payload.

    OW v0.5.20 requires all four fields (name, email, profile_image_url, role)
    in the update body — sending only {role} causes HTTP 422.
    """
    payload = {
        "name": user.get("name") or "",
        "email": user.get("email") or "",
        "profile_image_url": user.get("profile_image_url") or "",
        "role": role,
    }
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        f"{ow_url}/api/v1/users/{user['id']}/update",
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {jwt}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as _resp:
            pass
    except urllib.error.HTTPError as exc:
        raise OWError(f"OW update user: HTTP {exc.code}") from exc
    except Exception as exc:
        raise OWError(f"OW update user: {exc}") from exc


def ow_disable_student(name: str, disabled: bool) -> str:
    """
    Attempt to suspend or restore a student's Open WebUI account by name match.

    - disabled=True  → sets OW role to 'pending' (blocks chat login)
    - disabled=False → sets OW role to 'user' (restores chat access)

    Returns a short status string for inclusion in the flash message.
    Raises OWError if config env vars are missing or any API call fails.
    This is intentionally best-effort: callers must not roll back the
    LiteLLM key block if this raises.
    """
    ow_url = os.getenv("OPENWEBUI_URL", "").rstrip("/")
    email = os.getenv("OPENWEBUI_ADMIN_EMAIL", "")
    password = os.getenv("OPENWEBUI_ADMIN_PASSWORD", "")
    if not (ow_url and email and password):
        raise OWError(
            "OPENWEBUI_URL / OPENWEBUI_ADMIN_EMAIL / OPENWEBUI_ADMIN_PASSWORD not configured"
        )
    jwt = _ow_signin(ow_url, email, password)
    user = _ow_find_user(ow_url, jwt, name)
    if not user:
        raise OWError(f"no OW account found for name '{name}'")
    role = "pending" if disabled else "user"
    _ow_set_role(ow_url, jwt, user, role)
    return "chat suspended" if disabled else "chat restored"


def set_student_blocked(token: str, blocked: bool) -> bool:
    """
    Block or unblock a single student virtual key by its hashed token.
    Returns True if a row was updated, False if the token was not found.
    """
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE "LiteLLM_VerificationToken"
                SET blocked = %s
                WHERE token = %s
                """,
                (blocked, token),
            )
            updated = cur.rowcount
        conn.commit()
    return updated > 0


def topup_student_budget(token: str, add_amount: float) -> bool:
    """
    Increase a student's max_budget by add_amount (USD).
    Returns True on success, False if the token was not found or amount ≤ 0.
    """
    if add_amount <= 0:
        return False
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE "LiteLLM_VerificationToken"
                SET max_budget = COALESCE(max_budget, 0) + %s
                WHERE token = %s
                """,
                (add_amount, token),
            )
            updated = cur.rowcount
        conn.commit()
    return updated > 0


def set_cohort_blocked(cohort_name: str, blocked: bool) -> int:
    """
    Block or unblock every student virtual key in a cohort in one UPDATE.
    Returns the number of keys updated.
    """
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE "LiteLLM_VerificationToken"
                SET blocked = %s
                WHERE team_id = (
                    SELECT team_id FROM "LiteLLM_TeamTable"
                    WHERE team_alias = %s LIMIT 1
                )
                """,
                (blocked, cohort_name),
            )
            updated = cur.rowcount
        conn.commit()
    return updated


def get_student_info(
    cohort_name: str, slug: str
) -> tuple[str, str] | None:
    """
    Return (token, name) for a student identified by cohort + slug.
    name falls back to slug if not set in metadata.
    Returns None if not found.
    """
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT token,
                       COALESCE(metadata->>'name', %s) AS student_name
                FROM "LiteLLM_VerificationToken"
                WHERE team_id = (
                    SELECT team_id FROM "LiteLLM_TeamTable"
                    WHERE team_alias = %s LIMIT 1
                )
                AND metadata->>'slug' = %s
                LIMIT 1
                """,
                (slug, cohort_name, slug),
            )
            row = cur.fetchone()
    if not row:
        return None
    return row["token"], row["student_name"]
