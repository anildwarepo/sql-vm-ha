---
name: sql-ha-patch-orchestration
description: Safely patch or update Arc-enabled SQL Server Always On nodes on demand - AG-aware preflight, fail over off the primary, install Windows/SQL Server updates with Azure Update Manager, validate resynchronization and fail back. Use when the user asks to "patch SQL-VM-2 now", "install the SQL CU", "apply the critical security update", "rerun the cancelled wave", or "fail over and patch the primary".
---

# AG-safe on-demand patching

Use this for out-of-band patching. Routine patching happens in the scheduled waves (see
`sql-ha-maintenance-windows`). Every step that changes something needs explicit user approval.

## Golden rules

1. **One node at a time.** Never start an install on a node while its partner is patching, rebooting, or unhealthy.
2. **Never patch the primary.** Fail over to a failover-ready synchronous secondary first.
3. **Patch the secondary first**, validate it, then fail over to it, patch the old primary, validate, and fail back
   to the preferred primary.
4. Preview (`confirm=false`), then show the plan, then get explicit approval, then execute (`confirm=true`), then verify.
5. Stop at the first failed check and report. Don't improvise around a blocker.

## Tools

| Tool | Kind |
|------|------|
| `sqlha_plan_patch_install(machine)` | read-only preflight: live AG roles, blockers, warnings, outstanding updates |
| `sqlha_install_patches(machine, classifications?, kb_include?, kb_exclude?, max_duration_hours, reboot_setting, failover_first, confirm)` | **write, disruptive** |
| `sqlha_failover_availability_group(target_instance, ag_name?, confirm)` | **write, disruptive** |
| `sqlha_get_operation_status(operation_url)` | poll an install/assessment |
| `sqlha_get_availability_groups` / `sqlha_get_patch_compliance` | validate after each step |

## Full two-node procedure

```
0. sqlha_get_overview                        → no critical availability findings; note current primary P and secondary S
1. sqlha_plan_patch_install(S)               → can_proceed must be true
2. sqlha_install_patches(S, confirm=false)   → show request body + outstanding KBs → user approves
3. sqlha_install_patches(S, confirm=true)    → poll sqlha_get_operation_status until terminal
4. sqlha_get_availability_groups             → S healthy + failover_ready (allow up to ~45 min after reboot)
5. sqlha_failover_availability_group(S, confirm=false → approve → true)   → S becomes primary
6. sqlha_plan_patch_install(P) → sqlha_install_patches(P …) → poll
7. sqlha_get_availability_groups             → P healthy + failover_ready
8. Fail back: sqlha_failover_availability_group(P …) if P is the preferred primary
9. sqlha_get_patch_compliance                → confirm KBs gone (re-run assessment if Resource Graph is stale)
```

Shortcut for a single node that is currently primary: `sqlha_install_patches(machine, failover_first=true, …)`
fails over to the failover-ready partner, re-checks, then installs. It does **not** fail back. Do step 8 yourself.

## Choosing what to install

- Specific KB (e.g. the MSRC-critical SQL GDR): `kb_include=["5122768"]`.
- Security only: `classifications=["Critical","Security"]`.
- SQL Server CUs are classified as *Updates*. Include `"Updates"` or pass the KB.
- `max_duration_hours` must leave time for reboot (default 2). `reboot_setting` defaults to `IfRequired`.

## When preflight is blocked

| Blocker | Action |
|---------|--------|
| "is the PRIMARY" | Fail over first (step 5) or use `failover_first=true` |
| "Partner … is not healthy" | Stop. Investigate with `sql-ha-always-on`; patching now would leave no healthy replica |
| "installation is in progress on partner" | Wait for it to finish and validate |
| "Arc agent … Disconnected" | Fix Arc connectivity (Azure Connected Machine agent on the host) first |
| Warning "maintenance window … in progress" | Prefer to let the scheduled wave run instead of starting an overlapping one |

## When write actions are disabled

If a tool returns `write_actions_disabled`, write actions are turned off for this agent
(`SQLHA_ENABLE_WRITE_ACTIONS` is not `true`). Explain this and offer the manual equivalent: Azure portal →
Azure Update Manager → select the machine → *One-time update*, and the Arc SQL instance → *Availability Groups* →
*Failover*. Follow the same order as above.

## Report format after execution

`Step | Action | Result | Evidence (role/health/KB status, timestamp)`. End with the final AG state and remaining outstanding updates.
