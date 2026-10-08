"""Tool registry shared by the MCP server and the Foundry hosted agent.

Tool names are identical on both surfaces so the SKILL.md files work unchanged.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from typing import Annotated, Any, Callable

from pydantic import Field

from . import service

MAX_CHARS = int(os.environ.get("SQLHA_MAX_TOOL_CHARS", "60000"))


def _out(result: Any) -> str:
    text = json.dumps(result, default=str, indent=1)
    if len(text) > MAX_CHARS:
        text = text[:MAX_CHARS] + '\n... [truncated; narrow the request with the machine/severity filters]'
    return text


def _guard(fn: Callable[[], Any]) -> str:
    try:
        return _out(fn())
    except PermissionError as exc:
        return _out({"error": "write_actions_disabled", "message": str(exc)})
    except ValueError as exc:
        return _out({"error": "invalid_request", "message": str(exc)})
    except Exception as exc:  # surface ARM/RBAC errors to the model instead of failing the turn
        return _out({"error": type(exc).__name__, "message": str(exc)})


# --------------------------------------------------------------------------- read-only


def sqlha_get_overview() -> str:
    """Start here. Overall health of the Arc-managed SQL Server estate: KPIs (instances, AG health, outstanding
    patches, next maintenance window, last patch run) and a prioritized list of findings across availability,
    patching, maintenance and security."""
    return _guard(service.get_overview)


def sqlha_get_inventory() -> str:
    """SQL Server instances enabled by Azure Arc: version, edition, build (patch level), license, Arc/host status,
    hosting cloud (e.g. AWS), OS, Arc agent version, Always On role and AG membership."""
    return _guard(service.get_inventory)


def sqlha_get_availability_groups(
    live: Annotated[bool, Field(description="Query live state from each replica via the Arc AG API (default true). "
                                            "False returns the cached Resource Graph inventory.")] = True,
) -> str:
    """Always On availability groups: primary/secondary roles, preferred primary, availability and failover modes,
    connection and synchronization health per replica, per-database synchronization state, and whether each
    secondary is ready for a planned (no data loss) failover."""
    return _guard(lambda: service.get_availability_groups(live=live))


def sqlha_get_patch_compliance(
    machine: Annotated[str | None, Field(description="Arc machine name (e.g. SQL-VM-1). Omit for all SQL hosts.")] = None,
) -> str:
    """Outstanding (missing) updates per SQL host from the latest Azure Update Manager assessment, including SQL
    Server cumulative/security updates, MSRC severity, age, reboot pending, assessment freshness and last install."""
    return _guard(lambda: service.get_patch_compliance(machine))


def sqlha_get_patch_history(
    days: Annotated[int, Field(description="Look-back window in days.", ge=1, le=90)] = 30,
) -> str:
    """Past Update Manager maintenance runs for the SQL hosts' schedules (status, wave, errors such as
    cancellations) and patch installation results per machine."""
    return _guard(lambda: service.get_patch_history(days))


def sqlha_get_maintenance_windows(
    count: Annotated[int, Field(description="How many upcoming windows to compute per schedule.", ge=1, le=12)] = 4,
) -> str:
    """Maintenance configurations that patch the SQL hosts: recurrence, time zone, duration, classifications,
    excluded KBs, AG wave/target/partner/preferred primary, the next windows (local and UTC), and scheduling risks
    such as overlapping waves or hosts with no or multiple schedules."""
    return _guard(lambda: service.get_maintenance_windows(count))


def sqlha_get_security_posture(
    severity: Annotated[str | None, Field(description="Only return Defender findings of this severity: High, Medium or Low.")] = None,
    machine: Annotated[str | None, Field(description="Only return findings for this Arc machine.")] = None,
) -> str:
    """Security risks: Microsoft Defender for Cloud recommendations (SQL vulnerability assessment and host
    hardening), active Defender alerts, missing security patches, Defender for SQL status, mirroring endpoint
    encryption, and user databases without TDE."""
    def run() -> Any:
        data = service.get_security_posture()
        if severity or machine:
            data["defender_findings"] = [
                f for f in data["defender_findings"]
                if (not severity or (f["severity"] or "").lower() == severity.lower())
                and (not machine or (f["machine"] or "").lower() == machine.lower())]
        return data
    return _guard(run)


def sqlha_get_databases(
    instance: Annotated[str | None, Field(description="Only databases of this Arc SQL instance.")] = None,
) -> str:
    """Databases on the Arc SQL instances: state, recovery model, compatibility level, size, free space,
    encryption (TDE) and last backup times."""
    def run() -> Any:
        data = service.get_databases()
        if instance:
            data["databases"] = [d for d in data["databases"] if d["instance"].lower() == instance.lower()]
            data["database_count"] = len(data["databases"])
        return data
    return _guard(run)


def sqlha_get_orchestration_jobs(
    limit: Annotated[int, Field(description="Maximum jobs to return.", ge=1, le=100)] = 20,
    days: Annotated[int, Field(description="Look-back window in days.", ge=1, le=90)] = 30,
) -> str:
    """Recent runs of the AG-aware patching runbooks (Pre-SqlAgFailover moves the AG off the node before patching,
    Post-SqlAgValidate checks health and fails back). Use to explain cancelled or failed patch waves."""
    return _guard(lambda: service.get_orchestration_jobs(limit, days))


def sqlha_get_job_output(
    job_name: Annotated[str, Field(description="Automation job name (GUID) from sqlha_get_orchestration_jobs.")],
    automation_account: Annotated[str | None, Field(description="Automation account name, if known.")] = None,
) -> str:
    """Output log of one patching runbook job, to diagnose why a wave was cancelled or failed."""
    return _guard(lambda: service.get_job_output(job_name, automation_account))


def sqlha_plan_patch_install(
    machine: Annotated[str, Field(description="Arc machine name to patch, e.g. SQL-VM-2.")],
) -> str:
    """Read-only AG-safety preflight for patching one node now: live replica roles and health, blockers (node is
    primary, partner unhealthy, partner already patching, Arc disconnected), warnings, and the outstanding updates."""
    return _guard(lambda: service.plan_patch_install(machine))


def sqlha_get_performance_snapshot(
    machine: Annotated[str | None, Field(description="Arc machine name, e.g. SQL-VM-1. Omit for all SQL hosts.")] = None,
) -> str:
    """Live SQL Server performance metrics from each host (takes ~20-40 s): CPU (now / 30-min avg / max), memory
    (page life expectancy, server memory, grants pending, OS memory state), batch requests, transactions, user
    sessions, active/blocked requests, top waits and IO latency since startup, volume free space, and Always On
    log send / redo queues, rates and secondary lag. Runs a fixed read-only DMV script through Arc Run Command."""
    return _guard(lambda: service.get_performance(machine))


def sqlha_get_operation_status(
    operation_url: Annotated[str, Field(description="operation_url returned by an assessment or install tool.")],
) -> str:
    """Status of an Azure async operation started by sqlha_trigger_patch_assessment or sqlha_install_patches."""
    return _guard(lambda: service.get_operation_status(operation_url))


def sqlha_query_resource_graph(
    query: Annotated[str, Field(description="Azure Resource Graph KQL query (read-only).")],
) -> str:
    """Escape hatch for metadata questions the other tools don't answer. Runs a read-only Azure Resource Graph
    query (tables: resources, patchassessmentresources, patchinstallationresources, maintenanceresources,
    securityresources) scoped to the configured subscriptions. Returns up to 200 rows."""
    return _guard(lambda: service.run_resource_graph_query(query))


# --------------------------------------------------------------------------- write (guarded)


def sqlha_trigger_patch_assessment(
    machine: Annotated[str, Field(description="Arc machine name.")],
    confirm: Annotated[bool, Field(description="false = describe only; true = start the assessment. "
                                               "Only set true after the user explicitly agreed.")] = False,
) -> str:
    """WRITE (safe): start an on-demand Update Manager patch assessment on one SQL host. Scans only; installs nothing."""
    return _guard(lambda: service.trigger_patch_assessment(machine, confirm))


def sqlha_enable_periodic_assessment(
    machine: Annotated[str, Field(description="Arc machine name.")],
    confirm: Annotated[bool, Field(description="false = describe only; true = apply. Only after explicit user approval.")] = False,
) -> str:
    """WRITE (safe): set the machine's Update Manager assessment mode to AutomaticByPlatform (assess every 24h)."""
    return _guard(lambda: service.enable_periodic_assessment(machine, confirm))


def sqlha_install_patches(
    machine: Annotated[str, Field(description="Arc machine name to patch now.")],
    classifications: Annotated[list[str] | None, Field(description="Windows update classifications to include, e.g. "
                                                                   "['Critical','Security']. Default: all except FeaturePack/Tools.")] = None,
    kb_include: Annotated[list[str] | None, Field(description="Only install these KB numbers (digits only).")] = None,
    kb_exclude: Annotated[list[str] | None, Field(description="KB numbers to skip.")] = None,
    max_duration_hours: Annotated[float, Field(description="Maximum install duration in hours.", ge=0.5, le=3.9)] = 2.0,
    reboot_setting: Annotated[str, Field(description="IfRequired, Never or Always.")] = "IfRequired",
    failover_first: Annotated[bool, Field(description="If the node is the AG primary, do a planned failover to a "
                                                      "failover-ready partner before patching.")] = False,
    confirm: Annotated[bool, Field(description="false = preflight + request preview; true = execute. "
                                               "Only after the user explicitly approved the preview.")] = False,
) -> str:
    """WRITE (disruptive): AG-safe on-demand patch installation on ONE SQL host via Update Manager. Runs the AG
    preflight first and refuses if the node is primary (unless failover_first) or the partner is unhealthy.
    May reboot the node. Never patch both replicas at the same time."""
    return _guard(lambda: service.install_patches(machine, classifications, kb_include, kb_exclude,
                                                  max_duration_hours, reboot_setting, failover_first, confirm))


def sqlha_failover_availability_group(
    target_instance: Annotated[str, Field(description="Arc SQL instance that should become primary, e.g. SQL-VM-2.")],
    ag_name: Annotated[str | None, Field(description="Availability group name; required if the instance hosts several AGs.")] = None,
    confirm: Annotated[bool, Field(description="false = readiness check only; true = fail over. Only after explicit user approval.")] = False,
) -> str:
    """WRITE (disruptive): planned, no-data-loss failover of an Always On AG to a synchronized synchronous-commit
    secondary using the Arc AG API, then verifies the new primary. Client connections drop briefly."""
    return _guard(lambda: service.failover_availability_group(target_instance, ag_name, confirm))


@dataclass(frozen=True)
class ToolSpec:
    fn: Callable[..., str]
    read_only: bool = True
    destructive: bool = False
    hosted: bool = True  # also exposed by the Foundry hosted agent

    @property
    def name(self) -> str:
        return self.fn.__name__


TOOLS: list[ToolSpec] = [
    ToolSpec(sqlha_get_overview),
    ToolSpec(sqlha_get_inventory),
    ToolSpec(sqlha_get_availability_groups),
    ToolSpec(sqlha_get_patch_compliance),
    ToolSpec(sqlha_get_patch_history),
    ToolSpec(sqlha_get_maintenance_windows),
    ToolSpec(sqlha_get_security_posture),
    ToolSpec(sqlha_get_databases),
    ToolSpec(sqlha_get_orchestration_jobs),
    ToolSpec(sqlha_get_job_output),
    ToolSpec(sqlha_plan_patch_install),
    ToolSpec(sqlha_get_performance_snapshot),
    ToolSpec(sqlha_get_operation_status),
    ToolSpec(sqlha_query_resource_graph),
    ToolSpec(sqlha_trigger_patch_assessment, read_only=False),
    ToolSpec(sqlha_enable_periodic_assessment, read_only=False),
    ToolSpec(sqlha_install_patches, read_only=False, destructive=True),
    ToolSpec(sqlha_failover_availability_group, read_only=False, destructive=True),
]
