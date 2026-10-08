"""Models for the dashboard (UI) API."""

from __future__ import annotations

from typing import Any

from pydantic import Field

from .common import ApiModel, Finding
from .sql import (AvailabilityGroups, Databases, Inventory, Kpis, MaintenanceWindows, OrchestrationJobs,
                  PatchCompliance, PatchHistory, SecurityPosture)


class DashboardSnapshot(ApiModel):
    """Everything the UI renders, collected in parallel. A section is null when it failed (see `errors`)."""

    generated_at: str
    scope: dict[str, Any] = {}
    errors: dict[str, str] = Field(default_factory=dict, description="Section name -> error message")
    kpis: Kpis
    findings: list[Finding]
    inventory: Inventory | None = None
    availability_groups: AvailabilityGroups | None = None
    patching: PatchCompliance | None = None
    history: PatchHistory | None = None
    maintenance: MaintenanceWindows | None = None
    security: SecurityPosture | None = None
    databases: Databases | None = None
    jobs: OrchestrationJobs | None = None


class RefreshResult(ApiModel):
    generated_at: str
    duration_s: float
    kpis: Kpis
    section_errors: dict[str, str] = {}
