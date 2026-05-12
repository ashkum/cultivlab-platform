"""
services/founder-console/app/db.py

Read-only Postgres queries for the Founder Console student grid and cohort summary.

All queries use psycopg2 with the DATABASE_URL env var.
Connection is opened per-request — no pool needed at cohort (≤12 student) scale.

Spend attribution notes (ADR-011):
  IDE/Continue.dev: SpendLogs.api_key = hashed virtual key token → joinable to
                    LiteLLM_VerificationToken.token → slug known.
  Chat via OW:      SpendLogs.team_id IS NULL, user = OW UUID → slug unknown on
                    VM; shown as cohort aggregate only.
"""

from __future__ import annotations

import os
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Generator

import psycopg2
import psycopg2.extras


# ---------------------------------------------------------------------------
# Connection
# ---------------------------------------------------------------------------


def _get_dsn() -> str:
    dsn = os.getenv("DATABASE_URL", "")
    if not dsn:
        raise RuntimeError("DATABASE_URL is not set")
    return dsn


@contextmanager
def get_conn() -> Generator[psycopg2.extensions.connection, None, None]:
    """Open a Postgres connection and close it on exit."""
    conn = psycopg2.connect(_get_dsn(), cursor_factory=psycopg2.extras.RealDictCursor)
    try:
        yield conn
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------


@dataclass
class StudentRow:
    slug: str
    token: str       # hashed — used as write-action key, never displayed
    blocked: bool
    total_spend: float
    max_budget: float
    spend_24h: float
    spend_7d: float
    slot: str        # e.g. "l01", or "" if not assigned
    site_live: bool


@dataclass
class CohortSummary:
    team_alias: str
    team_spend: float
    team_max_budget: float
    team_blocked: bool
    student_count: int
    blocked_count: int
    chat_spend_24h: float   # aggregate chat (master-key) spend
    chat_requests_24h: int


# ---------------------------------------------------------------------------
# Filesystem helpers (slot manifest written by provision-sites.sh)
# ---------------------------------------------------------------------------

_STUDENTS_ROOT = "/srv/students"


def _read_slot_manifest() -> dict[str, str]:
    """
    Scan /srv/students/*/.student to build {slug: slot} map.
    Returns {} if the directory doesn't exist (CI / dev environments).
    """
    mapping: dict[str, str] = {}
    if not os.path.isdir(_STUDENTS_ROOT):
        return mapping
    for entry in os.scandir(_STUDENTS_ROOT):
        if not entry.is_dir():
            continue
        manifest_path = os.path.join(entry.path, ".student")
        if not os.path.isfile(manifest_path):
            continue
        try:
            with open(manifest_path) as f:
                slug = f.read().strip()
            if slug:
                mapping[slug] = entry.name
        except OSError:
            pass
    return mapping


def _check_site_live(slot: str) -> bool:
    """Return True if /srv/students/<slot>/index.html exists."""
    return os.path.isfile(os.path.join(_STUDENTS_ROOT, slot, "index.html"))


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------


def get_cohort_name() -> str:
    return os.getenv("COHORT_NAME", "")


def get_student_rows(cohort_name: str) -> list[StudentRow]:
    """
    Return one StudentRow per student virtual key in the cohort.
    Three SQL round-trips: key list, 24h spend, 7d spend.
    """
    slot_map = _read_slot_manifest()

    with get_conn() as conn:
        with conn.cursor() as cur:
            # Virtual keys belonging to this cohort
            cur.execute(
                """
                SELECT
                    vt.token,
                    COALESCE(vt.metadata->>'slug', LEFT(vt.token, 8)) AS slug,
                    COALESCE(vt.blocked, false)   AS blocked,
                    COALESCE(vt.spend, 0)         AS total_spend,
                    COALESCE(vt.max_budget, 0)    AS max_budget
                FROM "LiteLLM_VerificationToken" vt
                WHERE vt.team_id = (
                    SELECT team_id FROM "LiteLLM_TeamTable"
                    WHERE team_alias = %s LIMIT 1
                )
                ORDER BY slug
                """,
                (cohort_name,),
            )
            keys = cur.fetchall()
            if not keys:
                return []

            tokens = [r["token"] for r in keys]

            # 24-hour IDE spend per key
            cur.execute(
                """
                SELECT api_key, COALESCE(SUM(spend), 0) AS s
                FROM "LiteLLM_SpendLogs"
                WHERE api_key = ANY(%s)
                  AND "startTime" > NOW() - INTERVAL '24 hours'
                GROUP BY api_key
                """,
                (tokens,),
            )
            spend_24h = {r["api_key"]: float(r["s"]) for r in cur.fetchall()}

            # 7-day IDE spend per key
            cur.execute(
                """
                SELECT api_key, COALESCE(SUM(spend), 0) AS s
                FROM "LiteLLM_SpendLogs"
                WHERE api_key = ANY(%s)
                  AND "startTime" > NOW() - INTERVAL '7 days'
                GROUP BY api_key
                """,
                (tokens,),
            )
            spend_7d = {r["api_key"]: float(r["s"]) for r in cur.fetchall()}

    rows: list[StudentRow] = []
    for key in keys:
        token = key["token"]
        slug = key["slug"]
        slot = slot_map.get(slug, "")
        rows.append(
            StudentRow(
                slug=slug,
                token=token,
                blocked=bool(key["blocked"]),
                total_spend=float(key["total_spend"]),
                max_budget=float(key["max_budget"]),
                spend_24h=spend_24h.get(token, 0.0),
                spend_7d=spend_7d.get(token, 0.0),
                slot=slot,
                site_live=_check_site_live(slot) if slot else False,
            )
        )
    return rows


def get_cohort_summary(cohort_name: str, students: list[StudentRow]) -> CohortSummary:
    """
    Return cohort-level totals. Reuses the already-fetched student list for
    counts so we don't need a third DB round-trip for those.
    """
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT
                    COALESCE(spend, 0)       AS spend,
                    COALESCE(max_budget, 0)  AS max_budget,
                    COALESCE(blocked, false) AS blocked
                FROM "LiteLLM_TeamTable"
                WHERE team_alias = %s
                LIMIT 1
                """,
                (cohort_name,),
            )
            team = cur.fetchone()

            # Chat aggregate: master-key requests (team_id IS NULL, user non-empty)
            cur.execute(
                """
                SELECT
                    COUNT(*)                    AS reqs,
                    COALESCE(SUM(spend), 0)     AS spend
                FROM "LiteLLM_SpendLogs"
                WHERE team_id IS NULL
                  AND "user" != ''
                  AND "startTime" > NOW() - INTERVAL '24 hours'
                """
            )
            chat = cur.fetchone()

    return CohortSummary(
        team_alias=cohort_name,
        team_spend=float(team["spend"]) if team else 0.0,
        team_max_budget=float(team["max_budget"]) if team else 0.0,
        team_blocked=bool(team["blocked"]) if team else False,
        student_count=len(students),
        blocked_count=sum(1 for s in students if s.blocked),
        chat_spend_24h=float(chat["spend"]) if chat else 0.0,
        chat_requests_24h=int(chat["reqs"]) if chat else 0,
    )
