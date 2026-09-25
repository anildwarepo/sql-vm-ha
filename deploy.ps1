<#
.SYNOPSIS
    Deploys the SQL Server AlwaysOn Availability Group HA infrastructure.

.DESCRIPTION
    Creates a resource group (if needed) and deploys two DC VMs and two SQL
    VMs into dedicated subnets in an existing VNet, plus the WSFC cluster
    and AG listener.

.PARAMETER ResourceGroupName
    Name of the resource group to deploy into.

.PARAMETER Location
    Azure region for the deployment.

.EXAMPLE
    .\deploy.ps1 -ResourceGroupName rg-sql-ha -Location westus
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [string]$Location = 'westus'
)

$ErrorActionPreference = 'Stop'

# ─── Collect secure inputs ───

if (-not $env:ADMIN_PASSWORD) {
    $adminCred = Get-Credential -UserName 'azureadmin' -Message 'Enter VM admin password'
    $env:ADMIN_PASSWORD = $adminCred.GetNetworkCredential().Password
}

if (-not $env:SQL_SERVICE_PASSWORD) {
    $sqlCred = Get-Credential -UserName 'sqlservice' -Message 'Enter SQL service account password'
    $env:SQL_SERVICE_PASSWORD = $sqlCred.GetNetworkCredential().Password
}

if (-not $env:CLUSTER_OPERATOR_PASSWORD) {
    $clusterOpCred = Get-Credential -UserName 'clusteradmin' -Message 'Enter cluster operator account password'
    $env:CLUSTER_OPERATOR_PASSWORD = $clusterOpCred.GetNetworkCredential().Password
}

if (-not $env:CLUSTER_BOOTSTRAP_PASSWORD) {
    $env:CLUSTER_BOOTSTRAP_PASSWORD = $env:CLUSTER_OPERATOR_PASSWORD
}

# ─── Verify Azure CLI ───

Write-Host '==> Checking Azure CLI...' -ForegroundColor Cyan
$azVersion = az version --output tsv 2>$null
if (-not $azVersion) {
    Write-Error 'Azure CLI is not installed. Install from https://aka.ms/installazurecli'
    return
}

# ─── Ensure logged in ───

$account = az account show --output json 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host '==> Not logged in. Running az login...' -ForegroundColor Yellow
    az login
    $account = az account show --output json 2>$null | ConvertFrom-Json
}

Write-Host "==> Subscription: $($account.name) ($($account.id))" -ForegroundColor Green

# ─── Create resource group ───

Write-Host "==> Ensuring resource group '$ResourceGroupName' in '$Location'..." -ForegroundColor Cyan
az group create --name $ResourceGroupName --location $Location --output none

# ─── Validate existing VNet configuration ───

Write-Host '==> Validating existing VNet and dedicated subnet ranges...' -ForegroundColor Cyan
$preflightScript = Join-Path $PSScriptRoot 'hooks\preprovision.ps1'
& $preflightScript `
    -VnetName 'vnet-westus' `
    -VnetResourceGroupName 'vnet' `
    -Location $Location `
    -DcSubnetPrefix '10.0.9.0/24' `
    -Sql1SubnetPrefix '10.0.10.0/24' `
    -Sql2SubnetPrefix '10.0.11.0/24' `
    -DcPrivateIp '10.0.9.4' `
    -Sql1PrivateIp '10.0.10.4' `
    -Sql2PrivateIp '10.0.11.4' `
    -ClusterIp1 '10.0.10.10' `
    -ClusterIp2 '10.0.11.10' `
    -ListenerIp1 '10.0.10.11' `
    -ListenerIp2 '10.0.11.11'

# ─── Deploy ───

$templateFile = Join-Path $PSScriptRoot 'main.bicep'
$paramsFile   = Join-Path $PSScriptRoot 'main.bicepparam'

Write-Host '==> Starting deployment (this may take 30+ minutes)...' -ForegroundColor Cyan

az deployment group create `
    --resource-group $ResourceGroupName `
    --template-file $templateFile `
    --parameters $paramsFile `
    --name "sql-ha-$(Get-Date -Format 'yyyyMMdd-HHmmss')" `
    --verbose

if ($LASTEXITCODE -ne 0) {
    Write-Error 'Deployment failed. Check the Azure portal for details.'
    return
}

# ─── Show outputs ───

Write-Host "`n==> Deployment succeeded!" -ForegroundColor Green
az deployment group show `
    --resource-group $ResourceGroupName `
    --name (az deployment group list --resource-group $ResourceGroupName --query '[0].name' -o tsv) `
    --query 'properties.outputs' `
    --output table
