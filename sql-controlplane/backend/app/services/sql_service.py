"""SQL management service: a facade over sqlha.service used by the SQL routes."""

from __future__ import annotations

from typing import Any

from sqlha import service
from sqlha.arm import get_client


class SqlManagementService:
    """Read and write operations against SQL Server enabled by Azure Arc, Update Manager and Defender.

    All methods are blocking (they call Azure); FastAPI runs the sync route handlers in its thread pool.
    """

    # ------------------------------------------------------------ configuration

    @property
    def write_actions_enabled(self) -> bool:
        return get_client().settings.enable_write_actions

    @property
    def perf_snapshot_enabled(self) -> bool:
        return get_client().settings.enable_perf_snapshot

    def scope(self) -> dict[str, list[str]]:
        s = get_client().settings
        return {"subscriptions": s.subscription_ids or ["(all accessible)"], "resource_groups": s.resource_groups or ["(all)"]}

    # ------------------------------------------------------------ read

    def overview(self) -> dict[str, Any]:
        return service.get_overview()

    def inventory(self) -> dict[str, Any]:
        return service.get_inventory()

    def availability_groups(self, live: bool = True) -> dict[str, Any]:
        return service.get_availability_groups(live=live)

    def patch_compliance(self, machine: str | None = None) -> dict[str, Any]:
        return service.get_patch_compliance(machine)

    def patch_history(self, days: int = 30) -> dict[str, Any]:
        return service.get_patch_history(days)

    def maintenance_windows(self, count: int = 4) -> dict[str, Any]:
        return service.get_maintenance_windows(count)

    def security_posture(self, severity: str | None = None, machine: str | None = None) -> dict[str, Any]:
        data = service.get_security_posture()
        if severity or machine:
            data["defender_findings"] = [
                f for f in data["defender_findings"]
                if (not severity or (f.get("severity") or "").lower() == severity.lower())
                and (not machine or (f.get("machine") or "").lower() == machine.lower())]
        return data

    def databases(self, instance: str | None = None, include_system: bool = True) -> dict[str, Any]:
        data = service.get_databases()
        rows = [d for d in data["databases"]
                if (not instance or d["instance"].lower() == instance.lower()) and (include_system or not d["system"])]
        return {"database_count": len(rows), "databases": rows}

    def orchestration_jobs(self, limit: int = 20, days: int = 30) -> dict[str, Any]:
        return service.get_orchestration_jobs(limit, days)

    def job_output(self, job_name: str, automation_account: str | None = None) -> dict[str, Any]:
        return service.get_job_output(job_name, automation_account)

    def performance(self, machine: str | None = None) -> dict[str, Any]:
        return service.get_performance(machine)

    def resource_graph(self, query: str, max_rows: int = 200) -> dict[str, Any]:
        return service.run_resource_graph_query(query, max_rows)

    def operation_status(self, url: str) -> dict[str, Any]:
        return service.get_operation_status(url)

    def plan_patch_install(self, machine: str) -> dict[str, Any]:
        return service.plan_patch_install(machine)

    # ------------------------------------------------------------ write (preview unless confirm=True)

    def trigger_assessment(self, machine: str, confirm: bool) -> dict[str, Any]:
        return service.trigger_patch_assessment(machine, confirm)

    def enable_periodic_assessment(self, machine: str, confirm: bool) -> dict[str, Any]:
        return service.enable_periodic_assessment(machine, confirm)

    def install_patches(self, machine: str, *, classifications: list[str] | None, kb_include: list[str] | None,
                        kb_exclude: list[str] | None, max_duration_hours: float, reboot_setting: str,
                        failover_first: bool, confirm: bool) -> dict[str, Any]:
        return service.install_patches(machine, classifications, kb_include, kb_exclude, max_duration_hours,
                                       reboot_setting, failover_first, confirm)

    def failover(self, target_instance: str, ag_name: str | None, confirm: bool) -> dict[str, Any]:
        return service.failover_availability_group(target_instance, ag_name, confirm)
