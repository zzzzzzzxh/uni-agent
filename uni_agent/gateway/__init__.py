"""Gateway package exports with lazy Ray-backed runtime imports."""

from __future__ import annotations

__all__ = ["GatewayActor", "GatewayManager"]


def __getattr__(name: str):
    if name == "GatewayActor":
        from .gateway import GatewayActor

        return GatewayActor
    if name == "GatewayManager":
        from .manager import GatewayManager

        return GatewayManager
    raise AttributeError(name)
