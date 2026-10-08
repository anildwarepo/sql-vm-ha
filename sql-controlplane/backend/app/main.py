"""FastAPI application factory."""

from __future__ import annotations

import logging
import threading
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from starlette.middleware.trustedhost import TrustedHostMiddleware

from . import __version__
from .api.routes import ROUTERS
from .errors import register_exception_handlers
from .services.chat_service import ChatService
from .services.dashboard_service import DashboardService
from .services.sql_service import SqlManagementService
from .settings import Settings, get_settings

log = logging.getLogger("sqlha.api")

DESCRIPTION = """
REST API for the **SQL control plane**: SQL Server Always On availability groups running on AWS (or anywhere)
and managed from Azure through **Azure Arc**, **Azure Update Manager** and **Defender for Cloud**.

* **SQL management**: inventory, Always On state, patch compliance and history, maintenance windows, security,
  databases, runbook jobs, live performance and Resource Graph queries.
* **SQL actions**: patch assessment, AG-safe patch installation and planned failover. Every action previews with
  `confirm=false`; `confirm=true` runs it only when `SQLHA_ENABLE_WRITE_ACTIONS=true`.
* **Dashboard (UI)**: the cached snapshot the React UI renders, and refresh.
* **Chat**: the read-only SQL HA agent, streamed as Server-Sent Events.

POST and DELETE requests need the `X-SQLHA-Client` header (use **Authorize** in Swagger).
"""

TAGS = [
    {"name": "Health", "description": "Liveness and feature flags"},
    {"name": "SQL management", "description": "Read-only views over Arc SQL, Update Manager and Defender"},
    {"name": "SQL actions", "description": "Write actions with preview (confirm=false) and AG safety checks"},
    {"name": "Dashboard (UI)", "description": "Aggregated snapshot for the React UI"},
    {"name": "Chat", "description": "Read-only SQL HA agent (Microsoft Foundry model)"},
]


def create_app(settings: Settings | None = None, *, sql_service: SqlManagementService | None = None,
               dashboard_service: DashboardService | None = None, chat_service: ChatService | None = None,
               prewarm: bool = True) -> FastAPI:
    settings = settings or get_settings()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        if prewarm:
            # Collect the first snapshot in the background so the UI's first load is fast.
            threading.Thread(target=_prewarm, args=(app.state.dashboard_service,), daemon=True).start()
        yield

    app = FastAPI(title="SQL Control Plane API", version=__version__, description=DESCRIPTION,
                  openapi_tags=TAGS, lifespan=lifespan,
                  swagger_ui_parameters={"persistAuthorization": True, "displayRequestDuration": True})
    app.state.settings = settings
    app.state.sql_service = sql_service or SqlManagementService()
    app.state.dashboard_service = dashboard_service or DashboardService()
    app.state.chat_service = chat_service or ChatService(max_sessions=settings.chat_max_sessions)

    app.add_middleware(TrustedHostMiddleware, allowed_hosts=settings.allowed_hosts)
    app.add_middleware(CORSMiddleware, allow_origins=settings.cors_origins, allow_methods=["GET", "POST", "DELETE"],
                       allow_headers=["Content-Type", "X-SQLHA-Client"], allow_credentials=False)
    register_exception_handlers(app)
    for router in ROUTERS:
        app.include_router(router)

    # Production: serve the built React app from the same origin (routers above take precedence).
    app.state.ui_served = (settings.ui_dist / "index.html").is_file()
    if app.state.ui_served:
        app.mount("/", StaticFiles(directory=settings.ui_dist, html=True), name="ui")
    return app


def _prewarm(dashboard: DashboardService) -> None:
    try:
        dashboard.get()
        log.info("Dashboard snapshot ready (%.1f s)", dashboard.last_duration)
    except Exception as exc:  # e.g. not logged in to Azure; the UI shows the error on first load
        log.warning("Snapshot prewarm failed: %s", exc)
