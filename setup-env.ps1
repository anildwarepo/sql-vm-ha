<#
.SYNOPSIS
    Initialize azd environment with required variables for SQL HA deployment.

.PARAMETER EnvironmentName
    Name of the azd environment to create/configure.

.EXAMPLE
    .\setup-env.ps1 -EnvironmentName dev
    azd up
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$EnvironmentName,

    [string]$SubscriptionId = 'e4718866-4e88-411f-a0b8-10c8051dc165',

    [string]$Location = 'westus',

    [string]$ExistingVnetName = 'vnet-westus',

    [string]$ExistingVnetResourceGroupName = 'vnet'
)

$ErrorActionPreference = 'Stop'

# Check azd is installed
if (-not (Get-Command azd -ErrorAction SilentlyContinue)) {
    Write-Error 'Azure Developer CLI (azd) is not installed. Install from https://aka.ms/azd'
    return
}

Write-Host "==> Initializing azd environment '$EnvironmentName'..." -ForegroundColor Cyan
$ErrorActionPreference = 'Continue'
azd env new $EnvironmentName 2>$null
$ErrorActionPreference = 'Stop'

# Non-secret defaults
$ErrorActionPreference = 'Continue'
azd env set AZURE_ADMIN_USERNAME 'azureadmin' -e $EnvironmentName
azd env set AZURE_DOMAIN_FQDN 'contoso.local' -e $EnvironmentName
azd env set AZURE_DOMAIN_NETBIOS 'CONTOSO' -e $EnvironmentName
azd env set AZURE_SQL_SERVICE_ACCOUNT 'sqlservice@contoso.local' -e $EnvironmentName
azd env set AZURE_SQL_ADMIN_LOGIN 'sqladmin' -e $EnvironmentName
azd env set AZURE_CLUSTER_OPERATOR_ACCOUNT 'clusteradmin@contoso.local' -e $EnvironmentName
azd env set AZURE_CLUSTER_BOOTSTRAP_ACCOUNT 'clusteradmin@contoso.local' -e $EnvironmentName
azd env set AZURE_SQL_IMAGE_OFFER 'sql2022-ws2022' -e $EnvironmentName
azd env set AZURE_SQL_IMAGE_SKU 'Enterprise' -e $EnvironmentName
azd env set AZURE_SUBSCRIPTION_ID $SubscriptionId -e $EnvironmentName
azd env set AZURE_LOCATION $Location -e $EnvironmentName
azd env set AZURE_EXISTING_VNET_NAME $ExistingVnetName -e $EnvironmentName
azd env set AZURE_EXISTING_VNET_RESOURCE_GROUP $ExistingVnetResourceGroupName -e $EnvironmentName
azd env set AZURE_VPN_CLIENT_ADDRESS_PREFIX '10.255.0.0/27' -e $EnvironmentName
azd env set AZURE_DC_SUBNET_PREFIX '10.0.9.0/24' -e $EnvironmentName
azd env set AZURE_SQL1_SUBNET_PREFIX '10.0.10.0/24' -e $EnvironmentName
azd env set AZURE_SQL2_SUBNET_PREFIX '10.0.11.0/24' -e $EnvironmentName
azd env set AZURE_DC_PRIVATE_IP '10.0.9.4' -e $EnvironmentName
azd env set AZURE_SQL1_PRIVATE_IP '10.0.10.4' -e $EnvironmentName
azd env set AZURE_SQL2_PRIVATE_IP '10.0.11.4' -e $EnvironmentName
azd env set AZURE_CLUSTER_IP1 '10.0.10.10' -e $EnvironmentName
azd env set AZURE_CLUSTER_IP2 '10.0.11.10' -e $EnvironmentName
azd env set AZURE_LISTENER_IP1 '10.0.10.11' -e $EnvironmentName
azd env set AZURE_LISTENER_IP2 '10.0.11.11' -e $EnvironmentName
$ErrorActionPreference = 'Stop'

# Collect secrets
Write-Host "`n==> Enter passwords (will be stored in azd environment):" -ForegroundColor Yellow

$adminPass = Read-Host -Prompt 'VM Admin password' -AsSecureString
$adminPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($adminPass))
$ErrorActionPreference = 'Continue'
azd env set AZURE_ADMIN_PASSWORD $adminPlain -e $EnvironmentName
$ErrorActionPreference = 'Stop'

$sqlSvcPass = Read-Host -Prompt 'SQL Service account password' -AsSecureString
$sqlSvcPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sqlSvcPass))
$ErrorActionPreference = 'Continue'
azd env set AZURE_SQL_SERVICE_PASSWORD $sqlSvcPlain -e $EnvironmentName

$sqlAdminPass = Read-Host -Prompt 'SQL authentication admin password' -AsSecureString
$sqlAdminPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sqlAdminPass))
azd env set AZURE_SQL_ADMIN_PASSWORD $sqlAdminPlain -e $EnvironmentName

$clusterOpPass = Read-Host -Prompt 'Cluster operator password' -AsSecureString
$clusterOpPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($clusterOpPass))
azd env set AZURE_CLUSTER_OPERATOR_PASSWORD $clusterOpPlain -e $EnvironmentName
azd env set AZURE_CLUSTER_BOOTSTRAP_PASSWORD $clusterOpPlain -e $EnvironmentName
$ErrorActionPreference = 'Stop'

Write-Host "`n==> Environment '$EnvironmentName' configured. Deploy with:" -ForegroundColor Green
Write-Host "    azd up -e $EnvironmentName" -ForegroundColor White
