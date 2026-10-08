---
name: sql-ha-patch-compliance
description: Patch status of Arc-enabled SQL Server hosts from Azure Update Manager - outstanding/missing Windows and SQL Server updates (CU, GDR, security), MSRC severity, SQL build level, last assessment, reboot pending, patch history and why a patch wave was cancelled or failed. Use for "what patches are outstanding", "is SQL-VM-1 up to date", "which SQL CU is pending", "did patching succeed last weekend", "why was patching cancelled".
---

# Patch compliance and history

## Tools

| Tool | Use |
|------|-----|
| `sqlha_get_patch_compliance(machine?)` | Outstanding updates per host, counts by classification, SQL updates, assessment age, last install |
| `sqlha_get_inventory` | Current SQL build (`build`) and base version per instance |
| `sqlha_get_patch_history(days)` | Maintenance runs per schedule/wave (Succeeded/Cancelled/Failed + error) and installations |
| `sqlha_get_orchestration_jobs` | Pre-SqlAgFailover / Post-SqlAgValidate runbook runs |
| `sqlha_get_job_output(job_name)` | The runbook log, i.e. the real reason a wave was cancelled or failed |
| `sqlha_trigger_patch_assessment(machine, confirm)` | Refresh a stale or missing assessment (**write, safe**) |
| `sqlha_enable_periodic_assessment(machine, confirm)` | Assess every 24h (**write, safe**) |

## "What is outstanding?"

1. Call `sqlha_get_patch_compliance` (filtered by `machine` when the user names a host).
2. For each host, report outstanding total, security/critical count, MSRC-critical count, reboot pending, and
   assessment age. If `assessment_stale` is true or `last_assessed` is null, say the list may be incomplete
   and offer to run an assessment.
3. Table of outstanding updates, sorted MSRC-critical → security → oldest:
   KB | Title | Classification | MSRC | Published (age) | SQL?
4. Call out SQL Server updates (`is_sql_server_update`) separately and pair them with the instance's current
   `build` from `sqlha_get_inventory` (for example "SQL Server 2022 at 16.0.4255.1; CU27 KB5104824 pending").
   Don't guess CU numbers from builds; use only the update titles returned.
5. Remind the user that the nodes are patched one at a time by the AG-aware waves (see `sql-ha-maintenance-windows`)
   and say when each host's next window is.

## "Did patching work?" / "Why was it cancelled?"

1. Call `sqlha_get_patch_history(days=30)`. Show runs per schedule: Start | Schedule | Wave/Node | Status | Error.
2. For Cancelled or Failed runs, call `sqlha_get_orchestration_jobs` and find the Pre-SqlAgFailover /
   Post-SqlAgValidate jobs created around the run start (the pre-event fires 30-40 min before the window).
3. Call `sqlha_get_job_output(job_name)` for the relevant job, quote the decisive log lines, and explain them:
   - "partner … not ready / not synchronized / stale data" → the runbook refused to fail over, so it cancelled the
     run to protect the AG. This is working as designed.
   - "too little time before cancellation cut-off" → the pre-event was late.
   - Post-SqlAgValidate failure "not healthy after N seconds" → the node didn't rejoin/resynchronize after reboot. The next wave will then cancel.
   - "Maintenance cancelled using Cancellation API" in the run error confirms the runbook cancelled it.
4. Recommend the fix (heal the replica, then rerun on demand with the `sql-ha-patch-orchestration` skill, or wait for the next window).

## Refreshing assessments (write, safe)

Call `sqlha_trigger_patch_assessment(machine, confirm=false)`, tell the user it scans only (2-5 min, no install,
no reboot), and on approval call with `confirm=true`. Poll with `sqlha_get_operation_status(operation_url)` and
then re-run `sqlha_get_patch_compliance` (Resource Graph can lag a few minutes).
If Defender reports "Machines should be configured to periodically check for missing system updates", offer
`sqlha_enable_periodic_assessment`.

## Useful query (`sqlha_query_resource_graph`)

```kusto
patchassessmentresources
| where type =~ 'microsoft.hybridcompute/machines/patchassessmentresults/softwarepatches'
| extend machine = tostring(split(id, '/')[8])
| project machine, kb = tostring(properties.kbId), title = tostring(properties.patchName),
          cls = tostring(properties.classifications[0]), msrc = tostring(properties.msrcSeverity),
          published = todatetime(properties.publishedDateTime)
```
