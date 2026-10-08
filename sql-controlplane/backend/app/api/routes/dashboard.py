"""UI API: the dashboard snapshot the React app renders, and on-demand refresh."""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter

from ...schemas.common import ERROR_RESPONSES
from ...schemas.dashboard import DashboardSnapshot, RefreshResult
from ..deps import ClientGuard, DashboardDep

router = APIRouter(prefix="/api/dashboard", tags=["Dashboard (UI)"], responses=ERROR_RESPONSES)


@router.get("/snapshot", response_model=DashboardSnapshot,
            summary="Cached dashboard snapshot (collected on first call)")
def snapshot(dash=DashboardDep) -> Any:
    return dash.get()


@router.post("/refresh", response_model=RefreshResult, dependencies=[ClientGuard],
             summary="Collect a fresh snapshot from Azure (5-30 s)")
def refresh(dash=DashboardDep) -> Any:
    snap = dash.refresh()
    return {"generated_at": snap["generated_at"], "duration_s": dash.last_duration, "kpis": snap["kpis"],
            "section_errors": snap.get("errors") or {}}
