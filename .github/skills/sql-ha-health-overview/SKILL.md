---
name: sql-ha-health-overview
description: Overall health and status of the SQL Server Always On estate managed through Azure Arc (on AWS or elsewhere). Use for broad questions such as "how are my SQL servers", "anything I should worry about", "status report", "what needs attention", or a daily/weekly ops summary across availability, patching, maintenance windows and security.
---

# SQL HA health overview

Use this skill for broad or ambiguous status questions. It produces a short, prioritized summary across all areas
and points to the drill-down skills.

## Tools

| Step | Tool | Why |
|------|------|-----|
| 1 | `sqlha_get_overview` | KPIs + prioritized findings across availability, patching, maintenance, security |
| 2 (optional) | `sqlha_get_availability_groups` | Confirm live AG roles/health when an availability finding exists |
| 3 (optional) | `sqlha_get_maintenance_windows` | Exact next window when the user asks "when" |

## Procedure

1. Call `sqlha_get_overview` once. If `errors` is not empty, say which sections could not be loaded (often RBAC:
   the identity needs *Reader* on the Arc resource group and *Security Reader* for Defender data).
2. Report the overall state from `kpis.overall`:
   - `critical` → "Action required", `warning` → "Attention", `healthy` → "Healthy".
3. Summarize in this order (skip empty sections):
   1. **Availability**: AG count/healthy, current primary vs preferred primary, any unhealthy or not-failover-ready replica.
   2. **Patching**: outstanding updates (security/critical count), SQL Server CU/GDR pending, last patch run status.
   3. **Maintenance**: next window (local time with time zone and UTC, plus "in Xh"), target node and wave.
   4. **Security**: Defender high-severity count, active alerts.
4. List the top findings (critical and high first, at most 8) as a table: Severity | Area | Finding | Resource | Recommended action.
5. End with 1-3 concrete next steps and offer the relevant drill-down (e.g. "Want me to show why the last wave was cancelled?").

## Interpretation rules

- A **critical "waves overlap"** finding means both AG replicas can be patched and rebooted together. Call this out
  first, unless the user has already said the overlap is intentional (e.g. a test).
- **Cancelled maintenance run + failed Pre-SqlAgFailover job** usually means the pre-event runbook refused to fail
  over (partner unhealthy, not synchronized, or too close to the cancellation cut-off). Suggest
  `sqlha_get_job_output` (see the `sql-ha-patch-compliance` skill).
- **Never assessed / stale assessment** means outstanding-patch counts for that host are unknown, not zero.
- Defender findings are grouped per recommendation. Don't list all of them individually in an overview.

## Output template

```
**Overall: Action required** (2 critical, 13 high) — as of 2026-10-05 13:10 PDT

| Area | Status |
|------|--------|
| Always On | ag-sql-ha healthy · primary SQL-VM-1 (preferred) · SQL-VM-2 failover-ready |
| Patching | 3 outstanding on SQL-VM-1 (1 MSRC-critical: KB5122768) · SQL-VM-2 never assessed |
| Maintenance | Next: 2026-10-05 14:30 PDT (21:30 UTC), SQL-VM-1 + SQL-VM-2 (waves overlap) |
| Security | 18 high Defender recommendations · 0 active alerts |

Top findings: …
Next steps: …
```

For a visual version, use the `sql-ha-dashboard` skill (VS Code only).
