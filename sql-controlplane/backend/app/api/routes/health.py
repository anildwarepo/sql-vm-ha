"""Liveness and configuration."""

from __future__ import annotations

from fastapi import APIRouter, Request
from pydantic import BaseModel

from ... import __version__
from ..deps import ChatDep, DashboardDep, SqlService

router = APIRouter(prefix="/api", tags=["Health"])


class Health(BaseModel):
    status: str
    version: str
    write_actions_enabled: bool
    perf_snapshot_enabled: bool
    chat_configured: bool
    snapshot_cached: bool
    scope: dict[str, list[str]]
    ui_served: bool


@router.get("/health", response_model=Health, summary="Backend status and feature flags")
def health(request: Request, sql=SqlService, dash=DashboardDep, chat=ChatDep) -> Health:
    return Health(
        status="ok",
        version=__version__,
        write_actions_enabled=sql.write_actions_enabled,
        perf_snapshot_enabled=sql.perf_snapshot_enabled,
        chat_configured=not chat.missing_settings(),
        snapshot_cached=dash.has_snapshot,
        scope=sql.scope(),
        ui_served=bool(getattr(request.app.state, "ui_served", False)),
    )
