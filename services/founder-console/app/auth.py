"""
services/founder-console/app/auth.py

Password verification and signed-cookie auth for the Founder Console.

Environment vars consumed:
  FOUNDER_CONSOLE_PASSWORD_HASH — bcrypt hash of operator password (REQUIRED)
  FOUNDER_CONSOLE_SECRET_KEY    — itsdangerous signing key (REQUIRED)

Generate hash:  python3 -c "import bcrypt; print(bcrypt.hashpw(b'yourpass', bcrypt.gensalt()).decode())"
Generate key:   openssl rand -hex 32
"""

from __future__ import annotations

import os

import bcrypt
from fastapi import Request
from itsdangerous import BadSignature, SignatureExpired, TimestampSigner

# ---------------------------------------------------------------------------
# Lazy-initialised singletons (validated on first use, not at import time)
# ---------------------------------------------------------------------------

_signer: TimestampSigner | None = None
_password_hash: str = ""

_SESSION_COOKIE = "fc_session"
_SESSION_TOKEN = "authenticated"
_SESSION_MAX_AGE = 8 * 3600  # 8 hours


def _require_env(name: str) -> str:
    val = os.getenv(name, "")
    if not val:
        raise RuntimeError(f"Required env var {name} is not set")
    return val


def _get_signer() -> TimestampSigner:
    global _signer
    if _signer is None:
        secret = _require_env("FOUNDER_CONSOLE_SECRET_KEY")
        _signer = TimestampSigner(secret, salt="fc-session")
    return _signer


def _get_password_hash() -> str:
    global _password_hash
    if not _password_hash:
        _password_hash = _require_env("FOUNDER_CONSOLE_PASSWORD_HASH")
    return _password_hash


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def verify_password(plain: str) -> bool:
    """Return True if plain matches the stored bcrypt hash."""
    if not plain:
        return False
    stored = _get_password_hash()
    try:
        return bcrypt.checkpw(plain.encode(), stored.encode())
    except Exception:  # noqa: BLE001 — invalid hash format in env
        return False


def sign_cookie() -> str:
    """Return a signed token value to store in the session cookie."""
    return _get_signer().sign(_SESSION_TOKEN).decode()


def verify_cookie(request: Request) -> bool:
    """Return True if the fc_session cookie is present, signed, and not expired."""
    cookie = request.cookies.get(_SESSION_COOKIE, "")
    if not cookie:
        return False
    try:
        _get_signer().unsign(cookie, max_age=_SESSION_MAX_AGE)
        return True
    except (BadSignature, SignatureExpired):
        return False
