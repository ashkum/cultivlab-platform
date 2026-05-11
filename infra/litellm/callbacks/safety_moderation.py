"""
CultivLab safety moderation callback for LiteLLM.

WHY THIS EXISTS
---------------
CultivLab serves chat to children aged 8-12. Every chat completion request must
be screened for harmful content (violence, sexual content, self-harm, hate,
etc.) before reaching the upstream LLM. If flagged, the request is blocked AND
a real-time alert fires to the founder's Slack #cultivlab-alerts channel.

WHAT IT DOES
------------
1. Before each chat completion (`async_pre_call_hook`), extract the most recent
   user message from the request.
2. Send it to OpenAI's `omni-moderation-latest` API.
3. If any category is flagged with confidence above the threshold:
   - POST to ${SLACK_WEBHOOK_SAFETY} with student UUID, model, flagged
     categories, and a sanitized preview of the message.
   - Raise an HTTPException(400) so LiteLLM returns an error to Open WebUI
     instead of forwarding to the LLM. The student sees a "Please use kind
     language" message.
4. If clean, returns None and LiteLLM proceeds normally.

CONFIGURATION
-------------
Required environment variables (read at module import):
  OPENAI_API_KEY            for calling the moderation API
  SLACK_WEBHOOK_SAFETY      where to send safety alerts
Optional:
  SAFETY_MODERATION_DISABLED=true   skip moderation entirely (debug only)
  SAFETY_LOG_ONLY=true              alert but do NOT block (logging-only mode)

INSTALLATION
------------
This file is mounted into the LiteLLM container at
/app/callbacks/safety_moderation.py via docker-compose.yml volumes. LiteLLM's
config.yaml references it via:
  litellm_settings:
    callbacks: [callbacks.safety_moderation.proxy_handler_instance]

See ADR-012 (TBD) for the design decision.
"""

import os
import json
import urllib.request
from typing import Any, Dict, Literal, Optional, Union

from fastapi import HTTPException
from litellm.caching.caching import DualCache
from litellm.integrations.custom_logger import CustomLogger
from litellm.proxy._types import UserAPIKeyAuth

# Module-level config read once on import. Container restart picks up changes.
_OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY", "")
_SLACK_WEBHOOK_SAFETY = os.environ.get("SLACK_WEBHOOK_SAFETY", "")
_SAFETY_DISABLED = os.environ.get("SAFETY_MODERATION_DISABLED", "").lower() == "true"
_LOG_ONLY = os.environ.get("SAFETY_LOG_ONLY", "").lower() == "true"

# Moderation API endpoint. Omni model handles text + image content.
_MODERATION_URL = "https://api.openai.com/v1/moderations"
_MODERATION_MODEL = "omni-moderation-latest"

# Preview length for content shown in Slack alerts. Long enough to be useful,
# short enough not to amplify harmful content in our own alert channel.
_PREVIEW_CHARS = 200


def _extract_latest_user_message(data: Dict[str, Any]) -> str:
    """Return the most recent user-role message text, or empty string."""
    messages = data.get("messages") or []
    for msg in reversed(messages):
        if msg.get("role") == "user":
            content = msg.get("content", "")
            # Content may be a list of parts (multimodal); join text parts.
            if isinstance(content, list):
                parts = []
                for p in content:
                    if isinstance(p, dict) and p.get("type") == "text":
                        parts.append(p.get("text", ""))
                return "\n".join(parts)
            return str(content)
    return ""


def _call_moderation_api(text: str) -> Optional[Dict[str, Any]]:
    """Call OpenAI moderation. Returns parsed JSON or None on error."""
    if not _OPENAI_API_KEY:
        # Fail-open if no key: don't block legitimate traffic on misconfig.
        return None

    body = json.dumps({"model": _MODERATION_MODEL, "input": text}).encode("utf-8")
    req = urllib.request.Request(
        _MODERATION_URL,
        data=body,
        headers={
            "Authorization": f"Bearer {_OPENAI_API_KEY}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception:
        # Network or 5xx error: fail-open. Logging failure path is downstream.
        return None


def _flagged_categories(result: Dict[str, Any]) -> Dict[str, float]:
    """Return {category: score} for categories that were flagged."""
    if not result or not result.get("results"):
        return {}
    first = result["results"][0]
    categories = first.get("categories", {}) or {}
    scores = first.get("category_scores", {}) or {}
    return {cat: scores.get(cat, 0.0) for cat, flagged in categories.items() if flagged}


def _send_slack_alert(
    *,
    user_id: str,
    model: str,
    flagged: Dict[str, float],
    preview: str,
    log_only: bool,
) -> None:
    """POST safety alert to Slack. Best-effort; never raises."""
    if not _SLACK_WEBHOOK_SAFETY:
        return

    cats = ", ".join(f"{c}={s:.2f}" for c, s in flagged.items())
    mode = "LOG-ONLY" if log_only else "BLOCKED"
    snippet = preview[:_PREVIEW_CHARS]
    if len(preview) > _PREVIEW_CHARS:
        snippet += "..."

    payload = {
        "text": (
            f":warning: Safety [{mode}] — user={user_id} model={model}\n"
            f"flagged: {cats}\n"
            f"```{snippet}```"
        )
    }
    try:
        req = urllib.request.Request(
            _SLACK_WEBHOOK_SAFETY,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=3) as _:
            pass
    except Exception:
        # Best-effort. We must not propagate errors from the alert path.
        pass


class CultivLabSafetyModeration(CustomLogger):
    """LiteLLM callback that screens chat input and alerts on flagged content."""

    async def async_pre_call_hook(
        self,
        user_api_key_dict: UserAPIKeyAuth,
        cache: DualCache,
        data: dict,
        call_type: Literal[
            "completion",
            "text_completion",
            "embeddings",
            "image_generation",
            "moderation",
            "audio_transcription",
            "pass_through_endpoint",
            "rerank",
        ],
    ) -> Optional[Union[Exception, str, dict]]:
        # Only screen chat completion calls. Other call types pass through.
        if call_type not in ("completion", "text_completion"):
            return None

        if _SAFETY_DISABLED:
            return None

        text = _extract_latest_user_message(data)
        if not text.strip():
            return None

        result = _call_moderation_api(text)
        flagged = _flagged_categories(result) if result else {}
        if not flagged:
            return None

        # We have flagged content. Identify the student via the user field
        # that our Open WebUI Filter Function injects (ADR-011).
        user_id = data.get("user") or "unknown"
        model = data.get("model") or "unknown"

        _send_slack_alert(
            user_id=user_id,
            model=model,
            flagged=flagged,
            preview=text,
            log_only=_LOG_ONLY,
        )

        if _LOG_ONLY:
            # Alert but don't block — useful during tuning to see false positives.
            return None

        # Block. LiteLLM returns this as an HTTP error to Open WebUI.
        raise HTTPException(
            status_code=400,
            detail=(
                "Your message was blocked by content safety. "
                "Please rephrase using kind, school-appropriate language."
            ),
        )


# LiteLLM looks for an instance named `proxy_handler_instance` in callback modules.
proxy_handler_instance = CultivLabSafetyModeration()
