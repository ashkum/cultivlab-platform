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
    OWError,
    get_student_info,
    ow_disable_student,
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
    Return a small HTML fragment for HTMX swap into #flash.
    kind: "ok" → green, "warn" → amber, "error" → red.
    """
    colors = {"ok": "#2d6a4f", "warn": "#b5451b", "error": "#9b2226"}
    color = colors.get(kind, "#9b2226")
    return HTMLResponse(
        f'<div id="flash" style="color:{color};font-weight:600;padding:4px 0">'
        f"{message}</div>"
    )


def _refresh() -> HTMLResponse:
    """Tell HTMX to do a full page reload (status badges update immediately)."""
    return HTMLResponse("", headers={"HX-Refresh": "true"})


# ---------------------------------------------------------------------------
# Per-student actions
# ---------------------------------------------------------------------------


@router.post("/students/{slug}/pause", response_class=HTMLResponse, response_model=None)
async def pause_student(slug: str, request: Request) -> HTMLResponse | RedirectResponse:
    if not _guard(request):
        return RedirectResponse("/login", status_code=302)
    cohort = get_cohort_name()
    info = get_student_info(cohort, slug)
    if not info:
        return _flash(f"Student '{slug}' not found in cohort '{cohort}'.", "error")
    token, name = info
    ok = set_student_blocked(token, blocked=True)
    if not ok:
        return _flash(f"DB update failed for '{slug}' — token not matched.", "error")
    # Best-effort OW suspend — LiteLLM block always committed above.
    try:
        ow_msg = ow_disable_student(name, disabled=True)
        return _refresh()  # full page reload shows updated status badge
    except OWError as exc:
        return _flash(
            f"⛔ {slug} IDE blocked. ⚠️ Chat not suspended — {exc}. "
            f"Disable manually via the admin panel.",
            "warn",
        )


@router.post("/students/{slug}/resume", response_class=HTMLResponse, response_model=None)
async def resume_student(
    slug: str, request: Request
) -> HTMLResponse | RedirectResponse:
    if not _guard(request):
        return RedirectResponse("/login", status_code=302)
    cohort = get_cohort_name()
    info = get_student_info(cohort, slug)
    if not info:
        return _flash(f"Student '{slug}' not found in cohort '{cohort}'.", "error")
    token, name = info
    ok = set_student_blocked(token, blocked=False)
    if not ok:
        return _flash(f"DB update failed for '{slug}' — token not matched.", "error")
    # Best-effort OW restore.
    try:
        ow_msg = ow_disable_student(name, disabled=False)
        return _refresh()
    except OWError as exc:
        return _flash(
            f"✅ {slug} IDE unblocked. ⚠️ Chat restore failed — {exc}. "
            f"Re-enable manually via the admin panel.",
            "warn",
        )


@router.post("/students/{slug}/topup", response_class=HTMLResponse, response_model=None)
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
    info = get_student_info(cohort, slug)
    if not info:
        return _flash(f"Student '{slug}' not found in cohort '{cohort}'.", "error")
    token, _ = info
    ok = topup_student_budget(token, amount)
    if not ok:
        return _flash(f"DB update failed for '{slug}'.", "error")
    return _refresh()


# ---------------------------------------------------------------------------
# Cohort-wide actions
# ---------------------------------------------------------------------------


@router.post("/cohort/pause", response_class=HTMLResponse, response_model=None)
async def pause_cohort(request: Request) -> HTMLResponse | RedirectResponse:
    if not _guard(request):
        return RedirectResponse("/login", status_code=302)
    cohort = get_cohort_name()
    count = set_cohort_blocked(cohort, blocked=True)
    return _refresh()


@router.post("/cohort/resume", response_class=HTMLResponse, response_model=None)
async def resume_cohort(request: Request) -> HTMLResponse | RedirectResponse:
    if not _guard(request):
        return RedirectResponse("/login", status_code=302)
    cohort = get_cohort_name()
    count = set_cohort_blocked(cohort, blocked=False)
    return _refresh()
