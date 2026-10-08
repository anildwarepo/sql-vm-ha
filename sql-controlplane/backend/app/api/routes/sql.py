"""SQL management: read endpoints over Arc SQL, Update Manager, maintenance schedules and Defender."""

from __future__ import annotations

from typing import Annotated, Any

from fastapi import APIRouter, Path, Query

from ...schemas.common import ERROR_RESPONSES
from ...schemas.sql import (AvailabilityGroups, Databases, Inventory, JobOutput, MaintenanceWindows, OperationStatus,
                            OrchestrationJobs, Overview, PatchCompliance, PatchHistory, PerformanceSnapshot,
                            ResourceGraphQuery, ResourceGraphResult, SecurityPosture)
from ..deps import ClientGuard, SqlService

router = APIRouter(prefix="/api/sql", tags=["SQL management"], responses=ERROR_RESPONSES)

Machine = Annotated[str | None, Query(description="Arc machine name, e.g. SQL-VM-1. Omit for all SQL hosts.")]


@router.get("/overview", response_model=Overview, summary="KPIs and prioritized findings")
def overview(sql=SqlService) -> Any:
    return sql.overview()


@router.get("/instances", response_model=Inventory, summary="Arc SQL instances and their hosts")
def instances(sql=SqlService) -> Any:
    return sql.inventory()


@router.get("/availability-groups", response_model=AvailabilityGroups, summary="Always On availability groups")
def availability_groups(
        live: Annotated[bool, Query(description="Query each replica live through the Arc AG API")] = True,
        sql=SqlService) -> Any:
    return sql.availability_groups(live)


@router.get("/patching", response_model=PatchCompliance, summary="Outstanding updates per SQL host")
def patching(machine: Machine = None, sql=SqlService) -> Any:
    return sql.patch_compliance(machine)


@router.get("/patching/history", response_model=PatchHistory, summary="Maintenance runs and installations")
def patch_history(days: Annotated[int, Query(ge=1, le=90)] = 30, sql=SqlService) -> Any:
    return sql.patch_history(days)


@router.get("/patching/plan/{machine}", summary="AG-safety preflight for patching one node now (read-only)")
def patch_plan(machine: Annotated[str, Path(description="Arc machine name")], sql=SqlService) -> dict[str, Any]:
    return sql.plan_patch_install(machine)


@router.get("/maintenance-windows", response_model=MaintenanceWindows,
            summary="Schedules, next windows and wave risks")
def maintenance_windows(count: Annotated[int, Query(ge=1, le=60, description="Windows per schedule")] = 4,
                        sql=SqlService) -> Any:
    return sql.maintenance_windows(count)


@router.get("/security", response_model=SecurityPosture, summary="Defender findings, alerts and security gaps")
def security(severity: Annotated[str | None, Query(description="High | Medium | Low")] = None,
             machine: Machine = None, sql=SqlService) -> Any:
    return sql.security_posture(severity, machine)


@router.get("/databases", response_model=Databases, summary="Databases on Arc SQL instances")
def databases(instance: Annotated[str | None, Query()] = None,
              include_system: Annotated[bool, Query()] = True, sql=SqlService) -> Any:
    return sql.databases(instance, include_system)


@router.get("/jobs", response_model=OrchestrationJobs, summary="AG-aware patching runbook jobs")
def jobs(limit: Annotated[int, Query(ge=1, le=100)] = 20, days: Annotated[int, Query(ge=1, le=90)] = 30,
         sql=SqlService) -> Any:
    return sql.orchestration_jobs(limit, days)


@router.get("/jobs/{job_name}/output", response_model=JobOutput, summary="Output log of one runbook job")
def job_output(job_name: Annotated[str, Path(pattern=r"^[0-9a-fA-F-]{36}$")],
               automation_account: Annotated[str | None, Query()] = None, sql=SqlService) -> Any:
    return sql.job_output(job_name, automation_account)


@router.get("/performance", response_model=PerformanceSnapshot,
            summary="Live DMV performance snapshot (20-40 s, Arc Run Command)")
def performance(machine: Machine = None, sql=SqlService) -> Any:
    return sql.performance(machine)


@router.post("/resource-graph", response_model=ResourceGraphResult, dependencies=[ClientGuard],
             summary="Read-only Azure Resource Graph query")
def resource_graph(body: ResourceGraphQuery, sql=SqlService) -> Any:
    return sql.resource_graph(body.query, body.max_rows)


@router.get("/operations", response_model=OperationStatus, summary="Status of an async Azure operation")
def operation(url: Annotated[str, Query(description="operation_url returned by an action")], sql=SqlService) -> Any:
    return sql.operation_status(url)
