"""SQL actions: patch assessment, patch installation and AG failover.

Every action previews with confirm=false and only executes with confirm=true when SQLHA_ENABLE_WRITE_ACTIONS=true.
The core library enforces the AG safety rules (never patch the primary or both replicas, never fail over to a
replica that isn't failover-ready).
"""

from __future__ import annotations

from typing import Annotated, Any

from fastapi import APIRouter, Path

from ...schemas.actions import ConfirmRequest, FailoverRequest, InstallPatchesRequest
from ...schemas.common import ERROR_RESPONSES, ActionResult
from ..deps import ClientGuard, SqlService

router = APIRouter(prefix="/api/sql/actions", tags=["SQL actions"], responses=ERROR_RESPONSES,
                   dependencies=[ClientGuard])

MachinePath = Annotated[str, Path(description="Arc machine name, e.g. SQL-VM-2")]


@router.post("/machines/{machine}/assessment", response_model=ActionResult,
             summary="Run an Update Manager patch assessment (scan only)")
def assessment(machine: MachinePath, body: ConfirmRequest, sql=SqlService) -> Any:
    return sql.trigger_assessment(machine, body.confirm)


@router.post("/machines/{machine}/periodic-assessment", response_model=ActionResult,
             summary="Enable periodic (24 h) assessment")
def periodic_assessment(machine: MachinePath, body: ConfirmRequest, sql=SqlService) -> Any:
    return sql.enable_periodic_assessment(machine, body.confirm)


@router.post("/machines/{machine}/install-patches", response_model=ActionResult,
             summary="AG-safe on-demand patch install on one node (may reboot)")
def install_patches(machine: MachinePath, body: InstallPatchesRequest, sql=SqlService) -> Any:
    return sql.install_patches(machine, classifications=body.classifications, kb_include=body.kb_include,
                               kb_exclude=body.kb_exclude, max_duration_hours=body.max_duration_hours,
                               reboot_setting=body.reboot_setting, failover_first=body.failover_first,
                               confirm=body.confirm)


@router.post("/failover", response_model=ActionResult, summary="Planned (no data loss) AG failover")
def failover(body: FailoverRequest, sql=SqlService) -> Any:
    return sql.failover(body.target_instance, body.ag_name, body.confirm)
