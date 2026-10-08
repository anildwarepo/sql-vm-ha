"""Live SQL Server performance snapshot through Azure Arc Run Command.

SQL Server enabled by Azure Arc doesn't serve monitoring telemetry for every deployment, and the hosts may not run
the Azure Monitor agent. This module runs a fixed, read-only PowerShell + T-SQL script on the host instead. It reads
DMVs as NT AUTHORITY\\SYSTEM (granted VIEW SERVER STATE on Always On instances for cluster health detection) and
returns compact JSON. No query text or data rows are collected.
"""

from __future__ import annotations

import base64
import gzip
import json
import re
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from typing import Any

from .arm import ArmError, get_client

API_RUN_COMMAND = "2026-07-15"  # same Hybrid Compute version as the patching runbooks' Invoke-ArcRunCommand
MARKER = "SQLHA_PERF:"

# Executed on the host. `$Instance` is passed as a validated run command parameter, never interpolated here.
PERF_SCRIPT = r"""
param([string]$Instance = 'MSSQLSERVER')
$ErrorActionPreference = 'Stop'
$server = if ($Instance -eq 'MSSQLSERVER') { 'localhost' } else { "localhost\$Instance" }
$cs = "Server=$server;Database=master;Integrated Security=SSPI;TrustServerCertificate=True;Connect Timeout=15;Application Name=sqlha-perf-snapshot"
$conn = New-Object System.Data.SqlClient.SqlConnection $cs
$conn.Open()
function Q([string]$sql) {
    $cmd = $conn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 30
    $r = $cmd.ExecuteReader(); $rows = @()
    while ($r.Read()) { $o = [ordered]@{}; for ($i = 0; $i -lt $r.FieldCount; $i++) { $v = $r.GetValue($i); if ($v -is [DBNull]) { $v = $null }; $o[$r.GetName($i)] = $v }; $rows += [pscustomobject]$o }
    $r.Close(); return ,$rows
}
$out = [ordered]@{ collected_utc = (Get-Date).ToUniversalTime().ToString('o') }
$out.instance = (Q @"
SELECT @@SERVERNAME AS server, SERVERPROPERTY('ProductVersion') AS build, SERVERPROPERTY('Edition') AS edition,
 DATEDIFF(MINUTE, sqlserver_start_time, SYSDATETIME()) AS uptime_min, cpu_count, scheduler_count,
 CAST(physical_memory_kb/1024 AS int) AS physical_memory_mb, CAST(committed_kb/1024 AS int) AS committed_mb,
 CAST(committed_target_kb/1024 AS int) AS target_mb
FROM sys.dm_os_sys_info
"@)[0]
$out.os_memory = (Q @"
SELECT CAST(total_physical_memory_kb/1024 AS int) AS total_mb, CAST(available_physical_memory_kb/1024 AS int) AS available_mb,
 system_memory_state_desc AS state FROM sys.dm_os_sys_memory
"@)[0]
$out.cpu = Q @"
WITH rb AS (SELECT TOP (30) CONVERT(xml, record) AS x, [timestamp] FROM sys.dm_os_ring_buffers
  WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR' AND record LIKE N'%<SystemHealth>%' ORDER BY [timestamp] DESC)
SELECT x.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]','int') AS sql_pct,
 100 - x.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]','int') - x.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]','int') AS other_pct
FROM rb ORDER BY [timestamp] DESC
"@
$counterSql = @"
SELECT RTRIM(counter_name) AS c, RTRIM(instance_name) AS i, cntr_value AS v FROM sys.dm_os_performance_counters
WHERE (object_name LIKE '%SQL Statistics%' AND counter_name IN ('Batch Requests/sec','SQL Compilations/sec','SQL Re-Compilations/sec'))
   OR (object_name LIKE '%:Databases%' AND instance_name = '_Total' AND counter_name IN ('Transactions/sec','Log Bytes Flushed/sec'))
   OR (object_name LIKE '%Buffer Manager%' AND counter_name IN ('Page life expectancy','Page reads/sec','Page writes/sec'))
   OR (object_name LIKE '%Memory Manager%' AND counter_name IN ('Memory Grants Pending','Total Server Memory (KB)','Target Server Memory (KB)'))
   OR (object_name LIKE '%General Statistics%' AND counter_name IN ('User Connections','Processes blocked'))
   OR (object_name LIKE '%Database Replica%' AND instance_name = '_Total' AND counter_name IN ('Transaction Delay','Mirrored Write Transactions/sec'))
"@
$a = Q $counterSql; $t0 = Get-Date; Start-Sleep -Seconds 2; $b = Q $counterSql; $secs = ((Get-Date) - $t0).TotalSeconds
$rate = 'Batch Requests/sec','SQL Compilations/sec','SQL Re-Compilations/sec','Transactions/sec','Log Bytes Flushed/sec','Page reads/sec','Page writes/sec','Transaction Delay','Mirrored Write Transactions/sec'
$pc = [ordered]@{}
foreach ($x in $b) { $prev = $a | Where-Object { $_.c -eq $x.c -and $_.i -eq $x.i } | Select-Object -First 1
  if ($rate -contains $x.c -and $prev) { $pc[$x.c] = [math]::Round(([double]$x.v - [double]$prev.v) / $secs, 1) } else { $pc[$x.c] = $x.v } }
$out.counters = $pc
$out.sessions = (Q @"
SELECT (SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE is_user_process = 1) AS user_sessions,
 (SELECT COUNT(*) FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id WHERE s.is_user_process = 1) AS active_requests,
 (SELECT COUNT(*) FROM sys.dm_exec_requests WHERE blocking_session_id <> 0) AS blocked_requests
"@)[0]
$out.top_requests = Q @"
SELECT TOP (5) r.session_id AS sid, r.status, r.command, DB_NAME(r.database_id) AS db, r.wait_type AS wait, r.wait_time AS wait_ms,
 r.total_elapsed_time AS elapsed_ms, r.cpu_time AS cpu_ms, r.blocking_session_id AS blocked_by, LEFT(s.program_name, 40) AS program
FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
WHERE s.is_user_process = 1 AND r.session_id <> @@SPID
  AND ISNULL(r.wait_type, '') NOT IN ('XE_LIVE_TARGET_TVF', 'WAITFOR', 'BROKER_RECEIVE_WAITFOR')
ORDER BY r.total_elapsed_time DESC
"@
$out.waits = Q @"
WITH w AS (SELECT wait_type, wait_time_ms, signal_wait_time_ms, waiting_tasks_count FROM sys.dm_os_wait_stats
 WHERE waiting_tasks_count > 0 AND wait_type NOT IN (N'BROKER_EVENTHANDLER',N'BROKER_RECEIVE_WAITFOR',N'BROKER_TASK_STOP',N'BROKER_TO_FLUSH',N'BROKER_TRANSMITTER',N'CHECKPOINT_QUEUE',N'CLR_AUTO_EVENT',N'CLR_MANUAL_EVENT',N'DIRTY_PAGE_POLL',N'DISPATCHER_QUEUE_SEMAPHORE',N'FT_IFTS_SCHEDULER_IDLE_WAIT',N'FT_IFTSHC_MUTEX',N'HADR_CLUSAPI_CALL',N'HADR_FILESTREAM_IOMGR_IOCOMPLETION',N'HADR_LOGCAPTURE_WAIT',N'HADR_NOTIFICATION_DEQUEUE',N'HADR_TIMER_TASK',N'HADR_WORK_QUEUE',N'LAZYWRITER_SLEEP',N'LOGMGR_QUEUE',N'ONDEMAND_TASK_QUEUE',N'PARALLEL_REDO_DRAIN_WORKER',N'PARALLEL_REDO_LOG_CACHE',N'PARALLEL_REDO_TRAN_LIST',N'PARALLEL_REDO_WORKER_SYNC',N'PARALLEL_REDO_WORKER_WAIT_WORK',N'PREEMPTIVE_XE_GETTARGETSTATE',N'PWAIT_ALL_COMPONENTS_INITIALIZED',N'PWAIT_DIRECTLOGCONSUMER_GETNEXT',N'QDS_ASYNC_QUEUE',N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',N'QDS_SHUTDOWN_QUEUE',N'REDO_THREAD_PENDING_WORK',N'REQUEST_FOR_DEADLOCK_SEARCH',N'RESOURCE_QUEUE',N'SERVER_IDLE_CHECK',N'SLEEP_BPOOL_FLUSH',N'SLEEP_DBSTARTUP',N'SLEEP_DCOMSTARTUP',N'SLEEP_MASTERDBREADY',N'SLEEP_MASTERMDREADY',N'SLEEP_MASTERUPGRADED',N'SLEEP_MSDBSTARTUP',N'SLEEP_SYSTEMTASK',N'SLEEP_TASK',N'SLEEP_TEMPDBSTARTUP',N'SNI_HTTP_ACCEPT',N'SOS_WORK_DISPATCHER',N'SP_SERVER_DIAGNOSTICS_SLEEP',N'SQLTRACE_BUFFER_FLUSH',N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',N'SQLTRACE_WAIT_ENTRIES',N'WAIT_FOR_RESULTS',N'WAITFOR',N'WAITFOR_TASKSHUTDOWN',N'WAIT_XTP_RECOVERY',N'WAIT_XTP_HOST_WAIT',N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG',N'WAIT_XTP_CKPT_CLOSE',N'XE_DISPATCHER_JOIN',N'XE_DISPATCHER_WAIT',N'XE_TIMER_EVENT',N'XE_LIVE_TARGET_TVF',N'PWAIT_EXTENSIBILITY_CLEANUP_TASK',N'PREEMPTIVE_SP_SERVER_DIAGNOSTICS',N'PREEMPTIVE_HADR_LEASE_MECHANISM',N'PREEMPTIVE_XE_DISPATCHER',N'PREEMPTIVE_XE_CALLBACKEXECUTE',N'PREEMPTIVE_XE_SESSIONCOMMIT',N'HADR_FABRIC_CALLBACK',N'VDI_CLIENT_OTHER',N'SOS_WORK_DISPATCHER')
   AND wait_type NOT LIKE N'PREEMPTIVE_OS_%' AND wait_type NOT LIKE N'SLEEP_%')
SELECT TOP (8) wait_type AS wait, CAST(wait_time_ms/1000.0 AS decimal(18,1)) AS wait_s,
 CAST(100.0 * wait_time_ms / NULLIF(SUM(wait_time_ms) OVER (), 0) AS decimal(5,1)) AS pct,
 CAST(1.0 * wait_time_ms / waiting_tasks_count AS decimal(18,1)) AS avg_ms,
 CAST(100.0 * signal_wait_time_ms / NULLIF(wait_time_ms, 0) AS decimal(5,1)) AS signal_pct
FROM w ORDER BY wait_time_ms DESC
"@
$out.io = Q @"
SELECT TOP (8) DB_NAME(f.database_id) AS db, mf.type_desc AS type,
 CAST(f.io_stall_read_ms * 1.0 / NULLIF(f.num_of_reads, 0) AS decimal(10,1)) AS read_ms,
 CAST(f.io_stall_write_ms * 1.0 / NULLIF(f.num_of_writes, 0) AS decimal(10,1)) AS write_ms,
 f.num_of_reads AS reads, f.num_of_writes AS writes, LEFT(mf.physical_name, 3) AS drive
FROM sys.dm_io_virtual_file_stats(NULL, NULL) f JOIN sys.master_files mf ON mf.database_id = f.database_id AND mf.file_id = f.file_id
ORDER BY (f.io_stall_read_ms + f.io_stall_write_ms) DESC
"@
$out.volumes = Q @"
SELECT DISTINCT vs.volume_mount_point AS mount, CAST(vs.total_bytes/1048576 AS bigint) AS total_mb, CAST(vs.available_bytes/1048576 AS bigint) AS free_mb
FROM sys.master_files mf CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
"@
$out.ag = Q @"
SELECT ag.name AS ag, ar.replica_server_name AS replica, DB_NAME(drs.database_id) AS db, drs.is_local AS local,
 drs.synchronization_state_desc AS sync, drs.synchronization_health_desc AS health, drs.is_suspended AS suspended,
 drs.log_send_queue_size AS send_queue_kb, drs.log_send_rate AS send_rate_kbs, drs.redo_queue_size AS redo_queue_kb,
 drs.redo_rate AS redo_rate_kbs, drs.secondary_lag_seconds AS lag_s, drs.last_commit_time AS last_commit
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id JOIN sys.availability_groups ag ON ag.group_id = drs.group_id
ORDER BY ag.name, db, ar.replica_server_name
"@
$conn.Close()
$json = $out | ConvertTo-Json -Depth 5 -Compress
$ms = New-Object IO.MemoryStream; $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Compress)
$bytes = [Text.Encoding]::UTF8.GetBytes($json); $gz.Write($bytes, 0, $bytes.Length); $gz.Close()
Write-Output ('SQLHA_PERF:' + [Convert]::ToBase64String($ms.ToArray()))
"""


def _decode(output: str) -> dict[str, Any]:
    idx = (output or "").rfind(MARKER)
    if idx < 0:
        raise RuntimeError(f"No snapshot in run command output: {(output or '')[-400:]}")
    blob = output[idx + len(MARKER):].split()[0]
    return json.loads(gzip.decompress(base64.b64decode(blob)).decode("utf-8"))


def _run(machine: dict[str, Any], instance: str, timeout_seconds: int) -> dict[str, Any]:
    if not re.fullmatch(r"[A-Za-z0-9_$]{1,16}", instance or ""):
        raise ValueError(f"Invalid SQL instance name '{instance}'.")
    client = get_client()
    name = f"sqlha-perf-{uuid.uuid4().hex[:8]}"
    path = f"{machine['id']}/runCommands/{name}?api-version={API_RUN_COMMAND}"
    body = {"location": machine["location"], "properties": {
        "source": {"script": PERF_SCRIPT},
        "parameters": [{"name": "Instance", "value": instance}],
        "timeoutInSeconds": timeout_seconds, "asyncExecution": False}}
    started = time.time()
    try:
        client.request("PUT", path, body, retry=False)
        deadline = started + timeout_seconds + 60
        while True:
            time.sleep(4)
            try:
                rc = client.get(path)
            except ArmError as exc:
                # The resource isn't readable for a few seconds after the PUT is accepted.
                if exc.status == 404 and time.time() - started < 60:
                    continue
                raise
            props = rc.get("properties") or {}
            iv = props.get("instanceView") or {}
            state, ex = props.get("provisioningState"), iv.get("executionState")
            if state in ("Failed", "Canceled") or (state == "Succeeded" and ex in ("Succeeded", "Failed", "TimedOut", "Canceled")):
                break
            if time.time() > deadline:
                raise TimeoutError(f"Run command did not finish in {timeout_seconds + 60} s (state={state}/{ex}).")
        if ex != "Succeeded":
            raise RuntimeError(f"Run command {state}/{ex}: {(iv.get('error') or iv.get('output') or '')[-500:]}")
        snap = _decode(iv.get("output") or "")
        snap["duration_s"] = round(time.time() - started, 1)
        return snap
    finally:
        try:
            client.request("DELETE", path, retry=False)
        except ArmError:
            pass


def _summarize(snap: dict[str, Any]) -> dict[str, Any]:
    cpu = [r for r in snap.get("cpu") or [] if r.get("sql_pct") is not None]
    c = snap.get("counters") or {}
    mem = snap.get("os_memory") or {}
    flags = []
    if cpu and cpu[0]["sql_pct"] >= 80:
        flags.append(f"high SQL CPU now ({cpu[0]['sql_pct']}%)")
    if (c.get("Page life expectancy") or 10**9) < 300:
        flags.append(f"low page life expectancy ({c.get('Page life expectancy')} s)")
    if (c.get("Memory Grants Pending") or 0) > 0:
        flags.append(f"memory grants pending ({c.get('Memory Grants Pending')})")
    if (snap.get("sessions") or {}).get("blocked_requests"):
        flags.append(f"{snap['sessions']['blocked_requests']} blocked request(s)")
    if mem.get("state") and "low" in str(mem["state"]).lower():
        flags.append(f"OS memory: {mem['state']}")
    for r in snap.get("ag") or []:
        if (r.get("send_queue_kb") or 0) > 10240 or (r.get("redo_queue_kb") or 0) > 10240:
            flags.append(f"AG queue on {r.get('replica')}/{r.get('db')}: send {r.get('send_queue_kb')} KB, redo {r.get('redo_queue_kb')} KB")
    for f in snap.get("io") or []:
        if (f.get("read_ms") or 0) > 20 or (f.get("write_ms") or 0) > 20:
            flags.append(f"slow IO {f.get('db')} {f.get('type')}: read {f.get('read_ms')} ms, write {f.get('write_ms')} ms")
    for v in snap.get("volumes") or []:
        if v.get("total_mb") and v.get("free_mb") is not None and v["free_mb"] / v["total_mb"] < 0.1:
            flags.append(f"volume {v.get('mount')} {round(100 * v['free_mb'] / v['total_mb'])}% free")
    return {
        "cpu_sql_pct_now": cpu[0]["sql_pct"] if cpu else None,
        "cpu_sql_pct_avg_30min": round(sum(r["sql_pct"] for r in cpu) / len(cpu), 1) if cpu else None,
        "cpu_sql_pct_max_30min": max((r["sql_pct"] for r in cpu), default=None),
        "cpu_other_pct_avg_30min": round(sum((r.get("other_pct") or 0) for r in cpu) / len(cpu), 1) if cpu else None,
        "attention": flags,
    }


def get_performance_snapshot(machines: list[dict[str, Any]], instances: dict[str, str],
                             timeout_seconds: int = 90) -> dict[str, Any]:
    """Run the snapshot on each machine in parallel. `instances` maps machine name -> SQL instance name."""
    def one(m: dict[str, Any]) -> dict[str, Any]:
        try:
            snap = _run(m, instances.get(m["name"], "MSSQLSERVER"), timeout_seconds)
            summary = _summarize(snap)
            snap.pop("cpu", None)  # summarized; the raw minute samples are noisy for the model
            return {"machine": m["name"], "ok": True, "summary": summary, **snap}
        except Exception as exc:
            return {"machine": m["name"], "ok": False, "error": f"{type(exc).__name__}: {exc}"}

    with ThreadPoolExecutor(max_workers=max(1, min(8, len(machines)))) as pool:
        results = list(pool.map(one, machines))
    return {
        "source": "Live DMV snapshot via Azure Arc Run Command (read-only, no query text collected)",
        "notes": "CPU covers the last ~30 minutes. Wait and IO statistics are cumulative since the SQL Server "
                 "service last started (see instance.uptime_min). Rates are measured over 2 seconds.",
        "nodes": results,
    }
