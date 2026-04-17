<#
.SYNOPSIS
    Post-provision hook: waits for DCs to be ready, then deploys Phase 2 (Jumpbox + SQL VMs).
#>

$ErrorActionPreference = 'Stop'

# --- Read azd environment ---
$rgName = azd env get-value AZURE_RESOURCE_GROUP
$location = azd env get-value AZURE_LOCATION
$subId = azd env get-value AZURE_SUBSCRIPTION_ID
$envName = azd env get-value AZURE_ENV_NAME

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Phase 2: Jumpbox + SQL VMs Deployment" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# --- Get Phase 1 outputs ---
Write-Host "==> Reading Phase 1 deployment outputs..." -ForegroundColor Cyan

# Find the latest deployment (azd appends a timestamp to the name)
$deploymentName = az deployment group list `
    --resource-group $rgName `
    --query "[?starts_with(name, '$envName')].name | [0]" -o tsv

if (-not $deploymentName) {
    Write-Error "Could not find a deployment starting with '$envName' in resource group '$rgName'."
    exit 1
}
Write-Host "  Found deployment: $deploymentName" -ForegroundColor Gray

$outputs = az deployment group show `
    --resource-group $rgName `
    --name $deploymentName `
    --query 'properties.outputs' `
    --output json | ConvertFrom-Json

$cloudWitnessBlobEndpoint = $outputs.cloudWitnessBlobEndpoint.value
$cloudWitnessName = $outputs.cloudWitnessName.value
$subnetIds = @($outputs.subnetIds.value)

# Get cloud witness key
$cwKey = az storage account keys list --account-name $cloudWitnessName --resource-group $rgName --query '[0].value' -o tsv

Write-Host "  Cloud Witness: $cloudWitnessName" -ForegroundColor Gray
Write-Host "  Subnet count: $($subnetIds.Count)" -ForegroundColor Gray

# --- Wait for DC DNS to be functional ---
Write-Host "`n==> Waiting for Domain Controller to be ready..." -ForegroundColor Yellow

$domain = 'contoso.local'
$maxAttempts = 40
$ready = $false

for ($i = 1; $i -le $maxAttempts; $i++) {
    # First check if VM is running
    $powerState = az vm get-instance-view -g $rgName -n 'DC-VM-1' --query "instanceView.statuses[1].displayStatus" -o tsv 2>$null
    if ($powerState -ne 'VM running') {
        Write-Host "  Attempt $i/$maxAttempts - DC-VM-1 power state: $powerState, waiting 30s..." -ForegroundColor Gray
        Start-Sleep -Seconds 30
        continue
    }

    # VM is running - test if AD DS is operational
    $result = az vm run-command invoke `
        --resource-group $rgName `
        --name 'DC-VM-1' `
        --command-id RunPowerShellScript `
        --scripts "try { Get-ADDomain -Server $domain -ErrorAction Stop | Out-Null; Write-Output 'AD_OK' } catch { Write-Output 'AD_FAIL' }" `
        --query 'value[0].message' -o tsv 2>$null

    if ($result -match 'AD_OK') {
        Write-Host "  AD DS is ready on DC-VM-1! (attempt $i)" -ForegroundColor Green
        $ready = $true
        break
    }

    Write-Host "  Attempt $i/$maxAttempts - AD DS not ready yet, waiting 30s..." -ForegroundColor Gray
    Start-Sleep -Seconds 30
}

if (-not $ready) {
    Write-Error "AD DS did not become ready after $maxAttempts attempts. Check DC-VM-1."
    exit 1
}

# --- Read passwords from azd env ---
$adminPassword = azd env get-value AZURE_ADMIN_PASSWORD
$allowedIp = azd env get-value AZURE_ALLOWED_SOURCE_IP

# --- Deploy Phase 2 ---
Write-Host "`n==> Deploying Phase 2 (Jumpbox + SQL VMs + WSFC + AG)..." -ForegroundColor Cyan

$templateFile = Join-Path $PSScriptRoot '..\infra\phase2-sql.bicep'

# Write parameters to a temp file to avoid PowerShell/Windows quote-mangling of JSON values
$paramsObj = [ordered]@{
    adminUsername            = @{ value = 'azureadmin' }
    adminPassword            = @{ value = $adminPassword }
    domainFqdn               = @{ value = 'contoso.local' }
    domainNetBiosName        = @{ value = 'CONTOSO' }
    allowedSourceIp          = @{ value = $allowedIp }
    cloudWitnessBlobEndpoint = @{ value = $cloudWitnessBlobEndpoint }
    cloudWitnessPrimaryKey   = @{ value = $cwKey }
    subnetIds                = @{ value = $subnetIds }
}
$paramsFile = [System.IO.Path]::ChangeExtension((New-TemporaryFile).FullName, '.json')
$paramsObj | ConvertTo-Json -Depth 5 | Set-Content -Path $paramsFile -Encoding utf8

$deployOutput = az deployment group create `
    --resource-group $rgName `
    --template-file $templateFile `
    --name "${envName}-phase2" `
    --parameters "@$paramsFile" 2>&1

if ($LASTEXITCODE -ne 0) {
    $deployOutput | Out-Host
    Write-Error "Phase 2 deployment failed."
    Remove-Item -Path $paramsFile -Force -ErrorAction SilentlyContinue
    exit 1
}

Remove-Item -Path $paramsFile -Force -ErrorAction SilentlyContinue

# --- Show outputs ---
Write-Host "`n==> Phase 2 deployment succeeded!" -ForegroundColor Green
az deployment group show `
    --resource-group $rgName `
    --name "${envName}-phase2" `
    --query 'properties.outputs' `
    --output table
