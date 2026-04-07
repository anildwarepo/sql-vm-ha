<#
.SYNOPSIS
    Deploys the SQL Server AlwaysOn Availability Group HA infrastructure.

.DESCRIPTION
    Creates a resource group (if needed) and deploys the Bicep template with
    VNet, 2 DC VMs, 2 SQL VMs across availability zones, cloud witness,
    WSFC cluster, and AG listener.

.PARAMETER ResourceGroupName
    Name of the resource group to deploy into.

.PARAMETER Location
    Azure region for the deployment.

.EXAMPLE
    .\deploy.ps1 -ResourceGroupName rg-sql-ha -Location eastus2
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [string]$Location = 'westus2'
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
}

Write-Host "==> Subscription: $($account.name) ($($account.id))" -ForegroundColor Green

# ─── Create resource group ───

Write-Host "==> Ensuring resource group '$ResourceGroupName' in '$Location'..." -ForegroundColor Cyan
az group create --name $ResourceGroupName --location $Location --output none

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
