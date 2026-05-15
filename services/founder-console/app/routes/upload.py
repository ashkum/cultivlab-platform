"""
services/founder-console/app/routes/upload.py

Student file upload endpoint — called from the student portal (index.html).

Routes:
  POST /upload          — upload one or more files to the student's slot
  GET  /upload/files    — list files currently in the student's slot

Auth:  Bearer {litellm_key} in the Authorization header, validated via
       LiteLLM /key/info (key must exist and not be blocked).
Slot:  X-Student-Slot header, injected by Caddy from the subdomain label
       (e.g. l01.cultivlab.com → X-Student-Slot: l01).

No fc_session cookie required — this endpoint is public (HTTPS via Caddy)
and is only routed from student slot subdomains, not from founder.${DOMAIN}.
"""

from __future__ import annotations

import json
import os
import re
import urllib.error
import urllib.request
from pathlib import Path
from typing import List

from fastapi import APIRouter, File, Query, Request, UploadFile
from fastapi.responses import JSONResponse

router = APIRouter()

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

_STUDENTS_ROOT = Path("/srv/students")
_MAX_FILE_BYTES = 5 * 1024 * 1024  # 5 MB per file

_ALLOWED_EXTENSIONS = frozenset(
    {".html", ".htm", ".css", ".js",
     ".jpg", ".jpeg", ".png", ".gif", ".svg", ".webp", ".ico"}
)

# Files that can never be overwritten via the upload endpoint.
_PROTECTED_NAMES = frozenset({"index.html", "index.htm", ".student"})

# Slot names must match l01–l99.
_SLOT_RE = re.compile(r"^l\d{2}$")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _get_slot(request: Request) -> str | None:
    # Derive slot from the Host header (e.g. "l01.cultivlab.com" → "l01").
    # Falls back to X-Student-Slot for local testing / alternative routing.
    host = request.headers.get("host", "").split(":")[0].lower()
    slot = host.split(".")[0]  # first label of the hostname
    if _SLOT_RE.match(slot):
        return slot
    # Fallback: explicit header (e.g. set by a test client)
    slot = request.headers.get("X-Student-Slot", "").strip().lower()
    return slot if _SLOT_RE.match(slot) else None


def _extract_key(request: Request) -> str:
    auth = request.headers.get("Authorization", "")
    return auth.removeprefix("Bearer ").strip()


def _validate_key(key: str) -> bool:
    """Return True if the key exists in LiteLLM and is not blocked."""
    if not key or not key.startswith("sk-"):
        return False
    litellm_url = os.environ.get("LITELLM_INTERNAL_URL", "http://litellm:4000")
    master_key = os.environ.get("LITELLM_MASTER_KEY", "")
    url = f"{litellm_url}/key/info?key={key}"
    req = urllib.request.Request(
        url, headers={"Authorization": f"Bearer {master_key}"}
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read())
            return not data.get("info", {}).get("blocked", False)
    except (urllib.error.URLError, json.JSONDecodeError, KeyError, ValueError):
        return False


def _err(msg: str, status: int = 400) -> JSONResponse:
    return JSONResponse({"error": msg}, status_code=status)


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@router.post("/upload")
async def upload_files(
    request: Request,
    files: List[UploadFile] = File(...),
    force: bool = Query(default=False),
) -> JSONResponse:
    """
    Upload one or more files to the student's slot directory.

    Returns:
      200 { uploaded: [...], conflicts: [...], errors: [...] }
      401 if key is invalid or blocked
      409 { conflicts: [...] } if files exist and force=false
    """
    slot = _get_slot(request)
    if not slot:
        return _err("Missing or invalid slot — contact your instructor.", 400)

    key = _extract_key(request)
    if not _validate_key(key):
        return _err("Upload key invalid or budget exceeded — tell your instructor.", 401)

    slot_dir = _STUDENTS_ROOT / slot
    if not slot_dir.is_dir():
        return _err("Slot directory not found — contact your instructor.", 404)

    uploaded: list[dict] = []
    conflicts: list[str] = []
    errors: list[dict] = []

    for upload in files:
        # Strip any path component the browser might include.
        name = Path(upload.filename or "").name
        if not name:
            errors.append({"file": "(unnamed)", "reason": "empty filename"})
            continue

        suffix = Path(name).suffix.lower()

        if name.lower() in _PROTECTED_NAMES:
            errors.append({"file": name, "reason": "protected file — cannot be replaced"})
            continue

        if suffix not in _ALLOWED_EXTENSIONS:
            errors.append(
                {"file": name, "reason": f"file type '{suffix}' is not allowed"}
            )
            continue

        dest = slot_dir / name

        if dest.exists() and not force:
            conflicts.append(name)
            continue

        data = await upload.read()
        if len(data) > _MAX_FILE_BYTES:
            errors.append({"file": name, "reason": "file is larger than 5 MB"})
            continue

        dest.write_bytes(data)
        uploaded.append({"file": name, "url": f"/{name}", "bytes": len(data)})

    # If the only outcome was conflicts (nothing uploaded, nothing errored),
    # return 409 so the client can prompt for confirmation.
    if conflicts and not uploaded and not errors:
        return JSONResponse(
            {
                "conflicts": conflicts,
                "message": "Files already exist. Re-upload with force=true to overwrite.",
            },
            status_code=409,
        )

    return JSONResponse(
        {"uploaded": uploaded, "conflicts": conflicts, "errors": errors},
        status_code=200,
    )


@router.get("/upload/files")
async def list_files(request: Request) -> JSONResponse:
    """List files published in the student's slot (excludes protected files)."""
    slot = _get_slot(request)
    if not slot:
        return _err("Missing or invalid slot — contact your instructor.", 400)

    key = _extract_key(request)
    if not _validate_key(key):
        return _err("Upload key invalid or blocked.", 401)

    slot_dir = _STUDENTS_ROOT / slot
    if not slot_dir.is_dir():
        return _err("Slot directory not found.", 404)

    files = [
        {"name": f.name, "url": f"/{f.name}"}
        for f in sorted(slot_dir.iterdir())
        if f.is_file()
        and f.name not in _PROTECTED_NAMES
        and not f.name.startswith(".")
    ]
    return JSONResponse({"files": files})
