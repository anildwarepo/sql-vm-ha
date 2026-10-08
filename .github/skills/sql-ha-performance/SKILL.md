---
name: sql-ha-performance
description: Live performance of Arc-enabled SQL Server Always On nodes - CPU, memory and page life expectancy, batch requests and transactions per second, sessions and blocking, top wait types, IO latency per database file, disk free space, and Always On log send / redo queues and secondary lag. Use for "how is performance", "is SQL-VM-1 busy", "any blocking", "why is it slow", "what are the top waits", "is the secondary lagging", "how much memory is SQL using".
---

# SQL Server performance

## Tool

`sqlha_get_performance_snapshot(machine?)` runs a fixed, read-only DMV script on each host through Azure Arc Run
Command. It takes about 20-40 s and the result is cached for 60 s, so follow-up questions are instant. Omit
`machine` to snapshot every SQL host in parallel. No query text or data rows are collected.

Why Run Command: these instances don't serve Arc SQL monitoring telemetry, and the hosts have no Azure Monitor
agent, so there's no metric history in Azure. Each answer is a point-in-time snapshot. Say so when users ask
about trends.

## Reading the result (per node)

| Field | Meaning | Rule of thumb |
|-------|---------|---------------|
| `summary.cpu_sql_pct_now / _avg_30min / _max_30min` | SQL Server process CPU % | > 80 % sustained is high. `cpu_other_pct_avg_30min` > 20 % means another process is competing |
| `counters["Page life expectancy"]` | Seconds a page stays in the buffer pool | < 300 s suggests memory pressure |
| `counters["Memory Grants Pending"]` | Queries waiting for workspace memory | > 0 means memory pressure |
| `counters["Total/Target Server Memory (KB)"]`, `os_memory` | SQL memory use vs target; OS state | Total far below target after a restart is normal (cache warming) |
| `counters["Batch Requests/sec"]`, `["Transactions/sec"]` | Workload throughput (2 s sample) | Compare across nodes; the primary does the writes |
| `sessions`, `top_requests` | User sessions, active and blocked requests, longest running requests | `blocked_by` ≠ 0 means blocking |
| `waits` | Top waits since startup, excluding idle/background waits | `PAGEIOLATCH_*` = IO reads, `WRITELOG` = log IO, `LCK_M_*` = blocking, `HADR_SYNC_COMMIT` = sync-commit latency to the secondary, `CXPACKET/CXCONSUMER` = parallelism, `SOS_SCHEDULER_YIELD` = CPU |
| `io` | Average read/write latency per file since startup | > 20 ms data / > 5 ms log is slow |
| `volumes` | Free space per volume holding database files | < 10 % free is a risk |
| `ag` | Per database replica: sync state, `send_queue_kb`, `redo_queue_kb`, rates, `lag_s` | Growing queues or lag mean the secondary is falling behind, so a failover would be slower or lose data (async) |
| `instance.uptime_min` | Minutes since SQL Server started | Waits/IO are cumulative since then; a recent restart (e.g. patching) resets them |
| `summary.attention` | Pre-computed flags | Mention these first |

## Answering

1. Call `sqlha_get_performance_snapshot` (one node if the user named one or is looking at one in the dashboard).
2. Lead with a one-line verdict per node (e.g. "SQL-VM-2 (primary): healthy, light load, 2 batch req/s").
3. Then a compact table: Node | Role | SQL CPU now/avg | PLE | Batch req/s | Sessions (active/blocked) | Top wait | AG queues.
4. Call out `summary.attention` items and explain them in plain words.
5. If a node returns `ok: false`, say why (e.g. the node is patching or rebooting, Arc agent disconnected, or the
   identity lacks `Microsoft.HybridCompute/machines/runCommands/write`). Don't guess its metrics.
6. Combine with `sqlha_get_availability_groups` when the question is about AG health (roles, sync state).
