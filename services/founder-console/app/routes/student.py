"""
services/founder-console/app/routes/student.py

HTMX action endpoints: pause/resume/topup per student, pause/resume cohort.

All endpoints:
  - Require fc_session cookie (auth guard)
  - Return a small HTML fragment that HTMX swaps into #flash
  - Are idempotent (blocking an already-blocked key is a no-op at the DB level)
"""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse

from ..actions import (
    get_token_for_slug,
    set_cohort_blocked,
    set_student_blocked,
    topup_student_budget,
)
from ..auth import verify_cookie
from ..db import get_cohort_name

router = APIRouter()

_MAX_TOPUP = 50.0  # USD — prevents accidental large top-ups via form tampering


def _guard(request: Request) -> bool:
    return verify_cookie(request)


def _flash(message: str, kind: str = "ok") -> HTMLResponse:
    """
    Return a tiny HTML fragment for HTMX out-of-band swap into #flash.
    kind: "ok" → green, "error" → red.
    """
    color = "#2d6a4f" if kind == "ok" else "#9b2226"
    return HTMLResponse(
        f'<div id="flash" style="color:{color};font-weight:600;padding:4px 0">'
        f"{message}</div>"
    )


# ---------------------------------------------------------------------------
# Per-student actions
# ---------------------------------------------------------------------------


@router.post("/students/{slug}/pause", response_class=HTMLResponse)
async def pause_student(slug: str, request: Request) -> HTMLResponse | RedirectResponse:
    if not _guard(request):
        return RedirectResponse("/login", status_code=302)
    cohort = get_cohort_name()
    token = get_token_for_slug(cohort, slug)
    if not token:
        return _flash(f"Student '{slug}' not found in cohort '{cohort}'.", "error")
    ok = set_student_blocked(token, blocked=True)
    if not ok:
        return _flash(f"DB update failed for '{slug}' — token not matched.", "error")
    return _flash(
        f"⛔ {slug} paused (IDE blocked). "
        f"To suspend chat, disable their account via the admin panel."
    )


@router.post("/students/{slug}/resume", response_class=HTMLResponse)
async def resume_student(
    slug: str, request: Request
) -> HTMLResponse | RedirectResponse:
    if not _guard(request):
        return RedirectResponse("/login", status_code=302)
    cohort = get_cohort_name()
    token = get_token_for_slug(cohort, slug)
    if not token:
        return _flash(f"Student '{slug}' not found in cohort '{cohort}'.", "error")
    ok = set_student_blocked(token, blocked=False)
    if not ok:
        return _flash(f"DB update failed for '{slug}' — token not matched.", "error")
    return _flash(f"✅ {slug} resumed.")


@router.post("/students/{slug}/topup", response_class=HTMLResponse)
async def topup_student(
    slug: str,
    request: Request,
    amount: Annotated[float, Form()] = 5.0,
) -> HTMLResponse | RedirectResponse:
    if not _guard(request):
        return RedirectResponse("/login", status_code=302)
    if amount <= 0 or amount > _MAX_TOPUP:
        return _flash(f"Amount must be $0.01–${_MAX_TOPUP:.0f}.", "error")
    cohort = get_cohort_name()
    token = get_token_for_slug(cohort, slug)
    if not token:
        return _flash(f"Student '{slug}' not found in cohort '{cohort}'.", "error")
    ok = topup_student_budget(token, amount)
    if not ok:
        return _flash(f"DB update failed for '{slug}'.", "error")
    return _flash(f"✅ Added ${amount:.2f} to {slug}'s budget.")


# ---------------------------------------------------------------------------
# Cohort-wide actions
# ---------------------------------------------------------------------------


@router.post("/cohort/pause", response_class=HTMLResponse)
async def pause_cohort(request: Request) -> HTMLResponse | RedirectResponse:
    if not _guard(request):
        return RedirectResponse("/login", status_code=302)
    cohort = get_cohort_name()
    count = set_cohort_blocked(cohort, blocked=True)
    return _flash(f"⛔ Cohort paused — {count} key(s) blocked (IDE access cut).")


@router.post("/cohort/resume", response_class=HTMLResponse)
async def resume_cohort(request: Request) -> HTMLResponse | RedirectResponse:
    if not _guard(request):
        return RedirectResponse("/login", status_code=302)
    cohort = get_cohort_name()
    count = set_cohort_blocked(cohort, blocked=False)
    return _flash(f"✅ Cohort resumed — {count} key(s) unblocked.")
