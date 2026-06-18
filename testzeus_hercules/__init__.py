# Lean lockdown FIRST: sets telemetry-off env defaults before chromadb/huggingface/sentry load.
from testzeus_hercules import lean_lockdown  # type: ignore # noqa: F401,E402
from testzeus_hercules import core  # type: ignore # noqa: F401
