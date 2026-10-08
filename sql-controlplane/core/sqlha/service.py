"""Read and act on SQL Server enabled by Azure Arc, Azure Update Manager and Defender data.

Every public function returns JSON-serializable dicts so it can be exposed unchanged as
an MCP tool, a Foundry hosted-agent function tool, or dashboard input.
"""

from __future__ import annotations

import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from typing import Any, Callable

from . import schedule
from .arm import API_ARC_DATA, API_AUTOMATION, API_HYBRID_COMPUTE, API_MAINTENANCE, ArmError, get_client

SEVERITY_ORDER = {"critical": 0, "high": 1, "medium": 2, "low": 3, "info": 4}
STALE_ASSESSMENT_DAYS = 3
# Maintenance runs that are scheduled but haven't begun; they aren't "the last run".
NOT_STARTED = {"NotStarted", "Pending", "Scheduled"}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

_cache: dict[str, tuple[float, Any]] = {}
_cache_lock = threading.Lock()
_key_locks: dict[str, threading.Lock] = {}


def _cached(key: str, fn: Callable[[], Any], ttl: int = 60) -> Any:
    """Memoize `fn` for `ttl` seconds. Single-flight: parallel callers of the same key wait for one query."""
    def fresh() -> Any:
        hit = _cache.get(key)
        return hit if hit and time.time() - hit[0] < ttl else None

    with _cache_lock:
        if hit := fresh():
            return hit[1]
        key_lock = _key_locks.setdefault(key, threading.Lock())
    with key_lock:
        with _cache_lock:
            if hit := fresh():
                return hit[1]
        value = fn()
        with _cache_lock:
            _cache[key] = (time.time(), value)
    return value


def clear_cache() -> None:
    with _cache_lock:
        _cache.clear()


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _dt(value: Any) -> datetime | None:
    if not value or not isinstance(value, str):
        return None
    text = value.strip().replace("Z", "+00:00")
    text = re.sub(r"(\.\d{6})\d+", r"\1", text)
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def _age_days(value: Any) -> float | None:
    parsed = _dt(value)
    return round((_now() - parsed).total_seconds() / 86400, 1) if parsed else None


def _lower(value: Any) -> str:
    return str(value or "").lower()


def _machine_name(resource_id: str) -> str | None:
    m = re.search(r"/machines/([^/]+)", resource_id or "", re.I)
    return m.group(1) if m else None


def _rg(resource_id: str) -> str | None:
    m = re.search(r"/resourcegroups/([^/]+)", resource_id or "", re.I)
    return m.group(1) if m else None


def _finding(severity: str, category: str, title: str, detail: str, resource: str | None = None,
             recommendation: str | None = None) -> dict[str, Any]:
    return {
        "severity": severity,
        "category": category,
        "title": title,
        "detail": detail,
        "resource": resource,
        "recommendation": recommendation,
    }


def _scope() -> str:
    return get_client().scope_filter()


# ---------------------------------------------------------------------------
# inventory
# ---------------------------------------------------------------------------


def _raw_instances() -> list[dict[str, Any]]:
    return _cached("instances", lambda: get_client().graph(f"""
resources
| where type =~ 'microsoft.azurearcdata/sqlserverinstances' {_scope()}
| project id, name, resourceGroup, location, subscriptionId, tags, properties
"""))


def _raw_machines() -> list[dict[str, Any]]:
    return _cached("machines", lambda: get_client().graph(f"""
resources
| where type =~ 'microsoft.hybridcompute/machines' {_scope()}
| project id, name, resourceGroup, location, subscriptionId, tags, properties
"""))


def _raw_ag_resources() -> list[dict[str, Any]]:
    return _cached("ag_resources", lambda: get_client().graph(f"""
resources
| where type =~ 'microsoft.azurearcdata/sqlserverinstances/availabilitygroups' {_scope()}
| project id, name, resourceGroup, properties
"""))


def _cloud_of(machine: dict[str, Any]) -> str:
    props = machine.get("properties") or {}
    tags = machine.get("tags") or {}
    for candidate in (
        (props.get("cloudMetadata") or {}).get("provider"),
        (props.get("detectedProperties") or {}).get("cloudprovider"),
        tags.get("EmulatedCloud"),
        tags.get("Cloud"),
    ):
        if candidate and candidate not in ("N/A", "Unknown"):
            return candidate
    return "On-premises/unknown"


def _engine_instances() -> list[dict[str, Any]]:
    return [i for i in _raw_instances() if (i.get("properties") or {}).get("serviceType", "Engine") == "Engine"]


def _machines_by_id() -> dict[str, dict[str, Any]]:
    return {_lower(m["id"]): m for m in _raw_machines()}


def resolve_machine(name_or_id: str) -> dict[str, Any]:
    """Find an Arc machine by name or resource id (case-insensitive)."""
    key = _lower(name_or_id).strip()
    for m in _raw_machines():
        if _lower(m["id"]) == key or _lower(m["name"]) == key:
            return m
    raise ValueError(f"Arc machine '{name_or_id}' was not found in the configured scope.")


def get_inventory() -> dict[str, Any]:
    """SQL Server instances enabled by Azure Arc and their host machines."""
    machines = _machines_by_id()
    ag_by_instance: dict[str, list[str]] = {}
    for ag in _raw_ag_resources():
        ag_by_instance.setdefault(_lower(_instance_id_of_ag(ag["id"])), []).append(ag["name"])

    instances, other_services = [], []
    for inst in _raw_instances():
        p = inst.get("properties") or {}
        host = machines.get(_lower(p.get("containerResourceId")), {})
        hp = host.get("properties") or {}
        row = {
            "name": inst["name"],
            "id": inst["id"],
            "resource_group": inst.get("resourceGroup"),
            "location": inst.get("location"),
            "machine": host.get("name") or _machine_name(p.get("containerResourceId", "")),
            "service_type": p.get("serviceType"),
            "instance_name": p.get("instanceName"),
            "version": p.get("version"),
            "edition": p.get("edition"),
            "build": p.get("patchLevel") or p.get("currentVersion"),
            "base_version": p.get("currentVersion"),
            "status": p.get("status"),
            "license_type": p.get("licenseType"),
            "vcores": p.get("vCore"),
            "hadr_enabled": p.get("isHadrEnabled"),
            "always_on_role": p.get("alwaysOnRole"),
            "availability_groups": ag_by_instance.get(_lower(inst["id"]), []),
            "defender_status": p.get("azureDefenderStatus"),
            "monitoring_enabled": (p.get("monitoring") or {}).get("enabled"),
            "tcp_port": p.get("tcpStaticPorts") or p.get("tcpDynamicPorts"),
            "mirroring_endpoint": p.get("databaseMirroringEndpoint"),
            "last_inventory_upload": p.get("lastInventoryUploadTime"),
            "host": {
                "id": host.get("id"),
                "status": hp.get("status"),
                "last_status_change": hp.get("lastStatusChange"),
                "os": hp.get("osSku"),
                "os_version": hp.get("osVersion"),
                "arc_agent_version": hp.get("agentVersion"),
                "cloud": _cloud_of(host) if host else None,
                "logical_cores": (hp.get("detectedProperties") or {}).get("logicalCoreCount"),
                "memory_gb": (hp.get("detectedProperties") or {}).get("totalPhysicalMemoryInGigabytes"),
                "tags": host.get("tags") or {},
            },
        }
        (instances if p.get("serviceType", "Engine") == "Engine" else other_services).append(row)

    return {
        "instance_count": len(instances),
        "connected_count": sum(1 for i in instances if i["status"] == "Connected"),
        "instances": sorted(instances, key=lambda r: r["name"]),
        "other_sql_services": sorted(
            [{k: r[k] for k in ("name", "machine", "service_type", "version", "status")} for r in other_services],
            key=lambda r: r["name"],
        ),
    }


# ---------------------------------------------------------------------------
# Always On availability groups
# ---------------------------------------------------------------------------


def _instance_id_of_ag(ag_id: str) -> str:
    return re.split(r"/availabilitygroups/", ag_id, flags=re.I)[0]


def _evaluate_view(view: dict[str, Any], requested_at: datetime) -> dict[str, Any]:
    """Health evaluation identical to Get-SqlAgState in the patching runbooks."""
    p = view.get("properties") or {}
    replicas = [r for r in ((p.get("replicas") or {}).get("value") or []) if r]
    databases = [d for d in ((p.get("databases") or {}).get("value") or []) if d]
    local_name = next((d.get("replicaName") for d in databases if d.get("isLocal")), None) or p.get("serverName")
    local = next((r for r in replicas if r.get("replicaName") == local_name), {}) or {}
    state, conf = local.get("state") or {}, local.get("configure") or {}
    s: dict[str, Any] = {
        "replica": local_name,
        "role": state.get("availabilityGroupReplicaRole"),
        "mode": conf.get("availabilityModeDescription"),
        "connected": state.get("connectedStateDescription"),
        "replica_health": state.get("synchronizationHealthDescription"),
        "collected": p.get("collectionTimestamp"),
        "fresh": False,
        "healthy": False,
        "failover_ready": False,
        "message": "",
    }
    mode_of = {r.get("replicaName"): (r.get("configure") or {}).get("availabilityModeDescription") for r in replicas}
    checked = databases if s["role"] == "PRIMARY" else [d for d in databases if d.get("isLocal")]
    bad = [
        d for d in checked
        if d.get("isSuspended") is True
        or (mode_of.get(d.get("replicaName")) == "SYNCHRONOUS_COMMIT" and d.get("synchronizationStateDescription") != "SYNCHRONIZED")
        or (mode_of.get(d.get("replicaName")) != "SYNCHRONOUS_COMMIT"
            and d.get("synchronizationStateDescription") not in ("SYNCHRONIZED", "SYNCHRONIZING"))
    ]
    disconnected = [r for r in replicas if (r.get("state") or {}).get("connectedStateDescription") != "CONNECTED"]
    collected = _dt(s["collected"])
    s["fresh"] = bool(collected and collected >= requested_at)
    if not s["fresh"]:
        s["message"] = f"stale data (collected {s['collected']})"
    elif s["role"] not in ("PRIMARY", "SECONDARY"):
        s["message"] = f"replica role is '{s['role']}'"
    elif s["connected"] != "CONNECTED":
        s["message"] = f"replica is {s['connected']}"
    elif s["replica_health"] != "HEALTHY":
        s["message"] = f"replica synchronization health is {s['replica_health']}"
    elif not [d for d in databases if d.get("isLocal")]:
        s["message"] = "no local availability databases"
    elif bad:
        s["message"] = f"{len(bad)} database copies not synchronized or suspended"
    elif s["role"] == "PRIMARY" and disconnected:
        s["message"] = f"{len(disconnected)} replicas not connected"
    else:
        s["healthy"] = True
    s["failover_ready"] = s["healthy"] and s["role"] == "SECONDARY" and s["mode"] == "SYNCHRONOUS_COMMIT"
    return {"evaluation": s, "replicas": replicas, "databases": databases, "info": p.get("info") or {}}


def _live_view(instance_id: str, ag_name: str) -> dict[str, Any]:
    settings = get_client().settings
    requested = _now() - timedelta(seconds=settings.ag_fresh_seconds)
    # One quick retry only: a node that is patching or rebooting answers HTTP 500 until it is back, and long
    # backoff made a single refresh take ~30 s. The failure is reported as "live query failed" for that node.
    resp = get_client().post(f"{instance_id}/availabilityGroups/{ag_name}/getDetailView?api-version={API_ARC_DATA}",
                             attempts=2)
    return _evaluate_view(resp.json(), requested)


def _preferred_primaries() -> dict[str, str]:
    """AG name -> preferred primary from the AG-aware maintenance configuration tags."""
    out: dict[str, str] = {}
    for mc in _raw_maintenance_configs():
        tags = mc.get("tags") or {}
        if tags.get("SqlAgName") and tags.get("SqlAgPreferredPrimary"):
            out[_lower(tags["SqlAgName"])] = tags["SqlAgPreferredPrimary"]
    return out


def get_availability_groups(live: bool = True) -> dict[str, Any]:
    """Always On availability group topology and health, live from the Arc AG API when `live`."""
    groups: dict[str, dict[str, Any]] = {}
    for ag in _raw_ag_resources():
        p = ag.get("properties") or {}
        key = p.get("availabilityGroupId") or _lower(ag["name"])
        g = groups.setdefault(key, {
            "name": ag["name"],
            "availability_group_id": p.get("availabilityGroupId"),
            "resource_group": ag.get("resourceGroup"),
            "members": [],
            "info": p.get("info") or {},
            "inventory_collected": p.get("collectionTimestamp"),
        })
        g["members"].append({"instance": p.get("serverName") or _instance_id_of_ag(ag["id"]).rsplit("/", 1)[-1],
                             "instance_id": _instance_id_of_ag(ag["id"]), "ag_resource_id": ag["id"]})

    preferred = _cached("preferred_primaries", _preferred_primaries)
    result = []
    for g in groups.values():
        node_states, replicas, databases, errors = [], {}, {}, []
        if live:
            with ThreadPoolExecutor(max_workers=8) as pool:
                futures = {m["instance"]: pool.submit(_live_view, m["instance_id"], g["name"]) for m in g["members"]}
            for inst, fut in futures.items():
                try:
                    view = fut.result()
                except Exception as exc:  # node offline, extension unavailable, RBAC...
                    errors.append({"instance": inst, "error": str(exc)})
                    node_states.append({"instance": inst, "healthy": False, "failover_ready": False,
                                        "message": f"live query failed: {exc}"})
                    continue
                ev = view["evaluation"] | {"instance": inst}
                node_states.append(ev)
                for r in view["replicas"]:
                    if r.get("replicaName") not in replicas or ev.get("role") == "PRIMARY":
                        replicas[r.get("replicaName")] = r
                for d in view["databases"]:
                    k = (d.get("databaseName"), d.get("replicaName"))
                    if k not in databases or ev.get("role") == "PRIMARY":
                        databases[k] = d
                if ev.get("role") == "PRIMARY":
                    g["info"] = view["info"] or g["info"]

        replica_rows = []
        for name, r in sorted(replicas.items()):
            st, cf = r.get("state") or {}, r.get("configure") or {}
            replica_rows.append({
                "replica": name,
                "role": st.get("availabilityGroupReplicaRole"),
                "availability_mode": cf.get("availabilityModeDescription"),
                "failover_mode": cf.get("failoverModeDescription"),
                "connected": st.get("connectedStateDescription"),
                "operational_state": st.get("operationalStateDescription"),
                "sync_health": st.get("synchronizationHealthDescription"),
                "last_connect_error": st.get("lastConnectErrorDescription") or None,
                "endpoint_url": cf.get("endpointUrl"),
                "seeding_mode": cf.get("seedingModeDescription"),
                "readable_secondary": cf.get("secondaryRoleAllowConnectionsDescription"),
                "backup_priority": cf.get("backupPriority"),
            })
        db_rows: dict[str, dict[str, Any]] = {}
        for (db_name, replica), d in sorted(databases.items(), key=lambda kv: (kv[0][0] or "", kv[0][1] or "")):
            row = db_rows.setdefault(db_name, {"database": db_name, "replicas": []})
            row["replicas"].append({
                "replica": replica,
                "is_primary": d.get("isPrimaryReplica"),
                "sync_state": d.get("synchronizationStateDescription"),
                "sync_health": d.get("synchronizationHealthDescription"),
                "suspended": d.get("isSuspended"),
                "suspend_reason": d.get("suspendReasonDescription") or None,
                "database_state": d.get("databaseStateDescription") or None,
            })

        primary = next((n["instance"] for n in node_states if n.get("role") == "PRIMARY"), None) \
            or g["info"].get("primaryReplica")
        pref = preferred.get(_lower(g["name"]))
        healthy = bool(node_states) and all(n.get("healthy") for n in node_states) if live else \
            g["info"].get("synchronizationHealthDescription") == "HEALTHY"
        result.append({
            "name": g["name"],
            "availability_group_id": g["availability_group_id"],
            "resource_group": g["resource_group"],
            "cluster_type": g["info"].get("clusterTypeDescription"),
            "primary_replica": primary,
            "preferred_primary": pref,
            "on_preferred_primary": (pref is None) or (_lower(pref) == _lower(primary)),
            "synchronization_health": g["info"].get("synchronizationHealthDescription"),
            "automated_backup_preference": g["info"].get("automatedBackupPreferenceDescription"),
            "db_level_failover": g["info"].get("dbFailover"),
            "required_synchronized_secondaries": g["info"].get("requiredSynchronizedSecondariesToCommit"),
            "healthy": healthy,
            "source": "live (Arc getDetailView)" if live else "Resource Graph inventory",
            "nodes": node_states if live else [{"instance": m["instance"]} for m in g["members"]],
            "replicas": replica_rows,
            "databases": list(db_rows.values()),
            "errors": errors,
        })
    return {"availability_group_count": len(result), "availability_groups": result}


# ---------------------------------------------------------------------------
# patching
# ---------------------------------------------------------------------------


def _raw_assessments() -> list[dict[str, Any]]:
    return _cached("assessments", lambda: get_client().graph(f"""
patchassessmentresources
| where type =~ 'microsoft.hybridcompute/machines/patchassessmentresults' {_scope()}
| project machineId = tolower(tostring(split(tolower(id), '/patchassessmentresults/')[0])), properties
"""))


def _raw_missing_patches() -> list[dict[str, Any]]:
    return _cached("missing_patches", lambda: get_client().graph(f"""
patchassessmentresources
| where type =~ 'microsoft.hybridcompute/machines/patchassessmentresults/softwarepatches' {_scope()}
| project machineId = tolower(tostring(split(tolower(id), '/patchassessmentresults/')[0])), properties
"""))


def _raw_installations() -> list[dict[str, Any]]:
    return _cached("installations", lambda: get_client().graph(f"""
patchinstallationresources
| where type =~ 'microsoft.hybridcompute/machines/patchinstallationresults' {_scope()}
| project id, machineId = tolower(tostring(split(tolower(id), '/patchinstallationresults/')[0])), properties
"""))


def _sql_machine_ids() -> set[str]:
    return {_lower((i.get("properties") or {}).get("containerResourceId")) for i in _engine_instances()}


def get_patch_compliance(machine: str | None = None) -> dict[str, Any]:
    """Outstanding (missing) updates per SQL host from the latest Update Manager assessment."""
    machines = _machines_by_id()
    target_ids = _sql_machine_ids()
    if machine:
        target_ids = {_lower(resolve_machine(machine)["id"])}
    assessments = {a["machineId"]: a.get("properties") or {} for a in _raw_assessments()}
    missing: dict[str, list[dict[str, Any]]] = {}
    for row in _raw_missing_patches():
        p = row.get("properties") or {}
        name = p.get("patchName") or ""
        missing.setdefault(row["machineId"], []).append({
            "kb": p.get("kbId"),
            "name": name,
            "classifications": p.get("classifications") or [],
            "msrc_severity": p.get("msrcSeverity"),
            "published": p.get("publishedDateTime"),
            "age_days": _age_days(p.get("publishedDateTime")),
            "reboot_behavior": p.get("rebootBehavior"),
            "is_sql_server_update": "sql server" in name.lower(),
        })
    latest_install: dict[str, dict[str, Any]] = {}
    for row in _raw_installations():
        p = row.get("properties") or {}
        cur = latest_install.get(row["machineId"])
        if not cur or (_dt(p.get("lastModifiedDateTime")) or datetime.min.replace(tzinfo=timezone.utc)) > \
                (_dt(cur.get("lastModifiedDateTime")) or datetime.min.replace(tzinfo=timezone.utc)):
            latest_install[row["machineId"]] = p

    rows = []
    for mid in sorted(target_ids):
        a = assessments.get(mid, {})
        patches = sorted(missing.get(mid, []), key=lambda x: (
            0 if (x["msrc_severity"] or "").lower() == "critical" else 1,
            0 if "Security" in x["classifications"] or "Critical" in x["classifications"] else 1,
            -(x["age_days"] or 0)))
        counts = a.get("availablePatchCountByClassification") or {}
        assessed_age = _age_days(a.get("lastModifiedDateTime"))
        inst = latest_install.get(mid) or {}
        patch_settings = (((machines.get(mid) or {}).get("properties") or {}).get("osProfile") or {}) \
            .get("windowsConfiguration", {}).get("patchSettings") or {}
        rows.append({
            "machine": (machines.get(mid) or {}).get("name") or _machine_name(mid),
            "machine_id": mid,
            "assessment_mode": patch_settings.get("assessmentMode"),
            "patch_mode": patch_settings.get("patchMode"),
            "assessment_status": a.get("status") or "NotAssessed",
            "last_assessed": a.get("lastModifiedDateTime"),
            "assessment_age_days": assessed_age,
            "assessment_stale": assessed_age is None or assessed_age > STALE_ASSESSMENT_DAYS,
            "reboot_pending": a.get("rebootPending"),
            "patch_service": a.get("patchServiceUsed"),
            "counts_by_classification": counts,
            "outstanding_total": len(patches),
            "security_or_critical": sum(1 for x in patches if {"Security", "Critical"} & set(x["classifications"])),
            "msrc_critical": sum(1 for x in patches if (x["msrc_severity"] or "").lower() == "critical"),
            "sql_server_updates": [x for x in patches if x["is_sql_server_update"]],
            "oldest_outstanding_days": max((x["age_days"] or 0 for x in patches), default=0),
            "outstanding": patches,
            "last_installation": {
                "status": inst.get("status"),
                "start": inst.get("startDateTime"),
                "last_modified": inst.get("lastModifiedDateTime"),
                "started_by": inst.get("startedBy"),
                "installed": inst.get("installedPatchCount"),
                "failed": inst.get("failedPatchCount"),
                "pending": inst.get("pendingPatchCount"),
                "reboot_status": inst.get("rebootStatus"),
                "maintenance_window_exceeded": inst.get("maintenanceWindowExceeded"),
                "maintenance_run_id": inst.get("maintenanceRunId"),
            } if inst else None,
        })
    return {
        "machine_count": len(rows),
        "outstanding_total": sum(r["outstanding_total"] for r in rows),
        "security_or_critical_total": sum(r["security_or_critical"] for r in rows),
        "machines": rows,
    }


def _raw_maintenance_runs() -> list[dict[str, Any]]:
    return _cached("maintenance_runs", lambda: get_client().graph(f"""
maintenanceresources
| where type =~ 'microsoft.maintenance/maintenanceconfigurations/applyupdates' or type =~ 'microsoft.maintenance/applyupdates'
{_scope()}
| project id, type, properties
"""))


def _relevant_config_ids() -> set[str]:
    """Maintenance configurations that are AG-aware or assigned (statically or dynamically) to a SQL host."""
    sql_ids = _sql_machine_ids()
    machines = [m for m in _raw_machines() if _lower(m["id"]) in sql_ids]
    out = {_lower(c["id"]) for c in _raw_maintenance_configs() if (c.get("tags") or {}).get("SqlAgName")}
    for a in _raw_assignments():
        p = a.get("properties") or {}
        if _lower(p.get("resourceId")) in sql_ids or (
                p.get("filter") and any(_dynamic_scope_matches(p["filter"], m) for m in machines)):
            out.add(_lower(p.get("maintenanceConfigurationId")))
    return out


def get_patch_history(days: int = 30) -> dict[str, Any]:
    """Maintenance runs (Update Manager schedules) and patch installations over the last `days` days.

    Only runs of schedules that cover the SQL hosts are returned.
    """
    cutoff = _now() - timedelta(days=days)
    relevant = _relevant_config_ids()
    sql_ids = _sql_machine_ids()
    runs = []
    for r in _raw_maintenance_runs():
        p = r.get("properties") or {}
        start = _dt(p.get("startDateTime"))
        if start and start < cutoff:
            continue
        mc = p.get("maintenanceConfiguration") or {}
        mc_id = p.get("maintenanceConfigurationId") or mc.get("id") or ""
        if _lower(mc_id) not in relevant and _lower(p.get("resourceId")) not in sql_ids:
            continue
        tags = mc.get("tags") or {}
        runs.append({
            "run_id": p.get("correlationId") or r["id"],
            "scope": "configuration" if "maintenanceconfigurations/" in _lower(r["type"]) else "resource",
            "maintenance_configuration": mc_id.rsplit("/", 1)[-1] if mc_id else None,
            "resource": _machine_name(p.get("resourceId") or r["id"]),
            "target_node": tags.get("SqlAgTarget"),
            "wave": tags.get("SqlAgWave"),
            "status": p.get("status"),
            "start": p.get("startDateTime"),
            "end": p.get("endDateTime"),
            "summary": p.get("resourceUpdateSummary"),
            "error": p.get("errorMessage") or None,
        })
    installs = []
    machines = _machines_by_id()
    for row in _raw_installations():
        p = row.get("properties") or {}
        start = _dt(p.get("startDateTime"))
        if start and start < cutoff:
            continue
        installs.append({
            "machine": (machines.get(row["machineId"]) or {}).get("name") or _machine_name(row["machineId"]),
            "status": p.get("status"),
            "start": p.get("startDateTime"),
            "last_modified": p.get("lastModifiedDateTime"),
            "started_by": p.get("startedBy"),
            "installed": p.get("installedPatchCount"),
            "failed": p.get("failedPatchCount"),
            "pending": p.get("pendingPatchCount"),
            "excluded": p.get("excludedPatchCount"),
            "reboot_status": p.get("rebootStatus"),
            "maintenance_window_exceeded": p.get("maintenanceWindowExceeded"),
            "maintenance_run_id": p.get("maintenanceRunId"),
            "errors": ((p.get("errorDetails") or {}).get("details") or [])[:5],
        })
    runs.sort(key=lambda x: (x["start"] or "", x["scope"] == "configuration"), reverse=True)
    merged: dict[tuple[Any, Any], dict[str, Any]] = {}
    for run in runs:  # one row per schedule occurrence; configuration and resource records describe the same run
        key = (run["maintenance_configuration"], run["start"])
        cur = merged.get(key)
        if cur is None:
            merged[key] = run
        else:
            cur["error"] = cur["error"] or run["error"]
            cur["resource"] = cur["resource"] or run["resource"]
            cur["summary"] = cur["summary"] or run["summary"]
    runs = list(merged.values())
    installs.sort(key=lambda x: x["start"] or "", reverse=True)
    return {"days": days, "maintenance_runs": runs, "installations": installs}


# ---------------------------------------------------------------------------
# maintenance windows
# ---------------------------------------------------------------------------


def _raw_maintenance_configs() -> list[dict[str, Any]]:
    # Not resource-group scoped: SQL hosts can be assigned to configurations in other groups.
    return _cached("maintenance_configs", lambda: get_client().graph("""
resources
| where type =~ 'microsoft.maintenance/maintenanceconfigurations'
| project id, name, resourceGroup, location, tags, properties
"""))


def _raw_assignments() -> list[dict[str, Any]]:
    return _cached("assignments", lambda: get_client().graph("""
maintenanceresources
| where type =~ 'microsoft.maintenance/configurationassignments'
| project id, properties
"""))


def _dynamic_scope_matches(flt: dict[str, Any], machine: dict[str, Any]) -> bool:
    """Best-effort evaluation of a dynamic scope filter against a machine."""
    if not flt:
        return False
    types = [_lower(t) for t in flt.get("resourceTypes") or []]
    if types and "microsoft.hybridcompute/machines" not in types:
        return False
    groups = [_lower(g) for g in flt.get("resourceGroups") or []]
    if groups and _lower(machine.get("resourceGroup")) not in groups:
        return False
    locations = [_lower(x) for x in flt.get("locations") or []]
    if locations and _lower(machine.get("location")) not in locations:
        return False
    os_types = [_lower(x) for x in flt.get("osTypes") or []]
    if os_types and "windows" not in os_types:
        return False
    tag_settings = flt.get("tagSettings") or {}
    wanted = tag_settings.get("tags") or {}
    if wanted:
        mtags = {_lower(k): [_lower(v)] for k, v in (machine.get("tags") or {}).items()}
        hits = [any(_lower(v) in mtags.get(_lower(k), []) for v in (vals or [])) or (not vals and _lower(k) in mtags)
                for k, vals in wanted.items()]
        return all(hits) if _lower(tag_settings.get("filterOperator")) == "all" else any(hits)
    return True


def _live_configs(config_ids: set[str]) -> dict[str, dict[str, Any]]:
    """Read maintenance configurations from ARM. Resource Graph can lag minutes behind a schedule change, and
    the schedule is what operators check right after editing it. Falls back to Resource Graph on error."""
    def fetch(cid: str) -> tuple[str, dict[str, Any] | None]:
        try:
            c = get_client().get(f"{cid}?api-version={API_MAINTENANCE}")
        except Exception:
            return cid, None
        return cid, {"id": c.get("id") or cid, "name": c.get("name"), "resourceGroup": _rg(c.get("id") or cid),
                     "location": c.get("location"), "tags": c.get("tags") or {}, "properties": c.get("properties") or {}}

    ids = [c for c in config_ids if c]
    if not ids:
        return {}
    with ThreadPoolExecutor(max_workers=min(8, len(ids))) as pool:
        return {cid: cfg for cid, cfg in pool.map(fetch, ids) if cfg}


def get_maintenance_windows(count: int = 4) -> dict[str, Any]:
    """Maintenance configurations covering the SQL hosts, their next windows, and scheduling risks."""
    machines = {_lower(m["id"]): m for m in _raw_machines() if _lower(m["id"]) in _sql_machine_ids()}
    configs = {_lower(c["id"]): c for c in _raw_maintenance_configs()}
    assigned: dict[str, list[dict[str, Any]]] = {mid: [] for mid in machines}
    for a in _raw_assignments():
        p = a.get("properties") or {}
        mc_id = _lower(p.get("maintenanceConfigurationId"))
        rid = _lower(p.get("resourceId"))
        if rid in assigned:
            assigned[rid].append({"config_id": mc_id, "kind": "static", "assignment_id": a["id"]})
        elif p.get("filter"):
            for mid, m in machines.items():
                if _dynamic_scope_matches(p["filter"], m):
                    assigned[mid].append({"config_id": mc_id, "kind": "dynamic", "assignment_id": a["id"]})

    used_configs = {x["config_id"] for lst in assigned.values() for x in lst}
    relevant = used_configs | {c for c, v in configs.items() if (v.get("tags") or {}).get("SqlAgName")}
    configs.update(_live_configs(relevant))
    cfg_rows = []
    for cid in sorted(relevant):
        c = configs.get(cid)
        if not c:
            cfg_rows.append({"id": cid, "name": cid.rsplit("/", 1)[-1], "error": "configuration not readable"})
            continue
        p = c.get("properties") or {}
        w = p.get("maintenanceWindow") or {}
        win = (p.get("installPatches") or {}).get("windowsParameters") or {}
        try:
            upcoming = schedule.next_windows(w.get("startDateTime", ""), w.get("recurEvery", ""), w.get("duration"),
                                             w.get("timeZone"), count=count, expiration=w.get("expirationDateTime"))
        except Exception as exc:
            upcoming = [{"error": f"could not compute schedule: {exc}"}]
        tags = c.get("tags") or {}
        cfg_rows.append({
            "id": c["id"],
            "name": c["name"],
            "resource_group": c.get("resourceGroup"),
            "scope": p.get("maintenanceScope"),
            "recur_every": w.get("recurEvery"),
            "start": w.get("startDateTime"),
            "duration": w.get("duration"),
            "time_zone": w.get("timeZone"),
            "expiration": w.get("expirationDateTime"),
            "reboot_setting": (p.get("installPatches") or {}).get("rebootSetting"),
            "classifications": win.get("classificationsToInclude") or [],
            "kb_exclude": win.get("kbNumbersToExclude") or [],
            "kb_include": win.get("kbNumbersToInclude") or [],
            "ag_aware": bool(tags.get("SqlAgName")),
            "ag_name": tags.get("SqlAgName"),
            "wave": tags.get("SqlAgWave"),
            "target_node": tags.get("SqlAgTarget"),
            "partner_node": tags.get("SqlAgPartner"),
            "preferred_primary": tags.get("SqlAgPreferredPrimary"),
            "assigned_machines": sorted(
                (machines[m]["name"] for m, lst in assigned.items() for x in lst if x["config_id"] == cid),
                key=str.lower),
            "next_windows": upcoming,
        })
    cfg_by_id = {_lower(r["id"]): r for r in cfg_rows}
    machine_rows = []
    for mid, m in machines.items():
        entries = assigned.get(mid, [])
        machine_rows.append({
            "machine": m["name"],
            "assignments": [{"configuration": cfg_by_id.get(x["config_id"], {}).get("name", x["config_id"]),
                             "kind": x["kind"]} for x in entries],
            "next_window": min((w for x in entries for w in cfg_by_id.get(x["config_id"], {}).get("next_windows", [])
                                if "start_utc" in w), key=lambda w: w["start_utc"], default=None),
        })

    risks = _schedule_risks(machine_rows, cfg_by_id)
    return {"configurations": cfg_rows, "machines": sorted(machine_rows, key=lambda r: r["machine"]), "risks": risks}


PRE_EVENT_LEAD_MIN = 40   # Update Manager sends the pre-maintenance event 30-40 min before the window
RECOMMENDED_GAP_MIN = 90  # default -GapMinutes of Enable-SqlAgPatching.ps1 (reboot + resync before next pre-event)


def _wave_spacing_risks(a: dict[str, Any], b: dict[str, Any]) -> list[dict[str, Any]]:
    """Non-overlapping AG waves that are too close together, or that run in reverse wave order."""
    pairs = []
    for wa in a.get("next_windows", []):
        for wb in b.get("next_windows", []):
            if "start_utc" not in wa or "start_utc" not in wb:
                continue
            if wa["end_utc"] <= wb["start_utc"]:
                pairs.append((_dt(wb["start_utc"]) - _dt(wa["end_utc"]), a, wa, b, wb))
            elif wb["end_utc"] <= wa["start_utc"]:
                pairs.append((_dt(wa["start_utc"]) - _dt(wb["end_utc"]), b, wb, a, wa))
    if not pairs:
        return []
    gap, first, fw, second, sw = min(pairs, key=lambda p: p[0])
    gap_min = int(gap.total_seconds() // 60)
    risks = []
    if gap_min < RECOMMENDED_GAP_MIN:
        sev = "high" if gap_min < PRE_EVENT_LEAD_MIN else "medium"
        risks.append(_finding(
            sev, "maintenance", f"AG {first['ag_name']} waves are only {gap_min} min apart",
            f"{second['name']} ({second.get('target_node')}) starts {gap_min} min after {first['name']} "
            f"({first.get('target_node')}) ends, first at {sw['start_local']}. Its pre-maintenance runbook fires "
            f"30-40 min before the window, while {first.get('target_node')} may still be patching, rebooting or "
            f"resynchronizing, so the runbook is likely to cancel the {second.get('target_node')} run.",
            first["ag_name"], f"Leave at least {RECOMMENDED_GAP_MIN} min between waves: re-run "
            f"scripts/patching/Enable-SqlAgPatching.ps1 -GapMinutes {RECOMMENDED_GAP_MIN}."))
    try:
        reversed_order = int(first.get("wave") or 0) > int(second.get("wave") or 0) > 0
    except ValueError:
        reversed_order = False
    if reversed_order:
        risks.append(_finding(
            "medium", "maintenance", f"AG {first['ag_name']} waves run in reverse order",
            f"Wave {first['wave']} ({first.get('target_node')}) now runs before wave {second['wave']} "
            f"({second.get('target_node')}). The design patches the secondary first; in this order the "
            f"{'preferred primary' if _lower(first.get('target_node')) == _lower(first.get('preferred_primary')) else 'first node'} "
            "is patched first, which needs a failover before the secondary has been validated with the new updates.",
            first["ag_name"], "Schedule wave 1 before wave 2, or re-run Enable-SqlAgPatching.ps1."))
    return risks


def _schedule_risks(machine_rows: list[dict[str, Any]], cfg_by_id: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    risks = []
    by_name = {_lower(c["name"]): c for c in cfg_by_id.values()}
    for row in machine_rows:
        if not row["assignments"]:
            risks.append(_finding("high", "maintenance", f"{row['machine']} has no maintenance schedule",
                                  "The host is not assigned to any maintenance configuration, so it is not patched on a schedule.",
                                  row["machine"], "Run scripts/patching/Enable-SqlAgPatching.ps1 to assign AG-aware waves."))
        if len(row["assignments"]) > 1:
            names = ", ".join(a["configuration"] for a in row["assignments"])
            risks.append(_finding("high", "maintenance", f"{row['machine']} is in multiple schedules",
                                  f"Assigned to: {names}. Non-AG-aware schedules can patch both replicas at once.",
                                  row["machine"], "Keep each AG node in exactly one AG-aware wave."))
        for a in row["assignments"]:
            if a["kind"] == "dynamic":
                risks.append(_finding("medium", "maintenance", f"{row['machine']} may match a dynamic scope",
                                      f"Dynamic scope of '{a['configuration']}' appears to include this host.",
                                      row["machine"], "Exclude AG nodes from dynamic scopes."))
    # Overlapping windows between AG partners.
    ag_cfgs = [c for c in cfg_by_id.values() if c.get("ag_aware")]
    for i, a in enumerate(ag_cfgs):
        for b in ag_cfgs[i + 1:]:
            if _lower(a.get("ag_name")) != _lower(b.get("ag_name")):
                continue
            overlap = next(((wa, wb) for wa in a.get("next_windows", []) for wb in b.get("next_windows", [])
                            if "start_utc" in wa and "start_utc" in wb
                            and wa["start_utc"] < wb["end_utc"] and wb["start_utc"] < wa["end_utc"]), None)
            if overlap:
                risks.append(_finding("critical", "maintenance", f"AG {a['ag_name']} waves overlap",
                                      f"{a['name']} ({a['recur_every']} {a['start'][11:] if a.get('start') else ''}) and "
                                      f"{b['name']} ({b['recur_every']} {b['start'][11:] if b.get('start') else ''}) overlap, "
                                      f"first at {overlap[0]['start_local']}; both replicas could be patched and "
                                      "rebooted at the same time (AG outage).",
                                      a["ag_name"], "Re-run scripts/patching/Enable-SqlAgPatching.ps1 to restore "
                                      "staggered waves (e.g. -GapMinutes 90)."))
            else:
                risks.extend(_wave_spacing_risks(a, b))
        if a.get("partner_node") and _lower(a["partner_node"]) not in by_name and not any(
                _lower(c.get("target_node")) == _lower(a["partner_node"]) for c in ag_cfgs):
            risks.append(_finding("high", "maintenance", f"Partner {a['partner_node']} has no AG-aware wave",
                                  f"{a['name']} expects partner {a['partner_node']} to have its own wave.", a["partner_node"]))
    return risks


# ---------------------------------------------------------------------------
# security
# ---------------------------------------------------------------------------


def get_security_posture() -> dict[str, Any]:
    """Defender for Cloud recommendations/alerts for SQL hosts and instances, plus missing security patches."""
    client = get_client()
    assessments = _cached("sec_assessments", lambda: client.graph(f"""
securityresources
| where type =~ 'microsoft.security/assessments' {_scope()}
| where tolower(tostring(properties.resourceDetails.Id)) contains '/microsoft.hybridcompute/machines/'
   or tolower(tostring(properties.resourceDetails.Id)) contains '/microsoft.azurearcdata/'
| project id, name, properties
"""))
    alerts = _cached("sec_alerts", lambda: client.graph(f"""
securityresources
| where type =~ 'microsoft.security/locations/alerts' {_scope()}
| where tostring(properties.status) in~ ('Active', 'InProgress')
| project id, properties
"""))
    findings, healthy_count = [], 0
    for a in assessments:
        p = a.get("properties") or {}
        status = (p.get("status") or {}).get("code")
        if status == "Healthy":
            healthy_count += 1
            continue
        if status != "Unhealthy":
            continue
        meta = p.get("metadata") or {}
        rid = (p.get("resourceDetails") or {}).get("Id") or ""
        target = rid.split("/securityentitydata/", 1)[1] if "/securityentitydata/" in _lower(rid) else None
        findings.append({
            "title": p.get("displayName") or meta.get("displayName"),
            "severity": meta.get("severity") or "Unknown",
            "machine": _machine_name(rid),
            "target": target.replace(":", " / ") if target else None,
            "categories": meta.get("categories") or [],
            "description": meta.get("description"),
            "remediation": meta.get("remediationDescription"),
            "status_cause": (p.get("status") or {}).get("cause"),
            "assessment_key": a.get("name"),
        })
    findings.sort(key=lambda f: (SEVERITY_ORDER.get(_lower(f["severity"]), 5), f["machine"] or "", f["title"] or ""))
    alert_rows = [{
        "title": (al.get("properties") or {}).get("alertDisplayName"),
        "severity": (al.get("properties") or {}).get("severity"),
        "status": (al.get("properties") or {}).get("status"),
        "time": (al.get("properties") or {}).get("timeGeneratedUtc"),
        "entity": (al.get("properties") or {}).get("compromisedEntity"),
        "description": (al.get("properties") or {}).get("description"),
    } for al in alerts]

    inventory = get_inventory()
    instance_controls = [{
        "instance": i["name"],
        "defender_for_sql": i["defender_status"],
        "mirroring_endpoint_encrypted": (i["mirroring_endpoint"] or {}).get("isEncryptionEnabled"),
        "mirroring_endpoint_algorithm": (i["mirroring_endpoint"] or {}).get("encryptionAlgorithm"),
        "license_type": i["license_type"],
        "arc_agent_version": i["host"]["arc_agent_version"],
        "host_status": i["host"]["status"],
    } for i in inventory["instances"]]

    patches = get_patch_compliance()
    sec_patches = [{"machine": m["machine"], **x} for m in patches["machines"] for x in m["outstanding"]
                   if {"Security", "Critical"} & set(x["classifications"]) or x["msrc_severity"]]

    unencrypted = [d for d in get_databases()["databases"] if d.get("encrypted") is False and not d["system"]]
    by_sev: dict[str, int] = {}
    for f in findings:
        by_sev[f["severity"]] = by_sev.get(f["severity"], 0) + 1
    return {
        "defender_unhealthy_by_severity": by_sev,
        "defender_healthy_count": healthy_count,
        "defender_findings": findings,
        "active_alerts": alert_rows,
        "missing_security_patches": sec_patches,
        "instance_controls": instance_controls,
        "unencrypted_user_databases": [{"instance": d["instance"], "database": d["name"]} for d in unencrypted],
    }


# ---------------------------------------------------------------------------
# databases
# ---------------------------------------------------------------------------

SYSTEM_DBS = {"master", "model", "msdb", "tempdb"}


def get_databases() -> dict[str, Any]:
    """Databases discovered on Arc SQL instances (state, recovery model, size, encryption, backups)."""
    rows = _cached("databases", lambda: get_client().graph(f"""
resources
| where type =~ 'microsoft.azurearcdata/sqlserverinstances/databases' {_scope()}
| project id, name, properties
"""))
    out = []
    for r in rows:
        p = r.get("properties") or {}
        opts = p.get("databaseOptions") or {}
        backup = p.get("backupInformation") or {}
        out.append({
            "instance": re.split(r"/databases/", r["id"], flags=re.I)[0].rsplit("/", 1)[-1],
            "name": r["name"],
            "system": _lower(r["name"]) in SYSTEM_DBS,
            "state": p.get("state"),
            "recovery_model": p.get("recoveryMode"),
            "compatibility_level": p.get("compatibilityLevel"),
            "size_mb": p.get("sizeMB"),
            "space_available_mb": p.get("spaceAvailableMB"),
            "encrypted": opts.get("isEncrypted"),
            "read_only": p.get("isReadOnly"),
            "last_full_backup": backup.get("lastFullBackup"),
            "last_log_backup": backup.get("lastLogBackup"),
            "created": p.get("databaseCreationDate"),
            "last_upload": p.get("lastDatabaseUploadTime"),
        })
    out.sort(key=lambda d: (d["instance"], d["system"], d["name"]))
    return {"database_count": len(out), "databases": out}


# ---------------------------------------------------------------------------
# patch orchestration (Automation runbooks)
# ---------------------------------------------------------------------------


def _automation_accounts() -> list[dict[str, Any]]:
    return _cached("automation_accounts", lambda: get_client().graph(f"""
resources
| where type =~ 'microsoft.automation/automationaccounts' {_scope()}
| project id, name, resourceGroup
"""))


def get_orchestration_jobs(limit: int = 20, days: int = 30) -> dict[str, Any]:
    """Recent runs of the AG-aware patching runbooks (Pre-SqlAgFailover / Post-SqlAgValidate)."""
    cutoff = _now() - timedelta(days=days)
    jobs = []
    for acct in _automation_accounts():
        try:
            data = get_client().get(f"{acct['id']}/jobs?api-version={API_AUTOMATION}")
        except ArmError as exc:
            jobs.append({"automation_account": acct["name"], "error": str(exc)})
            continue
        for j in data.get("value", []):
            p = j.get("properties") or {}
            created = _dt(p.get("creationTime"))
            if created and created < cutoff:
                continue
            jobs.append({
                "automation_account": acct["name"],
                "job_name": j.get("name"),
                "runbook": (p.get("runbook") or {}).get("name"),
                "status": p.get("status"),
                "created": p.get("creationTime"),
                "start": p.get("startTime"),
                "end": p.get("endTime"),
            })
    jobs.sort(key=lambda x: x.get("created") or "", reverse=True)
    return {"jobs": jobs[:limit], "failed_count": sum(1 for j in jobs if j.get("status") in ("Failed", "Suspended"))}


def get_job_output(job_name: str, automation_account: str | None = None, tail_chars: int = 6000) -> dict[str, Any]:
    """Output stream of one Automation runbook job (for diagnosing a failed or cancelled patch wave)."""
    for acct in _automation_accounts():
        if automation_account and _lower(acct["name"]) != _lower(automation_account):
            continue
        try:
            resp = get_client().request("GET", f"{acct['id']}/jobs/{job_name}/output?api-version={API_AUTOMATION}")
        except ArmError as exc:
            if exc.status == 404:
                continue
            raise
        text = resp.text or ""
        return {"automation_account": acct["name"], "job_name": job_name, "truncated": len(text) > tail_chars,
                "output": text[-tail_chars:]}
    raise ValueError(f"Job '{job_name}' was not found in automation accounts in scope.")


# ---------------------------------------------------------------------------
# overview / findings
# ---------------------------------------------------------------------------


def _safe(fn: Callable[[], Any]) -> tuple[Any, str | None]:
    try:
        return fn(), None
    except Exception as exc:
        return None, f"{type(exc).__name__}: {exc}"


def get_dashboard_snapshot(live_ag: bool = True, history_days: int = 30) -> dict[str, Any]:
    """Everything needed for the dashboard and for broad status questions, collected in parallel."""
    tasks = {
        "inventory": get_inventory,
        "availability_groups": lambda: get_availability_groups(live=live_ag),
        "patching": get_patch_compliance,
        "history": lambda: get_patch_history(history_days),
        "maintenance": lambda: get_maintenance_windows(count=30),
        "security": get_security_posture,
        "databases": get_databases,
        "jobs": get_orchestration_jobs,
    }
    with ThreadPoolExecutor(max_workers=len(tasks)) as pool:
        futures = {k: pool.submit(_safe, fn) for k, fn in tasks.items()}
    snap: dict[str, Any] = {"generated_at": _now().isoformat(), "errors": {}}
    for key, fut in futures.items():
        value, error = fut.result()
        snap[key] = value
        if error:
            snap["errors"][key] = error
    settings = get_client().settings
    snap["scope"] = {"subscriptions": settings.subscription_ids or ["(all accessible)"],
                     "resource_groups": settings.resource_groups or ["(all)"]}
    snap["findings"] = build_findings(snap)
    snap["kpis"] = _kpis(snap)
    return snap


def build_findings(snap: dict[str, Any]) -> list[dict[str, Any]]:
    f: list[dict[str, Any]] = []
    inv = snap.get("inventory") or {}
    for i in inv.get("instances", []):
        if i["host"]["status"] != "Connected":
            f.append(_finding("critical", "connectivity", f"Arc agent on {i['machine']} is {i['host']['status']}",
                              f"Last status change {i['host']['last_status_change']}. Azure cannot monitor or patch it.",
                              i["machine"], "Check the Azure Connected Machine agent (himds) and network path."))
        elif i["status"] != "Connected":
            f.append(_finding("high", "connectivity", f"SQL instance {i['name']} is {i['status']}",
                              "The Arc SQL extension is not reporting.", i["name"]))
        if i["defender_status"] and i["defender_status"] != "Protected":
            f.append(_finding("medium", "security", f"Defender for SQL is {i['defender_status']} on {i['name']}",
                              "The instance is not protected by Microsoft Defender for SQL.", i["name"]))

    for ag in (snap.get("availability_groups") or {}).get("availability_groups", []):
        for n in ag.get("nodes", []):
            if "healthy" in n and not n["healthy"]:
                f.append(_finding("critical", "availability", f"AG {ag['name']}: {n['instance']} unhealthy",
                                  n.get("message") or "replica not healthy", n["instance"],
                                  "Investigate before any patching or failover; patch waves will cancel."))
            elif n.get("role") == "SECONDARY" and not n.get("failover_ready"):
                f.append(_finding("high", "availability", f"AG {ag['name']}: {n['instance']} not failover-ready",
                                  f"mode={n.get('mode')}: {n.get('message')}", n["instance"]))
        if not ag.get("on_preferred_primary"):
            f.append(_finding("medium", "availability", f"AG {ag['name']} is not on its preferred primary",
                              f"Primary is {ag['primary_replica']}; preferred is {ag['preferred_primary']}.", ag["name"],
                              "Fail back with sqlha_failover_availability_group when the preferred node is healthy."))

    for m in (snap.get("patching") or {}).get("machines", []):
        if m["msrc_critical"]:
            f.append(_finding("critical", "patching", f"{m['machine']}: {m['msrc_critical']} MSRC-critical update(s) missing",
                              ", ".join(f"KB{x['kb']}" for x in m["outstanding"] if (x["msrc_severity"] or "").lower() == "critical"),
                              m["machine"], "Patch in the next AG-aware wave or run an AG-safe on-demand install."))
        elif m["security_or_critical"]:
            f.append(_finding("high", "patching", f"{m['machine']}: {m['security_or_critical']} security update(s) missing",
                              ", ".join(f"KB{x['kb']}" for x in m["outstanding"] if {"Security", "Critical"} & set(x["classifications"])),
                              m["machine"]))
        for x in m["sql_server_updates"]:
            if not ({"Security", "Critical"} & set(x["classifications"])):
                f.append(_finding("medium", "patching", f"{m['machine']}: SQL Server update pending",
                                  f"{x['name']} (published {str(x['published'])[:10]}).", m["machine"]))
        if m["reboot_pending"]:
            f.append(_finding("medium", "patching", f"{m['machine']} has a reboot pending", "", m["machine"],
                              "Reboot only when the node is a secondary."))
        if m["assessment_stale"]:
            never = not m["last_assessed"]
            f.append(_finding("high" if never else "medium", "patching",
                              f"{m['machine']}: {'never assessed' if never else 'patch assessment is stale'}",
                              f"Last assessed {m['last_assessed'] or 'never'}; assessment mode "
                              f"{m.get('assessment_mode') or 'unknown'}. Outstanding updates are unknown.", m["machine"],
                              "Run sqlha_trigger_patch_assessment and sqlha_enable_periodic_assessment."))
        li = m.get("last_installation") or {}
        if li.get("status") in ("Failed", "CompletedWithWarnings"):
            f.append(_finding("high", "patching", f"{m['machine']}: last installation {li['status']}",
                              f"failed={li.get('failed')} pending={li.get('pending')}", m["machine"]))

    seen_cfg = set()
    for r in (snap.get("history") or {}).get("maintenance_runs", []):
        key = r.get("maintenance_configuration")
        if key in seen_cfg or r.get("status") in NOT_STARTED:
            continue
        seen_cfg.add(key)  # only the most recent started run per configuration
        if r["status"] in ("Cancelled", "Failed", "TimedOut", "PartialFailed"):
            f.append(_finding("high", "patching", f"Last run of {key} was {r['status']}",
                              f"{r['start']}: {r.get('error') or ''}", r.get("target_node") or key,
                              "Read the Pre-SqlAgFailover/Post-SqlAgValidate job output to find the cause."))

    seen_runbooks = set()
    for j in (snap.get("jobs") or {}).get("jobs", []):
        if j.get("runbook") in seen_runbooks:
            continue
        seen_runbooks.add(j.get("runbook"))  # only the most recent job per runbook
        if j.get("status") in ("Failed", "Suspended"):
            f.append(_finding("high", "patching", f"Last {j['runbook']} job {j['status']}",
                              f"Job {j['job_name']} created {j['created']}.", j.get("automation_account"),
                              "Use sqlha_get_job_output to see why."))

    f.extend((snap.get("maintenance") or {}).get("risks", []))

    sec = snap.get("security") or {}
    grouped: dict[str, dict[str, Any]] = {}
    for d in sec.get("defender_findings", []):
        g = grouped.setdefault(d["title"], {"severity": _lower(d["severity"]), "machines": set(), "targets": [],
                                            "remediation": d.get("remediation")})
        if d.get("machine"):
            g["machines"].add(d["machine"])
        if d.get("target"):
            g["targets"].append(d["target"])
    for title, g in grouped.items():
        sev = g["severity"]
        nodes = ", ".join(sorted(g["machines"]))
        f.append(_finding("high" if sev == "high" else "medium" if sev == "medium" else "low", "security", title,
                          f"{len(g['targets']) or len(g['machines'])} affected object(s) on {nodes or 'n/a'}",
                          nodes or None, g["remediation"]))
    for a in sec.get("active_alerts", []):
        f.append(_finding("critical" if _lower(a["severity"]) == "high" else "high", "security",
                          f"Defender alert: {a['title']}", a.get("description") or "", a.get("entity")))
    unencrypted = sec.get("unencrypted_user_databases", [])
    if unencrypted:
        f.append(_finding("low", "security", f"TDE off on {len(unencrypted)} user database copies",
                          ", ".join(sorted({f"{d['database']}@{d['instance']}" for d in unencrypted})),
                          ", ".join(sorted({d["instance"] for d in unencrypted}))))
    f.sort(key=lambda x: (SEVERITY_ORDER.get(x["severity"], 9), x["category"], x["title"]))
    return f


def _kpis(snap: dict[str, Any]) -> dict[str, Any]:
    inv = snap.get("inventory") or {}
    ags = (snap.get("availability_groups") or {}).get("availability_groups", [])
    pat = snap.get("patching") or {}
    maint = snap.get("maintenance") or {}
    windows = [w for c in maint.get("configurations", []) for w in c.get("next_windows", []) if "start_utc" in w]
    nxt = min(windows, key=lambda w: w["start_utc"], default=None)
    nxt_cfg = next((c for c in maint.get("configurations", []) if nxt in c.get("next_windows", [])), None)
    runs = [r for r in (snap.get("history") or {}).get("maintenance_runs", []) if r.get("status") not in NOT_STARTED]
    sev_counts: dict[str, int] = {}
    for x in snap.get("findings", []):
        sev_counts[x["severity"]] = sev_counts.get(x["severity"], 0) + 1
    worst = min(sev_counts, key=lambda s: SEVERITY_ORDER.get(s, 9), default="info")
    return {
        "overall": "critical" if worst == "critical" else "warning" if worst in ("high", "medium") else "healthy",
        "findings_by_severity": sev_counts,
        "instances_total": inv.get("instance_count", 0),
        "instances_connected": inv.get("connected_count", 0),
        "ag_total": len(ags),
        "ag_healthy": sum(1 for a in ags if a.get("healthy")),
        "outstanding_patches": pat.get("outstanding_total", 0),
        "security_patches": pat.get("security_or_critical_total", 0),
        "next_window": ({**nxt, "configuration": nxt_cfg["name"] if nxt_cfg else None,
                         "target_node": nxt_cfg.get("target_node") if nxt_cfg else None} if nxt else None),
        "last_run": runs[0] if runs else None,
        "defender_unhealthy": sum((snap.get("security") or {}).get("defender_unhealthy_by_severity", {}).values()),
    }


def get_overview() -> dict[str, Any]:
    """Health summary: KPIs and prioritized findings across availability, patching, maintenance and security."""
    snap = get_dashboard_snapshot()
    return {"generated_at": snap["generated_at"], "kpis": snap["kpis"], "findings": snap["findings"],
            "errors": snap["errors"]}


def run_resource_graph_query(query: str, max_rows: int = 200) -> dict[str, Any]:
    """Read-only Azure Resource Graph query for questions the other tools don't cover."""
    rows = get_client().graph(query, max_rows=max_rows)
    return {"row_count": len(rows), "rows": rows[:max_rows]}


def get_performance(machine: str | None = None) -> dict[str, Any]:
    """Live performance snapshot (CPU, memory, sessions, waits, IO, AG queues) for one or all SQL hosts."""
    from . import perf

    if not get_client().settings.enable_perf_snapshot:
        raise RuntimeError("Performance snapshots are disabled on this agent (SQLHA_ENABLE_PERF_SNAPSHOT=false).")
    sql_ids = _sql_machine_ids()
    if machine:
        targets = [resolve_machine(machine)]
        if _lower(targets[0]["id"]) not in sql_ids:
            raise ValueError(f"{targets[0]['name']} doesn't host an Arc-enabled SQL Server instance.")
    else:
        targets = sorted((m for m in _raw_machines() if _lower(m["id"]) in sql_ids), key=lambda m: m["name"])
    instances = {}
    for i in _engine_instances():
        host = _machine_name((i.get("properties") or {}).get("containerResourceId", ""))
        if host:
            instances[host] = (i.get("properties") or {}).get("instanceName") or "MSSQLSERVER"
    key = "perf:" + ",".join(sorted(m["name"].lower() for m in targets))
    # Run Command takes ~20-40 s, so reuse a snapshot for a minute (e.g. follow-up chat questions).
    return _cached(key, lambda: perf.get_performance_snapshot(targets, instances), ttl=60)


# ---------------------------------------------------------------------------
# write actions (guarded)
# ---------------------------------------------------------------------------


def _require_write() -> None:
    if not get_client().settings.enable_write_actions:
        raise PermissionError("Write actions are disabled. Set SQLHA_ENABLE_WRITE_ACTIONS=true to allow "
                              "patch assessment, patch installation and AG failover.")


def _operation(resp: Any) -> dict[str, Any]:
    url = resp.headers.get("Azure-AsyncOperation") or resp.headers.get("Location")
    return {"http_status": resp.status_code, "operation_url": url}


def trigger_patch_assessment(machine: str, confirm: bool = False) -> dict[str, Any]:
    """Start an on-demand Update Manager assessment on an Arc machine (no changes to the OS)."""
    m = resolve_machine(machine)
    if not confirm:
        return {"executed": False, "machine": m["name"], "plan": "POST assessPatches; takes 2-5 minutes.",
                "next_step": "Call again with confirm=true to start the assessment."}
    _require_write()
    resp = get_client().post(f"{m['id']}/assessPatches?api-version={API_HYBRID_COMPUTE}")
    clear_cache()
    return {"executed": True, "machine": m["name"], **_operation(resp)}


def enable_periodic_assessment(machine: str, confirm: bool = False) -> dict[str, Any]:
    """Turn on Update Manager periodic assessment (every 24h) for an Arc machine. Does not install anything."""
    m = resolve_machine(machine)
    current = (((m.get("properties") or {}).get("osProfile") or {}).get("windowsConfiguration") or {}) \
        .get("patchSettings") or {}
    if current.get("assessmentMode") == "AutomaticByPlatform":
        return {"executed": False, "machine": m["name"], "message": "Periodic assessment is already enabled."}
    body = {"properties": {"osProfile": {"windowsConfiguration": {"patchSettings": {
        "assessmentMode": "AutomaticByPlatform"}}}}}
    if not confirm:
        return {"executed": False, "machine": m["name"], "current": current, "request_body": body,
                "next_step": "Call again with confirm=true to enable periodic assessment."}
    _require_write()
    resp = get_client().request("PATCH", f"{m['id']}?api-version={API_HYBRID_COMPUTE}", body)
    clear_cache()
    return {"executed": True, "machine": m["name"], "http_status": resp.status_code}


def _ag_context_for_machine(machine_id: str) -> list[dict[str, Any]]:
    """AGs that an instance on this machine participates in, with each member's instance id."""
    inst_ids = {_lower(i["id"]) for i in _engine_instances()
                if _lower((i.get("properties") or {}).get("containerResourceId")) == _lower(machine_id)}
    groups: dict[str, list[dict[str, Any]]] = {}
    for ag in _raw_ag_resources():
        groups.setdefault(_lower(ag["name"]), []).append(ag)
    out = []
    for name, members in groups.items():
        member_ids = {_lower(_instance_id_of_ag(a["id"])) for a in members}
        if member_ids & inst_ids:
            out.append({"ag": members[0]["name"], "members": [
                {"instance_id": _instance_id_of_ag(a["id"]),
                 "instance": _instance_id_of_ag(a["id"]).rsplit("/", 1)[-1],
                 "is_target": _lower(_instance_id_of_ag(a["id"])) in inst_ids} for a in members]})
    return out


def plan_patch_install(machine: str) -> dict[str, Any]:
    """AG-safety preflight for an on-demand patch install. Never changes anything."""
    clear_cache()
    m = resolve_machine(machine)
    blockers, warnings, ag_states = [], [], []
    for ctx in _ag_context_for_machine(m["id"]):
        for mem in ctx["members"]:
            try:
                ev = _live_view(mem["instance_id"], ctx["ag"])["evaluation"]
            except Exception as exc:
                ev = {"healthy": False, "role": None, "message": f"live query failed: {exc}"}
            ag_states.append({"ag": ctx["ag"], "instance": mem["instance"], "is_target": mem["is_target"], **ev})
            if mem["is_target"] and ev.get("role") == "PRIMARY":
                partners = [x["instance"] for x in ctx["members"] if not x["is_target"]]
                blockers.append(f"{mem['instance']} is the PRIMARY of {ctx['ag']}. Fail over to "
                                f"{' or '.join(partners)} first (sqlha_failover_availability_group), or pass failover_first=true.")
            if not mem["is_target"] and not ev.get("healthy"):
                blockers.append(f"Partner {mem['instance']} in {ctx['ag']} is not healthy ({ev.get('message')}); "
                                "patching this node would leave the AG without a healthy replica.")
    machines = _machines_by_id()
    partner_ids = {_lower(i.get("properties", {}).get("containerResourceId")) for i in _engine_instances()
                   if any(_lower(i["name"]) == _lower(s["instance"]) and not s["is_target"] for s in ag_states)}
    for row in _raw_installations():
        p = row.get("properties") or {}
        if row["machineId"] in partner_ids and p.get("status") == "InProgress":
            blockers.append(f"An installation is in progress on partner {(machines.get(row['machineId']) or {}).get('name')}.")
    maint = get_maintenance_windows(count=2)
    for c in maint["configurations"]:
        if any(w.get("in_progress") for w in c.get("next_windows", [])):
            warnings.append(f"Maintenance window of {c['name']} is in progress now.")
    if (m.get("properties") or {}).get("status") != "Connected":
        blockers.append(f"Arc agent on {m['name']} is {(m.get('properties') or {}).get('status')}.")
    patch = get_patch_compliance(m["name"])["machines"]
    outstanding = patch[0]["outstanding"] if patch else []
    if not outstanding:
        warnings.append("No outstanding updates in the latest assessment; consider triggering an assessment first.")
    primary_only = bool(blockers) and all("is the PRIMARY" in b for b in blockers)
    return {"machine": m["name"], "can_proceed": not blockers, "blocked_only_by_primary_role": primary_only,
            "blockers": blockers, "warnings": warnings, "ag_states": ag_states,
            "outstanding": [{k: x[k] for k in ("kb", "name", "classifications", "msrc_severity")} for x in outstanding]}


def install_patches(
    machine: str,
    classifications: list[str] | None = None,
    kb_include: list[str] | None = None,
    kb_exclude: list[str] | None = None,
    max_duration_hours: float = 2.0,
    reboot_setting: str = "IfRequired",
    failover_first: bool = False,
    confirm: bool = False,
) -> dict[str, Any]:
    """AG-safe on-demand patch install on one Arc SQL host via Update Manager installPatches."""
    plan = plan_patch_install(machine)
    if not plan["can_proceed"] and not (failover_first and plan["blocked_only_by_primary_role"]):
        return {"executed": False, "reason": "preflight blocked", **plan}
    body = {
        "maximumDuration": f"PT{int(max_duration_hours * 60)}M",
        "rebootSetting": reboot_setting,
        "windowsParameters": {
            "classificationsToInclude": classifications or ["Critical", "Security", "UpdateRollup", "ServicePack",
                                                            "Definition", "Updates"],
            **({"kbNumbersToInclude": kb_include} if kb_include else {}),
            **({"kbNumbersToExclude": kb_exclude} if kb_exclude else {}),
        },
    }
    if not confirm:
        return {"executed": False, "plan": plan, "request_body": body,
                "failover_planned": failover_first and plan["blocked_only_by_primary_role"],
                "next_step": "Review, then call again with confirm=true."}
    _require_write()
    failover_result = None
    if not plan["can_proceed"]:
        target_ags = {s["ag"] for s in plan["ag_states"] if s["is_target"] and s.get("role") == "PRIMARY"}
        for ag in target_ags:
            partner = next((s for s in plan["ag_states"] if s["ag"] == ag and not s["is_target"] and s.get("failover_ready")), None)
            if not partner:
                return {"executed": False, "reason": f"No failover-ready partner in {ag}.", **plan}
            failover_result = failover_availability_group(partner["instance"], ag, confirm=True)
            if not failover_result.get("success"):
                return {"executed": False, "reason": "failover failed", "failover": failover_result}
        plan = plan_patch_install(machine)
        if not plan["can_proceed"]:
            return {"executed": False, "reason": "preflight still blocked after failover", "failover": failover_result, **plan}
    m = resolve_machine(machine)
    resp = get_client().post(f"{m['id']}/installPatches?api-version={API_HYBRID_COMPUTE}", body, retry=False)
    clear_cache()
    return {"executed": True, "machine": m["name"], "failover": failover_result, **_operation(resp),
            "next_step": "Poll sqlha_get_operation_status, then verify with sqlha_get_availability_groups. "
                         "Fail back if the preferred primary changed."}


def failover_availability_group(target_instance: str, ag_name: str | None = None, confirm: bool = False,
                                timeout_seconds: int = 150) -> dict[str, Any]:
    """Planned (no data loss) failover of an AG to `target_instance`, via the Arc AG API."""
    clear_cache()
    candidates = [a for a in _raw_ag_resources()
                  if _lower(_instance_id_of_ag(a["id"]).rsplit("/", 1)[-1]) == _lower(target_instance)
                  and (ag_name is None or _lower(a["name"]) == _lower(ag_name))]
    if not candidates:
        raise ValueError(f"No availability group found on instance '{target_instance}'.")
    if len(candidates) > 1:
        raise ValueError(f"'{target_instance}' is in several AGs ({', '.join(a['name'] for a in candidates)}); pass ag_name.")
    ag = candidates[0]
    inst_id = _instance_id_of_ag(ag["id"])
    ev = _live_view(inst_id, ag["name"])["evaluation"]
    if ev.get("role") == "PRIMARY":
        return {"executed": False, "success": True, "message": f"{target_instance} is already the primary.", "state": ev}
    if not ev.get("failover_ready"):
        return {"executed": False, "success": False,
                "message": f"{target_instance} is not ready for a planned failover: role={ev.get('role')}, "
                           f"mode={ev.get('mode')}, {ev.get('message')}", "state": ev}
    if not confirm:
        return {"executed": False, "success": None, "state": ev,
                "next_step": f"{target_instance} is failover-ready. Call again with confirm=true to fail over {ag['name']}."}
    _require_write()
    try:
        get_client().post(f"{inst_id}/availabilityGroups/{ag['name']}/failover?api-version={API_ARC_DATA}", retry=False)
    except ArmError as exc:
        # Known API behaviour: HTTP 400 "Failover retrieve null resource" even on success.
        if "failover retrieve null resource" not in str(exc).lower():
            raise
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        time.sleep(10)
        try:
            st = _live_view(inst_id, ag["name"])["evaluation"]
        except Exception:
            continue
        if st.get("role") == "PRIMARY":
            clear_cache()
            return {"executed": True, "success": True, "message": f"{target_instance} is now the primary of {ag['name']}.",
                    "state": st}
    return {"executed": True, "success": False,
            "message": f"Failover requested but {target_instance} is not primary after {timeout_seconds}s."}


def get_operation_status(operation_url: str) -> dict[str, Any]:
    """Status of an ARM async operation returned by assessment or installation tools."""
    if not operation_url.startswith(get_client().settings.arm_endpoint):
        raise ValueError("operation_url must be an Azure Resource Manager URL.")
    resp = get_client().request("GET", operation_url)
    try:
        body = resp.json()
    except ValueError:
        body = {"raw": resp.text[:2000]}
    return {"http_status": resp.status_code, "body": body}
