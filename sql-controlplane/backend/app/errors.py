"""Map core-library and framework exceptions to one JSON error format: {"error": {"code", "message", ...}}."""

from __future__ import annotations

import logging

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from sqlha.arm import ArmError
from starlette.exceptions import HTTPException as StarletteHTTPException

log = logging.getLogger("sqlha.api")


def _body(code: str, message: str, **extra) -> dict:
    return {"error": {"code": code, "message": message, **extra}}


def register_exception_handlers(app: FastAPI) -> None:
    @app.exception_handler(StarletteHTTPException)
    async def _http(_: Request, exc: StarletteHTTPException) -> JSONResponse:
        code = {403: "forbidden", 404: "not_found", 405: "method_not_allowed"}.get(exc.status_code, "http_error")
        return JSONResponse(status_code=exc.status_code, content=_body(code, str(exc.detail)),
                            headers=getattr(exc, "headers", None))

    @app.exception_handler(RequestValidationError)
    async def _validation(_: Request, exc: RequestValidationError) -> JSONResponse:
        details = [{"loc": list(e.get("loc", [])), "msg": e.get("msg"), "type": e.get("type")} for e in exc.errors()]
        return JSONResponse(status_code=422, content=_body("validation_error", "Request validation failed.",
                                                           details=details))

    @app.exception_handler(PermissionError)
    async def _forbidden(_: Request, exc: PermissionError) -> JSONResponse:
        return JSONResponse(status_code=403, content=_body("write_actions_disabled", str(exc)))

    @app.exception_handler(ValueError)
    async def _bad_request(_: Request, exc: ValueError) -> JSONResponse:
        # The core raises ValueError for unknown machines/instances/jobs ("... was not found") and bad input.
        message = str(exc)
        if "not found" in message.lower():
            return JSONResponse(status_code=404, content=_body("not_found", message))
        return JSONResponse(status_code=400, content=_body("invalid_request", message))

    @app.exception_handler(ArmError)
    async def _upstream(_: Request, exc: ArmError) -> JSONResponse:
        log.warning("Azure Resource Manager error %s: %s", exc.status, exc)
        status = 403 if exc.status in (401, 403) else 404 if exc.status == 404 else 502
        return JSONResponse(status_code=status, content=_body("azure_error", str(exc), upstream_status=exc.status))
