"""
CultivLab user-field injection Filter for Open WebUI.

WHY THIS EXISTS
---------------
Open WebUI v0.5.20 does NOT pass the OpenAI-style `user` field to upstream LLM
proxies on chat completion requests. CultivLab uses LiteLLM's per-user spend
attribution and per-user budget enforcement, both of which key off this field.

Without this filter, every student's chat traffic registers under the same
key (no per-student spend tracking, no per-student budget caps), breaking
the cohort cost model established in Sprint 2.

WHAT IT DOES
------------
Before any chat completion request leaves Open WebUI, this filter:

  1. Reads the currently-logged-in user's identity from Open WebUI's runtime.
  2. Sets `body["user"] = <openwebui_user_id>` (or the configured field).
  3. Passes the modified body downstream to LiteLLM.

LiteLLM then attributes the call to that student in its spend logs and applies
any per-user budget caps configured for that identity.

INSTALLATION
------------
This file is loaded into Open WebUI via the admin panel:
  Admin Panel -> Functions -> Import Function -> paste this file's contents.

After import, enable the function as a Global Filter (applies to all models)
or attach it to specific model(s).

LOCATION RATIONALE
------------------
Kept in the repo (infra/open-webui/functions/) so:
  - The source is version-controlled alongside the rest of the platform.
  - Sprint 3 provisioning scripts can install or update it programmatically
    via Open WebUI's admin API.
  - Future Claude sessions can find and modify it.

See ADR-011 in docs/DECISION_LOG.md for the design decision.
"""

from typing import Optional
from pydantic import BaseModel, Field


class Filter:
    """
    Open WebUI Filter that injects the OpenAI `user` field into chat completion
    requests using the logged-in Open WebUI user's stable identifier.
    """

    class Valves(BaseModel):
        """
        Admin-tunable settings, surfaced in the Open WebUI Functions UI.
        """

        identity_source: str = Field(
            default="id",
            description=(
                "Which Open WebUI user attribute to send as the OpenAI `user` "
                "field. Options: 'id' (stable UUID; default, recommended), "
                "'email' (human-readable but PII), 'name' (display name; not "
                "guaranteed unique)."
            ),
        )

        priority: int = Field(
            default=0,
            description=(
                "Filter execution priority. Lower numbers run first. Keep at 0 "
                "unless multiple filters need ordering."
            ),
        )

    def __init__(self):
        self.valves = self.Valves()

    def inlet(
        self,
        body: dict,
        __user__: Optional[dict] = None,
    ) -> dict:
        """
        Called by Open WebUI before the chat completion request is sent to the
        upstream OpenAI-compatible endpoint (LiteLLM in our case).

        Args:
            body: The OpenAI chat completion request body. We mutate this.
            __user__: Dict of Open WebUI user attributes for the current
                request. Provided by Open WebUI; we never construct this.

        Returns:
            The (mutated) body, with `user` field injected.
        """
        # Defensive: if we somehow get an anonymous request, do not inject.
        # LiteLLM's enforce_user_param=true will reject anonymous requests,
        # which is the correct failure mode (loud, not silent).
        if __user__ is None:
            return body

        identity_field = self.valves.identity_source
        identity_value = __user__.get(identity_field)

        if not identity_value:
            # Misconfigured Valves OR user object missing the attribute.
            # Fall back to 'id' since that's always present.
            identity_value = __user__.get("id")

        if identity_value:
            body["user"] = str(identity_value)

        return body
