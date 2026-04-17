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
    [string]$EnvironmentName
)

$ErrorActionPreference = 'Stop'

# Check azd is installed
if (-not (Get-Command azd -ErrorAction SilentlyContinue)) {
    Write-Error 'Azure Developer CLI (azd) is not installed. Install from https://aka.ms/azd'
    return
}

Write-Host "==> Initializing azd environment '$EnvironmentName'..." -ForegroundColor Cyan
azd env new $EnvironmentName 2>$null

# Non-secret defaults
azd env set AZURE_ADMIN_USERNAME 'azureadmin' -e $EnvironmentName
azd env set AZURE_DOMAIN_FQDN 'contoso.local' -e $EnvironmentName
azd env set AZURE_DOMAIN_NETBIOS 'CONTOSO' -e $EnvironmentName
azd env set AZURE_SQL_SERVICE_ACCOUNT 'sqlservice@contoso.local' -e $EnvironmentName
azd env set AZURE_CLUSTER_OPERATOR_ACCOUNT 'clusteradmin@contoso.local' -e $EnvironmentName
azd env set AZURE_CLUSTER_BOOTSTRAP_ACCOUNT 'clusteradmin@contoso.local' -e $EnvironmentName
azd env set AZURE_SQL_IMAGE_OFFER 'sql2022-ws2022' -e $EnvironmentName
azd env set AZURE_SQL_IMAGE_SKU 'Enterprise' -e $EnvironmentName

# Detect and set the public IP of this machine for NSG allow-listing
Write-Host "`n==> Detecting public IP of this machine..." -ForegroundColor Cyan
$allowedIp = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=text' -UseBasicParsing).Trim()
Write-Host "    Detected IP: $allowedIp" -ForegroundColor White
azd env set AZURE_ALLOWED_SOURCE_IP $allowedIp -e $EnvironmentName

# Collect secrets
Write-Host "`n==> Enter passwords (will be stored in azd environment):" -ForegroundColor Yellow

$adminPass = Read-Host -Prompt 'VM Admin password' -AsSecureString
$adminPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($adminPass))
azd env set AZURE_ADMIN_PASSWORD $adminPlain -e $EnvironmentName

$sqlSvcPass = Read-Host -Prompt 'SQL Service account password' -AsSecureString
$sqlSvcPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sqlSvcPass))
azd env set AZURE_SQL_SERVICE_PASSWORD $sqlSvcPlain -e $EnvironmentName

$clusterOpPass = Read-Host -Prompt 'Cluster operator password' -AsSecureString
$clusterOpPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($clusterOpPass))
azd env set AZURE_CLUSTER_OPERATOR_PASSWORD $clusterOpPlain -e $EnvironmentName
azd env set AZURE_CLUSTER_BOOTSTRAP_PASSWORD $clusterOpPlain -e $EnvironmentName

Write-Host "`n==> Environment '$EnvironmentName' configured. Deploy with:" -ForegroundColor Green
Write-Host "    azd up -e $EnvironmentName" -ForegroundColor White
