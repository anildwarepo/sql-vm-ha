---
name: sql-ha-security-risk
description: Security risk posture of Arc-enabled SQL Server hosts and instances - Microsoft Defender for Cloud recommendations (SQL vulnerability assessment, host hardening), active Defender alerts, missing security and critical patches (MSRC severity), Defender for SQL protection, TLS/TDE/endpoint encryption, and a prioritized remediation plan. Use for "what are the security risks", "are we exposed", "show high severity findings", "is Defender for SQL on", "which databases aren't encrypted".
---

# Security risk

## Tools

| Tool | Use |
|------|-----|
| `sqlha_get_security_posture(severity?, machine?)` | Defender recommendations, active alerts, missing security patches, instance controls, TDE gaps |
| `sqlha_get_patch_compliance` | Detail on missing security updates (MSRC severity, age) |
| `sqlha_get_inventory` | Defender for SQL status, license, Arc agent version, host OS |

## Procedure

1. Call `sqlha_get_security_posture()`. For large estates, call again with `severity="High"` or `machine=…` to stay focused.
2. Lead with exposure, in this priority:
   1. **Active Defender alerts** (possible active threat). Show every one: time, severity, alert, entity.
   2. **Missing security/critical updates**, especially MSRC *Critical*. Include KB, host, age in days, and whether it's a SQL Server update.
   3. **High-severity Defender recommendations**, grouped by recommendation title with affected hosts/objects.
   4. Medium/low recommendations as counts by theme (auth, permissions, auditing, encryption, OS hardening).
3. Instance controls: Defender for SQL `Protected` on every instance, AG mirroring endpoint encryption
   (AES expected), Arc agent version consistent across nodes.
4. Prioritized remediation plan (max 7 items) as a table: Priority | Risk | Affected | Fix | Effort/Impact.
   - Patch-based fixes go through the AG-safe flow (`sql-ha-patch-orchestration`) or the next wave. Never suggest patching both nodes together.
   - SQL configuration fixes (logins, permissions, auditing, TLS, TDE) are T-SQL or OS changes. Apply them on the
     **primary** for database-level settings, and on **both** replicas for instance-level settings. TDE on AG
     databases needs the certificate on every replica first.

## Interpreting common SQL VA recommendations

| Recommendation | Meaning / typical fix |
|----------------|-----------------------|
| Database communication using TDS should be protected through TLS | Force encryption / TLS 1.2+ certificate on each instance |
| Minimal set of principals in fixed server/database roles | Remove unneeded sysadmin/db_owner members |
| Authentication mode should be Windows Authentication | Disable mixed mode if no SQL logins are required |
| Transparent data encryption should be enabled | Enable TDE (certificate on all AG replicas first) |
| Account with default name 'sa' should be renamed and disabled | Rename + disable `sa` |
| Machines should be configured to periodically check for missing system updates | `sqlha_enable_periodic_assessment` |

## Rules

- Report Defender data as-is and mention it refreshes about every 12-24h, so recently fixed items may still appear.
- If `defender_findings` is empty and `errors` mentions authorization, the identity lacks *Security Reader*.
- Don't print secrets, connection strings or full resource IDs unless asked.
