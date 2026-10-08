---
name: sql-ha-metadata
description: Inventory and metadata for Arc-enabled SQL Server instances and their AWS-hosted machines - versions, editions, builds, licensing, vCores, OS, Arc agent version, cloud, tags, databases (size, recovery model, TDE, backups), other SQL services (SSIS/SSAS), and ad-hoc Azure Resource Graph questions. Use for "what version is SQL-VM-1", "list databases", "what license type", "which Arc agent version", "how big is CoupaExpenses", or any metadata question not covered by other skills.
---

# Inventory and metadata

## Tools

| Tool | Use |
|------|-----|
| `sqlha_get_inventory` | Instances + hosts (version, edition, build, license, vCores, status, cloud, OS, Arc agent, tags, AG membership), other SQL services |
| `sqlha_get_databases(instance?)` | Databases per instance: state, recovery model, compat level, size, free space, TDE, last backups |
| `sqlha_query_resource_graph(query)` | Anything else, as read-only KQL over Resource Graph |

## Answering

- Use exact values from the tools (build `16.0.4255.1`, not "CU-something"). Say "not reported" for nulls.
- Cloud: `host.cloud` comes from Arc cloud metadata, or from the `EmulatedCloud`/`Cloud` tag when Arc reports `N/A`.
- For capacity/licensing questions, sum `vcores` per license type and mention `license_type` (Paid, PAYG, LicenseOnly, HADR).
- For AG databases, the primary copy is authoritative. The secondary copies mirror it.
- Backup times come from the Arc SQL inventory; if missing, say backups aren't reported to Azure (not that they don't exist).

## Resource Graph cookbook (`sqlha_query_resource_graph`)

```kusto
// Arc SQL instances with build and host
resources
| where type =~ 'microsoft.azurearcdata/sqlserverinstances'
| project name, version = tostring(properties.version), edition = tostring(properties.edition),
          build = tostring(properties.patchLevel), license = tostring(properties.licenseType),
          status = tostring(properties.status), host = tostring(split(properties.containerResourceId, '/')[8])

// Arc machines and agent versions
resources
| where type =~ 'microsoft.hybridcompute/machines'
| project name, status = tostring(properties.status), os = tostring(properties.osSku),
          agent = tostring(properties.agentVersion), lastSeen = todatetime(properties.lastStatusChange), tags

// Arc extensions on the SQL hosts
resources
| where type =~ 'microsoft.hybridcompute/machines/extensions'
| project machine = tostring(split(id, '/')[8]), name, version = tostring(properties.typeHandlerVersion),
          state = tostring(properties.provisioningState)
```

Keep queries read-only and narrow (project only the columns you need). Results are capped at 200 rows.
Note: `filter` is a reserved word in KQL; use `properties['filter']`.
