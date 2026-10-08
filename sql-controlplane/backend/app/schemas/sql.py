"""Response models for the SQL management API (shapes produced by sqlha.service)."""

from __future__ import annotations

from typing import Any

from pydantic import Field

from .common import ApiModel, Finding, Scalar

# ---------------------------------------------------------------- inventory


class HostInfo(ApiModel):
    id: str | None = None
    status: str | None = Field(None, description="Arc agent status: Connected | Disconnected | Expired")
    last_status_change: str | None = None
    os: str | None = None
    os_version: str | None = None
    arc_agent_version: str | None = None
    cloud: str | None = Field(None, description="Hosting cloud from Arc metadata or tags, e.g. AWS")
    logical_cores: Scalar = None
    memory_gb: Scalar = None
    tags: dict[str, Any] = {}


class SqlInstance(ApiModel):
    name: str
    id: str
    machine: str | None = None
    version: str | None = None
    edition: str | None = None
    build: str | None = Field(None, description="Current patch level, e.g. 16.0.4255.1")
    status: str | None = None
    license_type: str | None = None
    vcores: Scalar = None
    always_on_role: str | None = None
    availability_groups: list[str] = []
    defender_status: str | None = None
    host: HostInfo


class OtherSqlService(ApiModel):
    name: str
    machine: str | None = None
    service_type: str | None = None
    version: str | None = None
    status: str | None = None


class Inventory(ApiModel):
    instance_count: int
    connected_count: int
    instances: list[SqlInstance]
    other_sql_services: list[OtherSqlService] = []


# ---------------------------------------------------------------- Always On


class ReplicaState(ApiModel):
    instance: str
    role: str | None = Field(None, description="PRIMARY | SECONDARY")
    mode: str | None = None
    connected: str | None = None
    replica_health: str | None = None
    collected: str | None = None
    fresh: bool | None = None
    healthy: bool | None = None
    failover_ready: bool | None = None
    message: str | None = None


class Replica(ApiModel):
    replica: str
    role: str | None = None
    availability_mode: str | None = None
    failover_mode: str | None = None
    connected: str | None = None
    sync_health: str | None = None


class DatabaseReplicaState(ApiModel):
    replica: str
    is_primary: bool | None = None
    sync_state: str | None = None
    sync_health: str | None = None
    suspended: bool | None = None


class AgDatabase(ApiModel):
    database: str
    replicas: list[DatabaseReplicaState]


class AvailabilityGroup(ApiModel):
    name: str
    primary_replica: str | None = None
    preferred_primary: str | None = None
    on_preferred_primary: bool | None = None
    healthy: bool | None = None
    cluster_type: str | None = None
    source: str | None = None
    nodes: list[ReplicaState] = []
    replicas: list[Replica] = []
    databases: list[AgDatabase] = []
    errors: list[dict[str, Any]] = []


class AvailabilityGroups(ApiModel):
    availability_group_count: int
    availability_groups: list[AvailabilityGroup]


# ---------------------------------------------------------------- patching


class MissingUpdate(ApiModel):
    kb: str | None = None
    name: str | None = None
    classifications: list[str] = []
    msrc_severity: str | None = None
    published: str | None = None
    age_days: float | None = None
    reboot_behavior: str | None = None
    is_sql_server_update: bool = False


class MachinePatchState(ApiModel):
    machine: str | None = None
    machine_id: str
    assessment_status: str | None = None
    assessment_mode: str | None = None
    last_assessed: str | None = None
    assessment_age_days: float | None = None
    assessment_stale: bool = False
    reboot_pending: bool | None = None
    outstanding_total: int = 0
    security_or_critical: int = 0
    msrc_critical: int = 0
    sql_server_updates: list[MissingUpdate] = []
    outstanding: list[MissingUpdate] = []
    last_installation: dict[str, Any] | None = None


class PatchCompliance(ApiModel):
    machine_count: int
    outstanding_total: int
    security_or_critical_total: int
    machines: list[MachinePatchState]


class MaintenanceRun(ApiModel):
    run_id: str | None = None
    maintenance_configuration: str | None = None
    target_node: str | None = None
    wave: str | None = None
    status: str | None = None
    start: str | None = None
    end: str | None = None
    error: str | None = None


class PatchHistory(ApiModel):
    days: int
    maintenance_runs: list[MaintenanceRun]
    installations: list[dict[str, Any]]


# ---------------------------------------------------------------- maintenance windows


class MaintenanceWindowOccurrence(ApiModel):
    start_local: str | None = None
    end_local: str | None = None
    start_utc: str | None = None
    end_utc: str | None = None
    in_progress: bool | None = None
    error: str | None = None


class MaintenanceConfiguration(ApiModel):
    id: str
    name: str
    recur_every: str | None = None
    start: str | None = None
    duration: str | None = None
    time_zone: str | None = None
    ag_aware: bool | None = None
    ag_name: str | None = None
    wave: str | None = None
    target_node: str | None = None
    partner_node: str | None = None
    preferred_primary: str | None = None
    classifications: list[str] = []
    kb_exclude: list[str] = []
    assigned_machines: list[str] = []
    next_windows: list[MaintenanceWindowOccurrence] = []


class MachineSchedule(ApiModel):
    machine: str
    assignments: list[dict[str, Any]] = []
    next_window: MaintenanceWindowOccurrence | None = None


class MaintenanceWindows(ApiModel):
    configurations: list[MaintenanceConfiguration]
    machines: list[MachineSchedule]
    risks: list[Finding]


# ---------------------------------------------------------------- security


class DefenderFinding(ApiModel):
    title: str | None = None
    severity: str | None = None
    machine: str | None = None
    target: str | None = None
    description: str | None = None
    remediation: str | None = None


class SecurityPosture(ApiModel):
    defender_unhealthy_by_severity: dict[str, int] = {}
    defender_healthy_count: int = 0
    defender_findings: list[DefenderFinding] = []
    active_alerts: list[dict[str, Any]] = []
    missing_security_patches: list[dict[str, Any]] = []
    instance_controls: list[dict[str, Any]] = []
    unencrypted_user_databases: list[dict[str, Any]] = []


# ---------------------------------------------------------------- databases, jobs, performance


class Database(ApiModel):
    instance: str
    name: str
    system: bool = False
    state: str | None = None
    recovery_model: str | None = None
    size_mb: float | None = None
    encrypted: bool | None = None


class Databases(ApiModel):
    database_count: int
    databases: list[Database]


class OrchestrationJob(ApiModel):
    automation_account: str | None = None
    job_name: str | None = None
    runbook: str | None = None
    status: str | None = None
    created: str | None = None
    start: str | None = None
    end: str | None = None
    error: str | None = None


class OrchestrationJobs(ApiModel):
    jobs: list[OrchestrationJob]
    failed_count: int = 0


class JobOutput(ApiModel):
    automation_account: str
    job_name: str
    truncated: bool
    output: str


class PerformanceNode(ApiModel):
    machine: str
    ok: bool
    error: str | None = None
    summary: dict[str, Any] | None = None


class PerformanceSnapshot(ApiModel):
    source: str
    notes: str | None = None
    nodes: list[PerformanceNode]


class Kpis(ApiModel):
    overall: str = Field(description="critical | warning | healthy")
    findings_by_severity: dict[str, int] = {}
    instances_total: int = 0
    instances_connected: int = 0
    ag_total: int = 0
    ag_healthy: int = 0
    outstanding_patches: int = 0
    security_patches: int = 0
    next_window: dict[str, Any] | None = None
    last_run: dict[str, Any] | None = None
    defender_unhealthy: int = 0


class Overview(ApiModel):
    generated_at: str
    kpis: Kpis
    findings: list[Finding]
    errors: dict[str, str] = {}


class ResourceGraphQuery(ApiModel):
    query: str = Field(min_length=1, max_length=8000,
                       examples=["resources | where type =~ 'microsoft.hybridcompute/machines' | project name"])
    max_rows: int = Field(200, ge=1, le=1000)


class ResourceGraphResult(ApiModel):
    row_count: int
    rows: list[dict[str, Any]]


class OperationStatus(ApiModel):
    http_status: int
    body: dict[str, Any] | list[Any] | None = None
