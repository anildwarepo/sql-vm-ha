# Scaling AG-aware patching to hundreds of SQL instances

> **Design document.** The scripts in this folder use one schedule per node, which suits a few AGs. This document describes the wave approach for large estates (for example 267 instances). It is not implemented yet.

## Why the per-node design doesn't scale

| Per-node design | At ~267 instances |
|-----------------|-------------------|
| One maintenance configuration per node | 267 schedules, over the limit of **250 per subscription per region**, plus one Event Grid topic each |
| Node and partner hard-coded in configuration tags | Can't describe AGs with 3+ replicas, instances that host several AGs, or standalone instances |
| Pre-runbook handles nodes one at a time (~3 s per state check, ~20 s per failover) | Failing over 100+ AGs one by one takes 35+ min; a pre-event must finish in **20 min** |
| An unsafe node cancels the run | Cancellation applies to the **whole run**: one bad AG would skip every machine in it |

## The wave approach

Machines are grouped into a few large **waves**. Each wave has one schedule. There is one rule:

> **Two replicas of the same AG are never in the same wave.**

Machines in one schedule are patched in parallel, so a wave takes about the same time whether it has 5 machines or 500.

### Example layout

| Wave (`PatchWave` tag) | Members | Recurrence (example) |
|------------------------|---------|----------------------|
| `Pilot` | Dev/test instances | `Month Second Tuesday Offset2` (Thu after Patch Tuesday) |
| `Standalone` | Instances without an AG | `Month Second Tuesday Offset4` 01:00-03:55 |
| `AG-A` | One replica of every AG | `Month Second Tuesday Offset4` 01:00-03:55 |
| `AG-B` | Second replica of every AG | `Month Second Tuesday Offset4` 05:30-09:25 |
| `AG-C` | Third replicas (if any) | `Month Second Tuesday Offset5` 01:00-03:55 |
| `AG-DR` | Asynchronous DR replicas | Own window; never a failover target |

This is 5-8 schedules in total. Split further by region, time zone or business unit if needed (for example `AG-A-EU`, `AG-A-US`), which is still far below the 250 limit.

### Components

| Component | Per-node design (today) | Wave design |
|-----------|-------------------------|-------------|
| Maintenance configurations | 1 per node | 1 per wave (and region) |
| Membership | Static assignment per machine | **Dynamic scope** on the `PatchWave` tag (up to 1,000 machines per scope, 3,000 per schedule) |
| Event Grid system topics | 1 per node | 1 per wave |
| Webhooks and runbooks | 2 | 2 (same webhooks for all waves) |
| AG topology | Configuration tags | Discovered from Azure Resource Graph at run time |
| Role assignments | Per machine and configuration | Once, at resource-group or subscription scope |

## Assigning waves

Arc discovers every AG and publishes it to Azure Resource Graph as `microsoft.azurearcdata/sqlserverinstances/availabilitygroups`. This query lists each AG with its replica machines, current primary and health (tested against this repo's deployment):

```kusto
resources
| where type =~ 'microsoft.azurearcdata/sqlserverinstances/availabilitygroups'
| extend agId = tostring(properties.availabilityGroupId), agName = name,
         instanceId = tostring(split(tolower(id), '/availabilitygroups/')[0]),
         primary = tostring(properties.info.primaryReplica),
         health = tostring(properties.info.synchronizationHealthDescription)
| join kind=inner (
    resources
    | where type =~ 'microsoft.azurearcdata/sqlserverinstances'
    | project instanceId = tolower(id), machineId = tolower(tostring(properties.containerResourceId))
  ) on instanceId
| summarize replicas = make_set(machineId), primary = any(primary), health = any(health) by agId, agName
```

A wave-assignment script (planned: `Set-SqlPatchWaves.ps1`) turns this into tags:

1. **Build a graph.** Each machine is a node. Two machines are linked if they share any AG.
2. **Colour the graph.** Linked machines must get different waves (`AG-A`, `AG-B`, `AG-C`, ...). A greedy algorithm that starts with the most-connected machines is enough. Instances that host several AGs are handled automatically.
3. **Pin preferences.** Put the usual primary in the *last* wave, so each AG fails over once and fails back once. Put asynchronous replicas in `AG-DR`. Honour manual overrides (`PatchWaveOverride` tag).
4. **Add the rest.** Arc SQL instances with no AG go to `Standalone`. Machines tagged `PatchRing=Pilot` go to `Pilot`.
5. **Validate and write.** Fail if any AG has two replicas in one wave, or if a wave exceeds the scope limits. Then write the `PatchWave` tag on each Arc machine. Run the script on a schedule (for example daily) so new or changed AGs are picked up before the next patch day.

## Runbook changes

The same two runbooks serve every wave. They no longer read node names from configuration tags.

### Pre-maintenance (`Pre-SqlAgFailover`)

1. **Find the machines in this run.** Query `maintenanceresources` for the run's `CorrelationId` (query from Microsoft's Update Manager documentation, not yet tested here; no maintenance run has occurred in this environment):
   ```kusto
   maintenanceresources
   | where type =~ 'microsoft.maintenance/maintenanceconfigurations/applyupdates'
   | where properties.correlationId has '<CorrelationId>'
   ```
2. **Find the affected AGs.** Look up every AG that has a replica on those machines (query above).
3. **Plan the failovers.** For each AG whose primary is in this run, choose a target replica that:
   - is **not** in this run,
   - uses synchronous commit and is `CONNECTED`, and
   - has all its databases failover-ready.
4. **Fail over in parallel.** Call the Arc AG `failover` API for each planned failover with PowerShell 7 `ForEach-Object -Parallel -ThrottleLimit 25`. Each call takes about 10 s, then `getDetailView` verifies the new primary (see [README.md](README.md#how-the-runbooks-talk-to-sql-server)). That is about 1 minute for 100+ AGs. The current per-node runbooks check nodes one at a time, about 3 s each.
5. **Handle machines that aren't safe** (no eligible target, failover failed, or unreachable), per machine:
   - **Preferred:** remove the machine from this run by changing its `PatchWave` tag to `Skipped-<date>`. It is then patched next cycle or manually. **This must be tested first:** confirm that Update Manager evaluates the dynamic scope *after* the pre-event, not when the pre-event fires.
   - **Fallback:** if the machine can't be excluded before the cancellation cut-off, cancel the whole run. This protects the AG but skips the entire wave.
6. **Stay within the time budget.** Stop scheduling new work 2 minutes before `CancellationCutOffDateTime`.

### Post-maintenance (`Post-SqlAgValidate`)

1. Get the machines in the run (same query as above) and validate them in parallel. For each machine:
   - Arc SQL extension reporting fresh data (`getDetailView` `collectionTimestamp`),
   - SQL Server running,
   - every local AG database synchronized.
2. Fail each AG back to its preferred primary (the `SqlAgPreferredPrimary` tag on the AG's primary machine, or the wave pinning), but only if all its replicas are healthy.
3. Restore machines tagged `Skipped-*` to their wave, if they are healthy and the reason was transient.
4. Write one summary for the wave (patched, failed, skipped, failed over, failed back) to Log Analytics or as a job output. Raise an alert if anything is unhealthy.

The next wave's pre-runbook checks AG health again, so an unhealthy replica from the previous wave blocks only the AGs that depend on it.

### Automation limits

Use a single job per event with in-job parallelism, rather than one child job per machine. This stays clear of Automation job-submission and concurrency limits. Use a **PowerShell 7.2+** runtime for `ForEach-Object -Parallel`. If a wave needs more than about 20 minutes of pre-work, split it into more waves.

## Timeline for one patch cycle

```text
Thu      Pilot        patch dev/test; review results
Sat 00:20            pre-events: AG-A and Standalone (fail over AGs whose primary is in AG-A)
Sat 01:00-03:55      AG-A + Standalone patched in parallel
Sat ~04:00           post-events: validate AG-A, fail back where preferred
Sat 04:50            pre-event: AG-B (fail over AGs whose primary is in AG-B)
Sat 05:30-09:25      AG-B patched
Sat ~09:30           post-event: validate AG-B, fail back to preferred primaries
Sun                  AG-C / AG-DR if present
```

Keep at least 60 minutes between one wave's end and the next wave's pre-event. That gives replicas time to reboot and resynchronize.

## Special cases

| Case | Handling |
|------|----------|
| Failover cluster instances (FCIs) | Update Manager isn't cluster-aware. Drain the node before patching (`Suspend-ClusterNode -Drain`) and resume it afterwards (`Resume-ClusterNode -Failback Immediate`). Put FCI nodes of the same cluster in different waves. |
| Asynchronous replicas | Never a failover target (that would lose data). Patch them in `AG-DR`. |
| Distributed AGs | Treat each side as its own AG. Fail over the global primary only in a planned change window, not from a runbook. |
| Basic AGs / 2-node clusters | Same as a normal AG; a planned failover still works. |
| Machines in several regions | One schedule per region per wave, or a dynamic scope with multiple locations. |
| Instances excluded from patching | Tag `PatchWave=Excluded`; no schedule selects it. |

## Operations

**Reporting.** Resource Graph gives per-machine patch results across the estate:

```kusto
patchinstallationresources
| where type =~ 'microsoft.hybridcompute/machines/patchinstallationresults'
| project machine = tostring(split(id, '/')[8]), status = tostring(properties.status),
          startedOn = todatetime(properties.startDateTime), installed = toint(properties.installedPatchCount),
          failed = toint(properties.failedPatchCount), reboot = tostring(properties.rebootStatus)
| order by startedOn desc
```

**Alerts.** Alert on:
- failed runbook jobs,
- machines `Skipped-*` for more than one cycle,
- AGs whose `synchronizationHealthDescription` isn't `HEALTHY` after a wave.

**Compliance.** Use Azure Policy to enforce:
- periodic assessment on all Arc machines,
- a `PatchWave` tag on every Arc SQL machine,
- no other maintenance configurations on those machines.

## Migrating from the per-node design

1. Run `Disable-SqlAgPatching.ps1` (keep the Windows Update policy on the nodes).
2. Run the wave-assignment script in report-only mode and review the proposed waves.
3. Create the wave schedules with dynamic scopes, a system topic per wave, the webhooks and the updated runbooks.
4. Tag the pilot machines first and run one cycle.
5. Tag production machines and run the wave-assignment script on a schedule.
