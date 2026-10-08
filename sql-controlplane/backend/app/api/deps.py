"""FastAPI dependencies: service lookup and request guards."""

from __future__ import annotations

from fastapi import Depends, HTTPException, Request, Security
from fastapi.security import APIKeyHeader

from ..services.chat_service import ChatService
from ..services.dashboard_service import DashboardService
from ..services.sql_service import SqlManagementService
from ..settings import Settings

CLIENT_HEADER = "X-SQLHA-Client"

# A custom header on every state-changing request forces a CORS preflight, which only the configured UI origins
# pass, so other websites can't drive the local API from a user's browser. Any non-empty value is accepted.
client_header = APIKeyHeader(
    name=CLIENT_HEADER, auto_error=False, scheme_name="ClientHeader",
    description="Required on POST/DELETE requests. The UI sends `ui`; in Swagger click Authorize and enter any value.")


def require_client(value: str | None = Security(client_header)) -> str:
    if not value:
        raise HTTPException(status_code=403, detail=f"Missing {CLIENT_HEADER} header.")
    return value


def get_settings(request: Request) -> Settings:
    return request.app.state.settings


def get_sql_service(request: Request) -> SqlManagementService:
    return request.app.state.sql_service


def get_dashboard_service(request: Request) -> DashboardService:
    return request.app.state.dashboard_service


def get_chat_service(request: Request) -> ChatService:
    return request.app.state.chat_service


SqlService = Depends(get_sql_service)
DashboardDep = Depends(get_dashboard_service)
ChatDep = Depends(get_chat_service)
ClientGuard = Depends(require_client)
