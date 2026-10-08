"""Shared schema building blocks."""

from __future__ import annotations

from typing import Any, Literal, Union

from pydantic import BaseModel, ConfigDict, Field

# Azure returns some numeric properties as strings (e.g. vCore "4"); keep them as-is.
Scalar = Union[str, int, float, bool, None]


class ApiModel(BaseModel):
    """Base for response models. Unknown fields from the core library pass through unchanged."""

    model_config = ConfigDict(extra="allow", populate_by_name=True)


class ErrorDetail(BaseModel):
    code: str = Field(examples=["write_actions_disabled"])
    message: str
    upstream_status: int | None = None
    details: list[dict[str, Any]] | None = Field(None, description="Validation errors (422 only)")


class ErrorResponse(BaseModel):
    error: ErrorDetail


Severity = Literal["critical", "high", "medium", "low", "info"]


class Finding(ApiModel):
    severity: str = Field(description="critical | high | medium | low | info")
    category: str = Field(description="availability | patching | maintenance | security | connectivity")
    title: str
    detail: str | None = None
    resource: str | None = None
    recommendation: str | None = None


class ActionResult(ApiModel):
    """Result of a write action. With confirm=false it's a preview; nothing is changed."""

    executed: bool | None = Field(None, description="True when the action ran; false/None for previews or refusals")
    message: str | None = None
    next_step: str | None = None
    operation_url: str | None = Field(None, description="Poll with GET /api/sql/operations?url=...")


ERROR_RESPONSES: dict[int | str, dict[str, Any]] = {
    400: {"model": ErrorResponse, "description": "Invalid request"},
    403: {"model": ErrorResponse, "description": "Forbidden (write actions disabled or Azure RBAC)"},
    404: {"model": ErrorResponse, "description": "Not found in the configured scope"},
    422: {"model": ErrorResponse, "description": "Request validation failed"},
    502: {"model": ErrorResponse, "description": "Azure Resource Manager error"},
}
