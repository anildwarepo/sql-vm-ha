<#
.SYNOPSIS
    Post-provision hook: waits for DCs to be ready, then deploys Phase 2 (Jumpbox + SQL VMs).

#>

$ErrorActionPreference = 'Stop'

# --- Read azd environment ---
$rgName = azd env get-value AZURE_RESOURCE_GROUP
$domainFQDN = azd env get-value AZURE_DOMAIN_FQDN
$envName = azd env get-value AZURE_ENV_NAME
$domainNetBiosName = azd env get-value AZURE_DOMAIN_NETBIOS
$allowedIp = azd env get-value AZURE_ALLOWED_SOURCE_IP
$dcVmName = azd env get-value dcVmName

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Phase 2: Jumpbox + SQL VMs Deployment" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# --- Get Phase 1 outputs ---
Write-Host "==> Reading Phase 1 deployment outputs..." -ForegroundColor Cyan

# Find latest Phase 1-style deployment. Exclude prior Phase 2 deployments (e.g. "dev-phase2").
$deploymentName = az deployment group list `
    --resource-group $rgName `
    --query "[?starts_with(name, '$envName') && !contains(name, 'phase2')].name | [0]" -o tsv

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

$cloudWitnessBlobEndpoint = ([string]$outputs.cloudWitnessBlobEndpoint.value).Trim().TrimEnd('/')
$cloudWitnessName = $outputs.cloudWitnessName.value
$dcPrivateIp = $outputs.dcPrivateIp.value
$subnetIds = @($outputs.subnetIds.value)

if ([string]::IsNullOrWhiteSpace($cloudWitnessName) -or [string]::IsNullOrWhiteSpace($cloudWitnessBlobEndpoint) -or [string]::IsNullOrWhiteSpace($dcPrivateIp) -or $subnetIds.Count -lt 4) {
    Write-Error "Phase 1 outputs are missing or incomplete."
    exit 1
}

# Get cloud witness key
$cwKey = (az storage account keys list --account-name $cloudWitnessName --resource-group $rgName --query '[0].value' -o tsv).Trim()

Write-Host "  Cloud Witness: $cloudWitnessName" -ForegroundColor Gray
Write-Host "  Subnet count: $($subnetIds.Count)" -ForegroundColor Gray

# --- Wait for DC DNS to be functional ---
Write-Host "`n==> Waiting for Domain Controller to be ready..." -ForegroundColor Yellow

$maxAttempts = 40
$ready = $false

for ($i = 1; $i -le $maxAttempts; $i++) {
    # First check if VM is running
    $powerState = az vm get-instance-view -g $rgName -n $dcVmName --query "instanceView.statuses[1].displayStatus" -o tsv 2>$null
    if ($powerState -ne 'VM running') {
        Write-Host "  Attempt $i/$maxAttempts - $dcVmName power state: $powerState, waiting 30s..." -ForegroundColor Gray
        Start-Sleep -Seconds 30
        continue
    }

    # VM is running - test if AD DS is operational
    $result = az vm run-command invoke `
        --resource-group $rgName `
        --name $dcVmName `
        --command-id RunPowerShellScript `
        --scripts "try { Get-ADDomain -Server $domain -ErrorAction Stop | Out-Null; Write-Output 'AD_OK' } catch { Write-Output 'AD_FAIL' }" `
        --query 'value[0].message' -o tsv 2>$null

    if ($result -match 'AD_OK') {
        Write-Host "  AD DS is ready on $dcVmName! (attempt $i)" -ForegroundColor Green
        $ready = $true
        break
    }

    Write-Host "  Attempt $i/$maxAttempts - AD DS not ready yet, waiting 30s..." -ForegroundColor Gray
    Start-Sleep -Seconds 30
}

if (-not $ready) {
    Write-Error "AD DS did not become ready after $maxAttempts attempts. Check $dcVmName."
    exit 1
}

# --- Read account credentials from azd env ---
Write-Host "`n==> Reading AD account credentials from azd environment..." -ForegroundColor Cyan

$adminUsername = azd env get-value AZURE_ADMIN_USERNAME
$adminPassword = azd env get-value AZURE_ADMIN_PASSWORD
$sqlServiceAccount = azd env get-value AZURE_SQL_SERVICE_ACCOUNT
$sqlServiceAccountPassword = azd env get-value AZURE_SQL_SERVICE_PASSWORD
$clusterOperatorAccount = azd env get-value AZURE_CLUSTER_OPERATOR_ACCOUNT
$clusterOperatorAccountPassword = azd env get-value AZURE_CLUSTER_OPERATOR_PASSWORD
$clusterBootstrapAccount = azd env get-value AZURE_CLUSTER_BOOTSTRAP_ACCOUNT
$clusterBootstrapAccountPassword = azd env get-value AZURE_CLUSTER_BOOTSTRAP_PASSWORD

if ([string]::IsNullOrWhiteSpace($sqlServiceAccount) -or [string]::IsNullOrWhiteSpace($sqlServiceAccountPassword)) {
    Write-Error "Required account credentials missing from azd env. Re-run setup-env.ps1."
    exit 1
}

Write-Host "  ✓ All credentials available" -ForegroundColor Green

# --- Create AD service accounts on DC using az vm run-command create (supports long timeout + protected params) ---
Write-Host "`n==> Provisioning AD service accounts on $dcVmName..." -ForegroundColor Cyan

# Write the script to a local temp file to avoid shell quoting issues
$adScriptFile = [System.IO.Path]::ChangeExtension((New-TemporaryFile).FullName, '.ps1')
@'
param(
    [string]$SQL_SAM,
    [string]$SQL_UPN,
    [string]$CL_SAM,
    [string]$CL_UPN,
    [string]$SQL_PASSWORD,
    [string]$CL_PASSWORD
)
$retry = 0
while ($retry -lt 20) {
    try { Import-Module ActiveDirectory -ErrorAction Stop; Get-ADDomain | Out-Null; break }
    catch { Start-Sleep 30; $retry++ }
}
$sqlPwd = ConvertTo-SecureString $SQL_PASSWORD -AsPlainText -Force
$clPwd  = ConvertTo-SecureString $CL_PASSWORD  -AsPlainText -Force
function Ensure-ADAccount($sam, $upn, $pwd, $admin) {
    $u = Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue
    if (-not $u) {
        New-ADUser -Name $sam -SamAccountName $sam -UserPrincipalName $upn `
            -AccountPassword $pwd -Enabled $true -PasswordNeverExpires $true -ChangePasswordAtLogon $false
        $u = Get-ADUser -Filter "SamAccountName -eq '$sam'"
    } else {
        Set-ADAccountPassword -Identity $u.DistinguishedName -Reset -NewPassword $pwd
        Enable-ADAccount -Identity $u.DistinguishedName
        Set-ADUser -Identity $u.DistinguishedName -PasswordNeverExpires $true -ChangePasswordAtLogon $false
    }
    if ($admin) { Add-ADGroupMember -Identity 'Domain Admins' -Members $u.SamAccountName -ErrorAction SilentlyContinue }
    Write-Output "Done: $upn"
}
Ensure-ADAccount $SQL_SAM $SQL_UPN $sqlPwd $false
Ensure-ADAccount $CL_SAM $CL_UPN $clPwd $true
Write-Output 'AD_ACCOUNTS_READY'
'@ | Set-Content -Path $adScriptFile -Encoding utf8

$sqlSam = $sqlServiceAccount.Split('@')[0]
$clSam  = $clusterOperatorAccount.Split('@')[0]

# Delete any stale run-command resource first
az vm run-command delete --resource-group $rgName --vm-name $dcVmName --run-command-name 'CreateADAccounts' --yes 2>$null | Out-Null

az vm run-command create `
    --resource-group $rgName `
    --vm-name $dcVmName `
    --run-command-name 'CreateADAccounts' `
    --script "@$adScriptFile" `
    --parameters "SQL_SAM=$sqlSam" "SQL_UPN=$sqlServiceAccount" "CL_SAM=$clSam" "CL_UPN=$clusterOperatorAccount" `
    --protected-parameters "SQL_PASSWORD=$sqlServiceAccountPassword" "CL_PASSWORD=$clusterOperatorAccountPassword" `
    --timeout-in-seconds 600 `
    --async-execution false | Out-Null

Remove-Item $adScriptFile -Force -ErrorAction SilentlyContinue

# Poll for completion
Write-Host "  Waiting for account provisioning to complete (up to 10 min)..." -ForegroundColor Gray
$maxWait = 60
for ($i = 1; $i -le $maxWait; $i++) {
    $rcStatus = az vm run-command show `
        --resource-group $rgName `
        --vm-name $dcVmName `
        --run-command-name 'CreateADAccounts' `
        --expand instanceView `
        -o json 2>$null | ConvertFrom-Json

    $execState = $rcStatus.instanceView.executionState
    $stdOut    = $rcStatus.instanceView.output
    $stdErr    = $rcStatus.instanceView.error

    if ($execState -eq 'Succeeded') {
        Write-Host "  Script output: $stdOut" -ForegroundColor Gray
        if ($stdOut -notmatch 'AD_ACCOUNTS_READY') {
            Write-Error "Account provisioning succeeded but output unexpected.`nstdout: $stdOut`nstderr: $stdErr"
            exit 1
        }
        Write-Host "  ✓ AD accounts provisioned" -ForegroundColor Green
        break
    } elseif ($execState -eq 'Failed') {
        Write-Error "Account provisioning FAILED.`nstdout: $stdOut`nstderr: $stdErr"
        exit 1
    }

    Write-Host "  Attempt $i/$maxWait - state: $execState, waiting 10s..." -ForegroundColor Gray
    Start-Sleep -Seconds 10

    if ($i -eq $maxWait) {
        Write-Error "AD account provisioning timed out after $($maxWait * 10)s. Last state: $execState"
        exit 1
    }
}

az vm run-command delete --resource-group $rgName --vm-name $dcVmName --run-command-name 'CreateADAccounts' --yes 2>$null | Out-Null

# --- Deploy Phase 2 ---
Write-Host "`n==> Deploying Phase 2 (Jumpbox + SQL VMs + WSFC + AG)..." -ForegroundColor Cyan

$templateFile = Join-Path $PSScriptRoot '..\infra\phase2-sql.bicep'
$phase2DeploymentName = "${envName}-phase2-$(Get-Date -Format 'yyyyMMddHHmmss')"

# Write parameters to temp file
$paramsObj = [ordered]@{
    adminUsername            = @{ value = $adminUsername }
    adminPassword            = @{ value = $adminPassword }
    domainFqdn               = @{ value = $domainFqdn }
    domainNetBiosName        = @{ value = $domainNetBiosName }
    sqlServiceAccount        = @{ value = $sqlServiceAccount }
    sqlServiceAccountPassword = @{ value = $sqlServiceAccountPassword }
    clusterOperatorAccount   = @{ value = $clusterOperatorAccount }
    clusterOperatorAccountPassword = @{ value = $clusterOperatorAccountPassword }
    clusterBootstrapAccount  = @{ value = $clusterBootstrapAccount }
    clusterBootstrapAccountPassword = @{ value = $clusterBootstrapAccountPassword }
    allowedSourceIp          = @{ value = $allowedIp }
    dcPrivateIp              = @{ value = $dcPrivateIp }
    cloudWitnessBlobEndpoint = @{ value = $cloudWitnessBlobEndpoint }
    cloudWitnessPrimaryKey   = @{ value = $cwKey }
    subnetIds                = @{ value = $subnetIds }
}
$paramsFile = [System.IO.Path]::ChangeExtension((New-TemporaryFile).FullName, '.json')
$paramsObj | ConvertTo-Json -Depth 5 | Set-Content -Path $paramsFile -Encoding utf8

$deployOutput = az deployment group create `
    --resource-group $rgName `
    --template-file $templateFile `
    --name $phase2DeploymentName `
    --parameters "@$paramsFile" 2>&1

if ($LASTEXITCODE -ne 0) {
    $deployOutput | Out-Host
    Write-Error "Phase 2 deployment failed."
    Remove-Item -Path $paramsFile -Force -ErrorAction SilentlyContinue
    exit 1
}

# --- Show outputs ---
Write-Host "`n✓ Phase 2 deployment completed successfully" -ForegroundColor Green
Remove-Item -Path $paramsFile -Force -ErrorAction SilentlyContinue
az deployment group show `
    --resource-group $rgName `
    --name $phase2DeploymentName `
    --query 'properties.outputs' `
    --output table
