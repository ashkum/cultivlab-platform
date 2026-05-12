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

from .db import get_conn


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


def get_token_for_slug(cohort_name: str, slug: str) -> str | None:
    """
    Return the hashed token for a student identified by cohort + slug.
    Returns None if not found.
    """
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT token
                FROM "LiteLLM_VerificationToken"
                WHERE team_id = (
                    SELECT team_id FROM "LiteLLM_TeamTable"
                    WHERE team_alias = %s LIMIT 1
                )
                AND metadata->>'slug' = %s
                LIMIT 1
                """,
                (cohort_name, slug),
            )
            row = cur.fetchone()
    return row["token"] if row else None
