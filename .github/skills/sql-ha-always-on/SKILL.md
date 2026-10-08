---
name: sql-ha-always-on
description: Always On availability group status for Arc-enabled SQL Server - which replica is primary or secondary, synchronization health, per-database sync state, failover readiness, preferred primary, and planned failover or failback. Use for questions like "is the AG healthy", "who is primary", "are databases synchronized", "can we fail over", "fail back to SQL-VM-1".
---

# Always On availability groups

Live AG state comes from the **SQL Server enabled by Azure Arc availability group API** (`getDetailView`), the same
API the portal *Availability Groups* blade and the patching runbooks use. No T-SQL or SQL login is needed.

## Tools

| Tool | Use |
|------|-----|
| `sqlha_get_availability_groups` (live=true) | Roles, modes, connection/sync health per replica, database sync matrix, failover readiness |
| `sqlha_get_inventory` | Instance build, host, cloud (AWS), Arc status for each replica |
| `sqlha_failover_availability_group` | Planned (no data loss) failover / failback — **write, disruptive** |

## Health rules (identical to the patching runbooks)

A replica is **healthy** when all of these are true:
- data is fresh (collected within 60 s; otherwise it's "stale data")
- role is PRIMARY or SECONDARY, replica is CONNECTED, sync health HEALTHY
- it has local availability databases, none suspended
- synchronous-commit copies are SYNCHRONIZED (async copies may be SYNCHRONIZING)
- on the primary, every replica is connected

A secondary is **failover-ready** only if it is healthy **and** SYNCHRONOUS_COMMIT.
A secondary only reports its own replica and databases. The primary reports all of them.

## Answering status questions

1. Call `sqlha_get_availability_groups`.
2. Lead with: AG name, healthy/unhealthy, current primary, preferred primary (from the maintenance configuration
   tag `SqlAgPreferredPrimary`), and whether it is running on the preferred primary.
3. Replica table: Replica | Role | Commit mode | Failover mode | Connected | Sync health | Failover-ready.
4. Database table only if something is not SYNCHRONIZED/HEALTHY, or the user asks: Database | Replica | Sync state | Health | Suspended.
5. If `errors` is present for a node, say the live query failed (node offline, Arc SQL extension disconnected,
   or missing RBAC) and that the AG may still be serving from the other replica.

## Planned failover / failback (write)

Only do this when the user asks for it.

1. Call `sqlha_failover_availability_group(target_instance=<new primary>, confirm=false)`.
   - If the result says it is already primary, stop.
   - If it's not failover-ready, explain the `message` and stop. Never force it.
2. Show the user what will happen: "AG `<ag>` will move from `<current primary>` to `<target>`. Connections through
   the listener drop for ~10-30 s. No data loss (synchronous commit, synchronized)." Then ask for explicit approval.
3. On approval call again with `confirm=true`. The Arc API often returns HTTP 400 *"Failover retrieve null
   resource"* even on success. The tool handles that and verifies the new primary with `getDetailView`.
4. Report the result and re-run `sqlha_get_availability_groups` to show the final state.

Don't fail over during an in-progress maintenance window for the target node, or when the target has a reboot pending.

## Fallback query (Resource Graph inventory, refreshed by the Arc extension)

```kusto
resources
| where type =~ 'microsoft.azurearcdata/sqlserverinstances/availabilitygroups'
| project instance = tostring(properties.serverName), ag = name,
          primary = tostring(properties.info.primaryReplica),
          health = tostring(properties.info.synchronizationHealthDescription),
          collected = todatetime(properties.collectionTimestamp)
```
Run it with `sqlha_query_resource_graph` if the live API is unavailable, and say the data may be minutes old.
