"""Telemetry — NEUTERED in the lean build.

Upstream Hercules ships a "phone-home": at import it initializes a hardcoded error-reporting DSN,
prompts (interactively!) for the operator's email, and on shutdown ships an installation id + email
+ a full session summary to a third-party ingest endpoint.

For closed/DLP environments that is unacceptable, so this module is reduced to an inert stub:

  * NO ``sentry_sdk`` import, NO DSN — the endpoint is not even present in the artifact.
  * NO ``input()`` — the email is never requested, with or without ``AUTO_MODE``.
  * ``add_event`` / ``send_message_to_sentry`` / ``register_shutdown`` / ``build_final_message``
    are no-ops, kept only so existing call sites keep importing and calling them unchanged.

The public surface the rest of the package imports — ``EventType``, ``EventData``, ``add_event`` —
is preserved. See also ``testzeus_hercules/lean_lockdown.py`` for the env-level kill-switch.
"""

from enum import Enum
from typing import Any, Dict, Optional

from pydantic import BaseModel

# Telemetry is hard-off in the lean build. Kept as a symbol for any code that reads it.
ENABLE_TELEMETRY = False


class EventType(Enum):
    INTERACTION = "interaction"
    STEP = "step"
    TOOL = "tool"
    ASSERT = "assert"
    RUN = "run"
    DETECTION = "detection"
    CONFIG = "config"


class EventData(BaseModel):
    detail: Optional[str] = None
    additional_data: Optional[Dict[str, Any]] = None


def get_installation_id(file_path: str = "installation_id.txt", is_manual_run: bool = True) -> Dict[str, Any]:
    """Return a static local installation identity. Never prompts, never sends anything."""
    return {"user_email": "", "installation_id": "lean-local"}


def add_event(event_type: "EventType", event_data: "EventData") -> None:
    """No-op: events are neither collected nor sent in the lean build."""
    return None


def build_final_message() -> Dict[str, Any]:
    """No-op stub kept for API compatibility."""
    return {}


async def send_message_to_sentry() -> None:
    """No-op: there is no Sentry in the lean build."""
    return None


def register_shutdown() -> None:
    """No-op: nothing is shipped on shutdown in the lean build."""
    return None
