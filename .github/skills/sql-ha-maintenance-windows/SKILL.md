---
name: sql-ha-maintenance-windows
description: Azure Update Manager maintenance windows for Always On SQL nodes - next patch window per node, recurrence, time zone, duration, AG-aware waves (wave 1 secondary first, wave 2 primary), included classifications, excluded KBs, overlapping or missing schedules, and how to change the schedule. Use for "when is the next maintenance window", "when will SQL-VM-1 be patched", "what is the patch schedule", "are the waves safe", "move the window to Sunday".
---

# Maintenance windows

The SQL hosts are patched by **AG-aware waves**: one maintenance configuration per node, tagged with
`SqlAgName`, `SqlAgTarget`, `SqlAgPartner`, `SqlAgPreferredPrimary` and `SqlAgWave`. Event Grid pre/post
events start the `Pre-SqlAgFailover` and `Post-SqlAgValidate` runbooks so the node being patched is never the
primary. By default wave 1 patches the secondary and wave 2 patches the preferred primary 90 minutes later,
after failing over to the freshly patched secondary, then fails back.

## Tools

| Tool | Use |
|------|-----|
| `sqlha_get_maintenance_windows(count)` | Schedules, next N windows (local + UTC, `in_progress`), host assignments, risks |
| `sqlha_get_patch_history` | What happened in previous windows |
| `sqlha_get_availability_groups` | Which node is primary *now*, which determines whether a failover will occur |

## Answering "when"

0. Schedules are read live from ARM, so a change made in the portal shows up immediately. Host assignments and
   run history come from Resource Graph and can lag a few minutes.
1. Call `sqlha_get_maintenance_windows`.
2. Give the next window per node: `Node | Wave | Local start–end (time zone) | UTC | Starts in`.
   Always include the configuration's time zone name and UTC. Mention `in_progress` windows first.
3. Explain the flow for the coming run, given the current primary:
   - Pre-event about 30-40 min before each window: the runbook fails over off the target node if it is primary,
     or cancels the run if the partner isn't healthy.
   - Window: install the configured classifications and reboot if required (`reboot_setting`).
   - Post-event: wait for the node to be healthy, then fail back to the preferred primary.
4. Mention classifications and excluded KBs when asked "what will be installed".

## Risks to flag (from `risks`)

| Risk | Severity | Meaning |
|------|----------|---------|
| AG waves overlap | critical | Both replicas can be patched/rebooted together, which means an AG outage |
| AG waves are only N min apart | high (< 40 min) / medium (< 90 min) | The later wave's pre-event fires while the earlier node may still be patching or resyncing, so that wave is likely cancelled |
| AG waves run in reverse order | medium | Wave 2 (usually the preferred primary) is patched before wave 1, which means a failover before the secondary has been validated |
| Host has no maintenance schedule | high | Host is never patched by Update Manager |
| Host is in multiple schedules | high | A non-AG-aware schedule can patch it at any time |
| Host may match a dynamic scope | medium | A subscription-level dynamic scope could include an AG node |
| Partner has no AG-aware wave | high | Only one side of the AG is scheduled |

If the user says an overlap is intentional (e.g. a test), acknowledge it once and don't keep repeating the warning.

## Changing the schedule

Schedules, Event Grid subscriptions, webhooks and runbooks are managed together by
`scripts/patching/Enable-SqlAgPatching.ps1`. Change them only through that script so the pre/post wiring stays consistent.

```powershell
# Second Saturday of each month, first wave at 01:00 Pacific, 90 min gap between waves
.\scripts\patching\Enable-SqlAgPatching.ps1 -RecurEvery 'Month Second Saturday' -StartTime '01:00' -GapMinutes 90
# Exclude a KB from both waves
.\scripts\patching\Enable-SqlAgPatching.ps1 -ExcludeKbs 5104824
# Rotate the Event Grid webhooks before they expire (365 days)
.\scripts\patching\Enable-SqlAgPatching.ps1 -RotateWebhooks
```

In VS Code, preview the command and run it in the terminal only after the user approves. The hosted agent can't
run scripts; give the command to the user instead. After a change, call `sqlha_get_maintenance_windows` again to
confirm the new next windows and that `risks` is empty.

Recurrence syntax (`recurEvery`): `Day`, `3Days`, `Week Saturday`, `2Weeks Saturday,Sunday`,
`Month day15`, `Month day-1` (last day), `Month Second Saturday`, `Month Last Sunday Offset-3`.
