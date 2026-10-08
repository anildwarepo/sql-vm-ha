# SQL Server Always On Availability Group

Deploy a SQL Server 2022 Always On Availability Group into dedicated subnets in the existing `vnet-westus` virtual network. The deployment uses private networking only and is intended to be reached through the VNet's point-to-site VPN.

## Architecture

- Existing VNet: `vnet-westus` in resource group `vnet`
- VPN client pool: `10.255.0.0/27`
- DC subnet: `sql-ha-dc` (`10.0.9.0/24`)
- SQL subnet 1: `sql-ha-sql-1` (`10.0.10.0/24`)
- SQL subnet 2: `sql-ha-sql-2` (`10.0.11.0/24`)
- One DC for the AZD deployment; two DCs for the direct Bicep deployment
- Two SQL Server 2022 VMs in an availability set
- Multi-subnet WSFC and SQL availability group
- Private AG listener: `ag-listener` on TCP 14333
- File-share witness hosted by the DC
- No public IP or jumpbox

West US does not expose availability zones for the selected Dsv6 VM sizes. The SQL replicas therefore use an availability set rather than zone placement.

## Shared VNet Safety

The templates reference `vnet-westus` as an existing resource and create only three child subnets and their NSGs. They do not submit a replacement VNet definition and do not modify:

- existing address spaces or subnets;
- the VPN gateway or `GatewaySubnet`;
- peerings, route tables, or delegated subnets;
- VNet-wide DNS servers.

SQL VM NICs use the deployment's DC directly for DNS, avoiding a DNS change for unrelated workloads in the shared VNet.

## Prerequisites

| Tool | Install |
|------|---------|
| [Azure CLI](https://aka.ms/installazurecli) | `winget install Microsoft.AzureCLI` |
| [Azure Developer CLI](https://aka.ms/azd) | `winget install Microsoft.Azd` |
| [Bicep CLI](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install) | Bundled with Azure CLI |
| PowerShell 7+ | `winget install Microsoft.PowerShell` |

The deploying identity needs permission to create resources in the deployment resource group and subnets/NSGs in the existing VNet resource group.

## Option A: Azure Developer CLI

### 1. Configure the environment

```powershell
.\setup-env.ps1 -EnvironmentName dev
```

The defaults target:

- Subscription: `e4718866-4e88-411f-a0b8-10c8051dc165`
- Region: `westus`
- VNet: `vnet-westus`
- VNet resource group: `vnet`

The script prompts for the VM administrator and AD service-account passwords.

### 2. Preview and deploy

```powershell
azd provision --preview -e dev
azd up -e dev
```

The `preprovision` hook checks VNet location, address-space containment, subnet overlap, and static-IP validity. Phase 1 creates the three subnets and DC. The `postprovision` hook deploys the SQL VMs and configures WSFC, the AG, and the listener.

## Option B: Direct Bicep

Set the required secrets:

```powershell
$env:ADMIN_PASSWORD = 'YourAdminP@ss!'
$env:SQL_SERVICE_PASSWORD = 'YourSqlSvcP@ss!'
$env:CLUSTER_OPERATOR_PASSWORD = 'YourClusterP@ss!'
```

Review `main.bicepparam`, then deploy:

```powershell
.\deploy.ps1 -ResourceGroupName rg-sql-ha -Location westus
```

## VPN DNS and SQL Connection

The VPN client must resolve `contoso.local` through the DC at `10.0.9.4`. For a development workstation, add an NRPT rule after connecting the VPN:

```powershell
Add-DnsClientNrptRule -Namespace '.contoso.local' -NameServers '10.0.9.4'
```

Verify name resolution and listener connectivity:

```powershell
Resolve-DnsName ag-listener.contoso.local
Test-NetConnection ag-listener.contoso.local -Port 14333
```

Connect from SSMS with:

| Setting | Value |
|---------|-------|
| Server | `ag-listener.contoso.local,14333` |
| Authentication | SQL Server Authentication |
| Login | Value of `AZURE_SQL_ADMIN_LOGIN` |
| Password | Value of `AZURE_SQL_ADMIN_PASSWORD` |
| Additional parameter | `MultiSubnetFailover=True` |

For this development deployment, `TrustServerCertificate=True` may also be required until a trusted SQL certificate is installed.

If the client cannot use the `contoso.local` DNS zone, connect to the currently active listener IP, such as `10.0.10.11,14333`. The DNS listener name is preferred because it continues to work after failover.

To remove the NRPT rule later:

```powershell
Get-DnsClientNrptRule | Where-Object Namespace -eq '.contoso.local' | Remove-DnsClientNrptRule -Force
```

## Add a Database to the AG

Run `ag_configure.ps1` from `SQL-VM-1`, or from a VPN-connected management host with WinRM access:

```powershell
.\ag_configure.ps1
```

The script opens the required SQL and HADR ports, creates `SampleDB`, restores it on the secondary, and adds it to the AG.

## Coupa Demo Sample Data

`scripts/sample-data/` creates three procure-to-pay demo databases and adds them to the AG with automatic seeding. Run it from a VPN-connected workstation; it uses SQL authentication with the azd admin login.

```powershell
.\scripts\sample-data\New-CoupaDemoDatabases.ps1            # create (idempotent)
.\scripts\sample-data\New-CoupaDemoDatabases.ps1 -Recreate  # drop everywhere and rebuild
```

| Database | Tables | Views |
|----------|--------|-------|
| `CoupaProcurement` | CostCenters, Employees, Commodities, Suppliers, Contracts, CatalogItems, Requisitions, RequisitionLines, Approvals, PurchaseOrders, PurchaseOrderLines | `vw_SpendByCommodity`, `vw_SupplierSpend`, `vw_BudgetVsSpend` |
| `CoupaInvoicing` | Invoices (3-way match, price/quantity variance), InvoiceLines, Payments | `vw_InvoiceAging` |
| `CoupaExpenses` | ExpenseCategories, ExpenseReports, ExpenseLines | `vw_ExpenseSummary` |

The data is deterministic and covers the 12 months before the load date. `CoupaDemo.sql` can also be run on its own in SSMS against a standalone instance.

### Generate demo load

`Start-CoupaDemoLoad.ps1` runs a pool of worker threads that continuously run a weighted mix of procure-to-pay reads, inserts, updates and deletes until you press Ctrl+C. It prints throughput, errors and the current primary every 10 seconds.

```powershell
.\scripts\sample-data\Start-CoupaDemoLoad.ps1                                   # 8 workers, until Ctrl+C
.\scripts\sample-data\Start-CoupaDemoLoad.ps1 -Workers 16 -ThinkTimeMs 0        # heavier load
.\scripts\sample-data\Start-CoupaDemoLoad.ps1 -Cleanup                          # remove all load-generated rows
```

- Writes go through the listener. By default half of the reads go straight to the readable secondary (`-ReadFromSecondaryPercent`).
- Workers reconnect after errors, so the load keeps running through an AG failover.
- The generator only updates or deletes rows it created itself (prefixes `LGR-`, `LGP-`, `LGI-`, `LGE-`), so the seed data is never changed. Rows older than `-RetentionMinutes` (30 by default) are purged continuously.

## Evaluate SQL Server enabled by Azure Arc (emulated non-Azure VMs)

> **Evaluation/testing only.** Azure Arc does not support Azure VMs in production. These scripts use the documented workaround ([Evaluate Arc-enabled servers on an Azure VM](https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine)) to make the SQL VMs behave like servers running outside Azure, for example in AWS.

```powershell
az login
.\scripts\arc\Enable-SqlArcEvaluation.ps1            # SQL-VM-1 and SQL-VM-2 -> <rg>-arc
.\scripts\arc\Disable-SqlArcEvaluation.ps1           # revert
```

`Enable-SqlArcEvaluation.ps1` does the following for each SQL VM:

1. Registers the Arc resource providers and creates the Arc resource group. The default is `<AZURE_RESOURCE_GROUP>-arc`.
2. Removes the SQL IaaS Agent registration, then all VM extensions and managed Run Commands. It also deletes any SQL Server instance resources whose host type is "Azure Virtual Machine", which the IaaS agent leaves behind.
3. Uses Azure Run Command one last time to start `Install-ArcAgentOnVm.ps1` as a SYSTEM scheduled task. That script:
   - sets `MSFT_ARC_TEST=true`
   - installs the Connected Machine agent
   - blocks IMDS
   - disables `WindowsAzureGuestAgent`
   - runs `azcmagent connect` with a short-lived ARM token for your `az` login
4. Installs the `WindowsAgent.SqlServer` extension with `-LicenseType Paid` by default. The Arc machines are tagged `ArcSQLServerExtensionDeployment=Disabled`, so automatic onboarding does not race it. Use `-AutomaticSqlOnboarding` to let Arc install the extension instead.

The script uses `Paid` (Software Assurance) because the marketplace SQL image is already billed PAYG. Choosing `-LicenseType PAYG` would add Arc SQL license charges on top of that.

While a VM is Arc-enabled, the following stop working on it:

- Azure VM extensions and Azure VM Run Command
- SQL IaaS Agent features and Defender for SQL on Azure VMs
- the `azd provision` hooks

The AG, WSFC, listener and SQL logins keep working. On-VM logs are in `C:\ArcEval\*.log`. If a VM cannot be reached via Arc, RDP to it and run `scripts\arc\Remove-ArcAgentOnVm.ps1`.

### AG-aware patching with Azure Update Manager

`scripts/patching/` patches the Arc-enabled nodes one at a time and keeps the AG online. Windows updates and SQL Server CUs are both included. See [scripts/patching/README.md](scripts/patching/README.md) for how it works. Run it after `Enable-SqlArcEvaluation.ps1`. You need Owner or User Access Administrator on the resource groups, because the script creates role assignments.

```powershell
.\scripts\patching\Enable-SqlAgPatching.ps1          # default: every Saturday, SQL-VM-2 01:00-03:00, SQL-VM-1 04:30-06:30 PT
.\scripts\patching\Enable-SqlAgPatching.ps1 -RecurEvery 'Month Second Saturday' -StartTime '00:00'
.\scripts\patching\Disable-SqlAgPatching.ps1         # remove it (-RemoveWindowsUpdatePolicy also reverts the node settings)
```

The script creates the following in the Arc resource group:

| Resource | Purpose |
|----------|---------|
| `mc-sqlag-<node>` (or `-ConfigNames`) | One maintenance configuration per node ("wave"), staggered by `WindowDuration + GapMinutes`. Tags (`SqlAgTarget`, `SqlAgPartner`, `SqlAgName`, ...) tell the runbooks which node is patched. This environment uses `sql-update-wave1` (SQL-VM-1) and `sql-update-wave2` (SQL-VM-2) |
| `aa-sql-ag-patching` | Automation account with a system-assigned identity. The identity gets *Contributor* on each Arc SQL instance (for the AG API) and on each configuration (to cancel a run) |
| `Pre-SqlAgFailover` runbook | Started by the pre-maintenance event, 30-40 min before a wave. If the node to be patched is the primary, it does a planned failover to the synchronized secondary. If that is unsafe (partner offline or not synchronized, or the failover fails), it **cancels the run** |
| `Post-SqlAgValidate` runbook | Started by the post-maintenance event. Waits until the Arc SQL extension reports the replica connected and synchronized after the reboot, then logs the SQL build. If the patched node is `-PreferredPrimary` (default `SQL-VM-1`), it fails the AG back. The job fails if the node is unhealthy, and the next wave's pre-runbook then cancels that wave |
| `st-<configuration>` system topics | One Event Grid system topic per configuration, with pre and post event subscriptions that call the runbook webhooks |

The script also sets up the nodes:

- It registers the nodes with Microsoft Update, so SQL Server CUs are offered, and sets Windows Update to notify only (`AUOptions=2`). Windows then never installs updates or reboots outside the windows. Use `-SkipWindowsUpdatePolicy` to skip this.
- It removes other Update Manager schedules assigned to the nodes, such as `autoupdate-config` from *SQL Server - Azure Arc > Updates*, because they patch both nodes at once. Also turn off automatic updates in that blade. Use `-KeepOtherAssignments` to keep the other schedules.

The runbooks call only ARM: the SQL Server enabled by Azure Arc availability group API (`getDetailView` for live AG state, `failover` for a planned failover). No Run Command, T-SQL or SQL login is needed. Check job output under *Automation account > Jobs* and patch results under *Azure Update Manager > History*.

### SQL Control Plane (monitoring, patching, dashboard and API)

`sql-controlplane/` and `.github/` add an operations layer on top of Arc, Update Manager and the AG-aware waves.
It answers questions about patch status, outstanding updates, maintenance windows, security risks, Always On health,
performance and metadata, and it can patch and fail over safely. One shared Python core (`sqlha`) powers:
- a React dashboard with drill-down, node actions and a chat panel;
- a FastAPI backend with Swagger (`python sql-controlplane/run_all.py` starts both);
- a VS Code custom agent (`sql-ha-agent`, backed by the local `sqlha` MCP server);
- a Microsoft Foundry hosted agent.

See [sql-controlplane/README.md](sql-controlplane/README.md).

> Webhooks expire after `-WebhookExpiryDays` (default 365). Rerun the script with `-RotateWebhooks` before then. If a pre-event cannot start its runbook, Update Manager still patches that node without a failover.

## Key Network Parameters

| Parameter | Default |
|-----------|---------|
| `existingVnetName` | `vnet-westus` |
| `existingVnetResourceGroupName` | `vnet` |
| `vpnClientAddressPrefix` | `10.255.0.0/27` |
| `dcSubnetPrefix` | `10.0.9.0/24` |
| `sql1SubnetPrefix` | `10.0.10.0/24` |
| `sql2SubnetPrefix` | `10.0.11.0/24` |

## Project Structure

```text
├── main.bicep
├── main.bicepparam
├── deploy.ps1
├── setup-env.ps1
├── azure.yaml
├── ag_configure.ps1
├── hooks/
│   ├── preprovision.ps1
│   └── postprovision.ps1
├── scripts/
│   ├── arc/            # Azure Arc SQL evaluation (emulated non-Azure VMs)
│   ├── patching/       # AG-aware patching: Update Manager schedules + pre/post runbooks
│   │   └── runbooks/
│   └── sample-data/    # Coupa procure-to-pay demo databases
├── sql-controlplane/   # SQL Control Plane: React UI + FastAPI/Swagger + shared sqlha core, MCP server, Foundry hosted agent
├── .github/
│   ├── agents/         # VS Code custom agent: sql-ha-agent
│   └── skills/         # sql-ha-* skills (overview, Always On, patching, maintenance, security, performance, metadata, dashboard)
├── .vscode/            # mcp.json (sqlha MCP server), F5 hosted-agent debug, "Run SQL control plane" tasks
├── infra/
│   ├── main.bicep
│   ├── main.parameters.json
│   ├── phase2-sql.bicep
│   └── modules/
└── modules/
```
