# SQL Server AlwaysOn Availability Group — HA Deployment

Deploy a SQL Server AlwaysOn Availability Group across two availability zones on Azure, including a VNet, domain controllers, a Windows Server Failover Cluster (WSFC), cloud witness, AG listener, and an optional jumpbox.

## Architecture

- **VNet** with dedicated subnets for DCs, SQL nodes, and jumpbox
- **2 Domain Controller VMs** (Active Directory forest — `contoso.local`)
- **2 SQL Server 2022 VMs** in separate availability zones with multi-subnet AG
- **Cloud Witness** storage account for WSFC quorum
- **AG Listener** with multi-subnet IPs

## Prerequisites

| Tool | Install |
|------|---------|
| [Azure CLI](https://aka.ms/installazurecli) | `winget install Microsoft.AzureCLI` |
| [Azure Developer CLI (azd)](https://aka.ms/azd) | `winget install Microsoft.Azd` |
| [Bicep CLI](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install) | Bundled with Azure CLI |
| PowerShell 7+ | `winget install Microsoft.PowerShell` |

You also need an Azure subscription with permissions to create resources (Contributor or Owner role).

## Deployment Options

### Option A — Azure Developer CLI (`azd`)

This is a two-phase deployment. Phase 1 provisions the network, domain controllers, and cloud witness. A `postprovision` hook then waits for Active Directory to become ready and deploys Phase 2 (jumpbox + SQL VMs + WSFC + AG).

#### 1. Initialise the environment

```powershell
.\setup-env.ps1 -EnvironmentName dev
```

You will be prompted for:
- **VM admin password**
- **SQL service account password**
- **Cluster operator password**

The script stores these values (plus sensible defaults for domain, accounts, and SQL image) in the azd environment.

#### 2. Deploy

```powershell
azd up -e dev
```

`azd up` will:
1. Provision Phase 1 (network, DC, cloud witness) via `infra/main.bicep`.
2. Run the `postprovision` hook (`hooks/postprovision.ps1`), which waits for Active Directory on DC-VM-1, then deploys Phase 2 (`infra/phase2-sql.bicep`) with the jumpbox and SQL VMs.

#### 3. Tear down

```powershell
azd down -e dev --purge --force
```

---

### Option B — Direct Bicep deployment (`deploy.ps1`)

Use this if you prefer a single-phase deployment without azd (deploys everything in `main.bicep` at the root).

#### 1. Set passwords as environment variables (optional)

```powershell
$env:ADMIN_PASSWORD         = 'YourAdminP@ss!'
$env:SQL_SERVICE_PASSWORD   = 'YourSqlSvcP@ss!'
$env:CLUSTER_OPERATOR_PASSWORD = 'YourClusterP@ss!'
```

If not set, the script will prompt for each password interactively.

#### 2. Deploy

```powershell
.\deploy.ps1 -ResourceGroupName rg-sql-ha -Location eastus2
```

This creates the resource group (if it doesn't exist) and runs a single `az deployment group create` using `main.bicep` / `main.bicepparam`.

---

## Post-Deployment: Add a Database to the AG

After the infrastructure is deployed, run `ag_configure.ps1` **from SQL-VM-1** (or a jumpbox with WinRM access to both SQL VMs) to:

1. Open Windows Firewall ports (1433, 5022) on both SQL VMs.
2. Create a sample database (`SampleDB`) on the primary.
3. Back up and restore the database to the secondary with `NORECOVERY`.
4. Add the database to the AG on both replicas.

```powershell
.\ag_configure.ps1
```

## Key Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `adminUsername` | `azureadmin` | Local/domain admin user for all VMs |
| `domainFqdn` | `contoso.local` | AD domain FQDN |
| `domainNetBiosName` | `CONTOSO` | AD NetBIOS name |
| `sqlImageOffer` | `sql2022-ws2022` | SQL Server marketplace image |
| `sqlImageSku` | `Enterprise` | SQL edition (`Enterprise`, `Developer`, `Standard`) |

## Project Structure

```
├── main.bicep              # Single-phase Bicep template (Option B)
├── main.bicepparam         # Parameters file for Option B
├── deploy.ps1              # Deployment script for Option B
├── setup-env.ps1           # azd environment setup (Option A)
├── azure.yaml              # azd project definition
├── ag_configure.ps1        # Post-deploy AG database configuration
├── hooks/
│   └── postprovision.ps1   # Phase 2 deployment hook (Option A)
├── infra/                  # azd Bicep templates (Option A)
│   ├── main.bicep          # Phase 1: network, DC, cloud witness
│   ├── main.parameters.json
│   ├── phase2-sql.bicep    # Phase 2: jumpbox, SQL VMs, WSFC, AG
│   └── modules/
├── modules/                # Shared Bicep modules (Option B)
│   ├── domain-controller.bicep
│   ├── network.bicep
│   ├── sql-vm.bicep
│   └── vnet-dns-update.bicep
```