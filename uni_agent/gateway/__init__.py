"""Gateway package exports with optional Ray-backed runtime imports."""

from __future__ import annotations

try:
    from .gateway import GatewayActor
    from .manager import GatewayManager
except ModuleNotFoundError as exc:
    # Keep protocol adapters and CPU-only unit tests importable without Ray.
    if exc.name != "ray":
        raise
    GatewayActor = None  # type: ignore[assignment,misc]
    GatewayManager = None  # type: ignore[assignment,misc]

__all__ = ["GatewayActor", "GatewayManager"]
