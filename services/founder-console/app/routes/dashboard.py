"""
services/founder-console/app/routes/dashboard.py

GET / — operator dashboard.

Fetches cohort summary + student grid from Postgres and renders dashboard.html.
Auth-gated: unauthenticated requests redirect to /login.
"""

from __future__ import annotations

import os

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse, RedirectResponse

from ..auth import verify_cookie
from ..db import get_cohort_name, get_cohort_summary, get_student_rows

router = APIRouter()


@router.get("/", response_class=HTMLResponse)
async def dashboard(request: Request) -> HTMLResponse | RedirectResponse:
    if not verify_cookie(request):
        return RedirectResponse("/login", status_code=302)

    templates = request.app.state.templates
    cohort_name = get_cohort_name()
    domain = os.getenv("DOMAIN", "")

    try:
        students = get_student_rows(cohort_name)
        summary = get_cohort_summary(cohort_name, students)
        error = None
    except Exception as exc:  # noqa: BLE001
        students = []
        summary = None
        error = str(exc)

    return templates.TemplateResponse(
        "dashboard.html",
        {
            "request": request,
            "cohort_name": cohort_name,
            "domain": domain,
            "students": students,
            "summary": summary,
            "error": error,
        },
    )
