"""
services/founder-console/app/main.py

CultivLab Founder Console — FastAPI application entry point.

Routes registered here:
  GET  /health  — liveness probe (no auth, no DB)
  GET  /login   — login form
  POST /login   — verify password, set signed cookie
  GET  /logout  — clear cookie, redirect to /login

Additional routes are registered via:
  app/routes/dashboard.py  →  GET /
  app/routes/student.py    →  POST /students/{slug}/{action}, /cohort/{action}

Docs UI is intentionally disabled (operator-only service, no public API).
"""

from __future__ import annotations

import os
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from .auth import sign_cookie, verify_cookie, verify_password
from .routes import dashboard, student

# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

app = FastAPI(title="CultivLab Founder Console", docs_url=None, redoc_url=None)

_TEMPLATES_DIR = Path(__file__).parent / "templates"
_templates = Jinja2Templates(directory=str(_TEMPLATES_DIR))

# Serve HTMX and other static assets bundled into the image (no CDN dependency)
_STATIC_DIR = Path(__file__).parent.parent / "static"
app.mount("/static", StaticFiles(directory=str(_STATIC_DIR)), name="static")

# Share the Jinja2 instance with routers via app.state
app.state.templates = _templates

app.include_router(dashboard.router)
app.include_router(student.router)


# ---------------------------------------------------------------------------
# Health — no auth, no DB (CI-friendly)
# ---------------------------------------------------------------------------


@app.get("/health")
async def health() -> JSONResponse:
    return JSONResponse({"status": "ok"})


# ---------------------------------------------------------------------------
# Auth routes
# ---------------------------------------------------------------------------


@app.get("/login", response_class=HTMLResponse, response_model=None)
async def login_form(request: Request) -> HTMLResponse | RedirectResponse:
    if verify_cookie(request):
        return RedirectResponse("/", status_code=302)
    return _templates.TemplateResponse(
        "login.html", {"request": request, "error": None}
    )


@app.post("/login", response_model=None)
async def login_submit(request: Request) -> HTMLResponse | RedirectResponse:
    form = await request.form()
    password = str(form.get("password", ""))

    if not verify_password(password):
        return _templates.TemplateResponse(
            "login.html",
            {"request": request, "error": "Invalid password."},
            status_code=401,
        )

    response = RedirectResponse("/", status_code=302)
    # secure=True in production (HTTPS via Caddy); allow override for local dev
    secure = os.getenv("COOKIE_SECURE", "true").lower() != "false"
    response.set_cookie(
        key="fc_session",
        value=sign_cookie(),
        httponly=True,
        samesite="lax",
        secure=secure,
        max_age=8 * 3600,
    )
    return response


@app.get("/logout", response_model=None)
async def logout() -> RedirectResponse:
    response = RedirectResponse("/login", status_code=302)
    response.delete_cookie("fc_session")
    return response
