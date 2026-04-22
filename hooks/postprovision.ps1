<#
.SYNOPSIS
    Post-provision hook: waits for DCs to be ready, then deploys Phase 2 (Jumpbox + SQL VMs).

#>

$ErrorActionPreference = 'Stop'

# Suppress Azure CLI warnings (deprecation notices, upgrade prompts) that write to stderr
# and get treated as terminating errors by $ErrorActionPreference = 'Stop'
$env:AZURE_CORE_ONLY_SHOW_ERRORS = 'true'

# --- Read azd environment ---
# Temporarily relax error preference so azd stderr warnings (e.g. version notices) don't terminate
$ErrorActionPreference = 'Continue'
$rgName = "$(azd env get-value AZURE_RESOURCE_GROUP 2>$null)".Trim()
$domainFQDN = "$(azd env get-value AZURE_DOMAIN_FQDN 2>$null)".Trim()
$envName = "$(azd env get-value AZURE_ENV_NAME 2>$null)".Trim()
$domainNetBiosName = "$(azd env get-value AZURE_DOMAIN_NETBIOS 2>$null)".Trim()
$allowedIp = "$(azd env get-value AZURE_ALLOWED_SOURCE_IP 2>$null)".Trim()
$dcVmName = "$(azd env get-value dcVmName 2>$null)".Trim()
$ErrorActionPreference = 'Stop'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Phase 2: Jumpbox + SQL VMs Deployment" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# --- Get Phase 1 outputs ---
Write-Host "==> Reading Phase 1 deployment outputs..." -ForegroundColor Cyan

# Find latest Phase 1-style deployment. Exclude prior Phase 2 deployments (e.g. "dev-phase2").
$deploymentName = az deployment group list `
    --resource-group $rgName `
    --query "[?starts_with(name, '$envName') && !contains(name, 'phase2')].name | [0]" -o tsv 2>$null

if (-not $deploymentName) {
    Write-Error "Could not find a deployment starting with '$envName' in resource group '$rgName'."
    exit 1
}
Write-Host "  Found deployment: $deploymentName" -ForegroundColor Gray

$outputs = az deployment group show `
    --resource-group $rgName `
    --name $deploymentName `
    --query 'properties.outputs' `
    --output json 2>$null | ConvertFrom-Json

$dcPrivateIp = $outputs.dcPrivateIp.value
$subnetIds = @($outputs.subnetIds.value)

if ([string]::IsNullOrWhiteSpace($dcPrivateIp) -or $subnetIds.Count -lt 4) {
    Write-Error "Phase 1 outputs are missing or incomplete."
    exit 1
}

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
        --scripts "try { Get-ADDomain -ErrorAction Stop | Out-Null; Write-Output 'AD_OK' } catch { Write-Output 'AD_FAIL' }" `
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

$ErrorActionPreference = 'Continue'
$adminUsername = "$(azd env get-value AZURE_ADMIN_USERNAME 2>$null)".Trim()
$adminPassword = "$(azd env get-value AZURE_ADMIN_PASSWORD 2>$null)".Trim()
$sqlServiceAccount = "$(azd env get-value AZURE_SQL_SERVICE_ACCOUNT 2>$null)".Trim()
$sqlServiceAccountPassword = "$(azd env get-value AZURE_SQL_SERVICE_PASSWORD 2>$null)".Trim()
$clusterOperatorAccount = "$(azd env get-value AZURE_CLUSTER_OPERATOR_ACCOUNT 2>$null)".Trim()
$clusterOperatorAccountPassword = "$(azd env get-value AZURE_CLUSTER_OPERATOR_PASSWORD 2>$null)".Trim()
$clusterBootstrapAccount = "$(azd env get-value AZURE_CLUSTER_BOOTSTRAP_ACCOUNT 2>$null)".Trim()
$clusterBootstrapAccountPassword = "$(azd env get-value AZURE_CLUSTER_BOOTSTRAP_PASSWORD 2>$null)".Trim()
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($sqlServiceAccount) -or [string]::IsNullOrWhiteSpace($sqlServiceAccountPassword)) {
    Write-Error "Required account credentials missing from azd env. Re-run setup-env.ps1."
    exit 1
}

Write-Host "  [OK] All credentials available" -ForegroundColor Green

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
    --async-execution false 2>$null | Out-Null

Remove-Item $adScriptFile -Force -ErrorAction SilentlyContinue

# Poll for completion
Write-Host "  Waiting for account provisioning to complete (up to 10 min)..." -ForegroundColor Gray
$maxWait = 60
for ($i = 1; $i -le $maxWait; $i++) {
    $rcStatus = az vm run-command show `
        --resource-group $rgName `
        --vm-name $dcVmName `
        --run-command-name 'CreateADAccounts' `
        --instance-view `
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
        Write-Host "  [OK] AD accounts provisioned" -ForegroundColor Green
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
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters     = [ordered]@{
        adminUsername            = @{ value = $adminUsername }
        adminPassword            = @{ value = $adminPassword }
        domainFqdn               = @{ value = $domainFqdn }
        domainNetBiosName        = @{ value = $domainNetBiosName }
        allowedSourceIp          = @{ value = $allowedIp }
        dcPrivateIp              = @{ value = $dcPrivateIp }
        subnetIds                = @{ value = $subnetIds }
    }
}
$paramsFile = [System.IO.Path]::ChangeExtension((New-TemporaryFile).FullName, '.json')
$paramsObj | ConvertTo-Json -Depth 5 | Set-Content -Path $paramsFile -Encoding utf8

$deployOutput = az deployment group create `
    --resource-group $rgName `
    --template-file $templateFile `
    --name $phase2DeploymentName `
    --parameters "@$paramsFile" 2>&1 | Out-String

if ($LASTEXITCODE -ne 0) {
    $deployOutput | Out-Host
    Write-Error "Phase 2 deployment failed."
    Remove-Item -Path $paramsFile -Force -ErrorAction SilentlyContinue
    exit 1
}

Write-Host "`n[OK] Phase 2 deployment completed successfully" -ForegroundColor Green
Remove-Item -Path $paramsFile -Force -ErrorAction SilentlyContinue

# =====================================================================
# Phase 3: Manual WSFC Cluster + File Share Witness + AG Configuration
# =====================================================================

# --- Helper: run a script on a VM, poll for result, clean up ---
function Invoke-VmScript {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$RunCommandName,
        [string]$ScriptPath,
        [string[]]$Parameters,
        [string[]]$ProtectedParameters,
        [string]$SuccessMarker,
        [int]$TimeoutSeconds = 600,
        [int]$PollMaxAttempts = 60,
        [int]$PollIntervalSec = 10
    )

    az vm run-command delete --resource-group $ResourceGroup --vm-name $VmName --run-command-name $RunCommandName --yes 2>$null | Out-Null

    $createArgs = @(
        'vm', 'run-command', 'create',
        '--resource-group', $ResourceGroup,
        '--vm-name', $VmName,
        '--run-command-name', $RunCommandName,
        '--script', "@$ScriptPath",
        '--timeout-in-seconds', $TimeoutSeconds,
        '--async-execution', 'false'
    )
    if ($Parameters) { $createArgs += '--parameters'; $createArgs += $Parameters }
    if ($ProtectedParameters) { $createArgs += '--protected-parameters'; $createArgs += $ProtectedParameters }

    az @createArgs 2>$null | Out-Null

    for ($i = 1; $i -le $PollMaxAttempts; $i++) {
        $rc = az vm run-command show --resource-group $ResourceGroup --vm-name $VmName --run-command-name $RunCommandName --instance-view -o json 2>$null | ConvertFrom-Json
        $state  = $rc.instanceView.executionState
        $stdout = $rc.instanceView.output
        $stderr = $rc.instanceView.error

        if ($state -eq 'Succeeded') {
            if ($stdout -match $SuccessMarker) {
                az vm run-command delete --resource-group $ResourceGroup --vm-name $VmName --run-command-name $RunCommandName --yes 2>$null | Out-Null
                return $stdout
            }
            Write-Error "Script on $VmName succeeded but marker '$SuccessMarker' not found.`nstdout: $stdout`nstderr: $stderr"
            exit 1
        } elseif ($state -eq 'Failed') {
            Write-Error "Script on $VmName FAILED.`nstdout: $stdout`nstderr: $stderr"
            exit 1
        }
        Write-Host "    Attempt $i/$PollMaxAttempts - state: $state ..." -ForegroundColor Gray
        Start-Sleep -Seconds $PollIntervalSec
    }
    Write-Error "Script on $VmName timed out after $($PollMaxAttempts * $PollIntervalSec)s."
    exit 1
}

# --- Step 1: Create file share witness on DC ---
Write-Host "`n==> Creating file share witness on $dcVmName..." -ForegroundColor Cyan

$fswShareName = 'fswshare'
$fswScript = [System.IO.Path]::ChangeExtension((New-TemporaryFile).FullName, '.ps1')
@'
param([string]$ShareName)
$sharePath = "C:\FSW\$ShareName"
if (-not (Test-Path $sharePath)) { New-Item -ItemType Directory -Path $sharePath -Force | Out-Null }
$existing = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
if ($existing) { Remove-SmbShare -Name $ShareName -Force }
New-SmbShare -Name $ShareName -Path $sharePath -FullAccess "Everyone" | Out-Null
$acl = Get-Acl $sharePath
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule("Everyone", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.AddAccessRule($rule)
Set-Acl $sharePath $acl
Write-Output "FSW_READY"
'@ | Set-Content -Path $fswScript -Encoding utf8

Invoke-VmScript -ResourceGroup $rgName -VmName $dcVmName -RunCommandName 'CreateFSW' `
    -ScriptPath $fswScript -Parameters "ShareName=$fswShareName" -SuccessMarker 'FSW_READY'
Remove-Item $fswScript -Force -ErrorAction SilentlyContinue
Write-Host "  [OK] \\$dcVmName\$fswShareName created" -ForegroundColor Green

# --- Step 2: Install Failover Clustering + Create WSFC + Quorum + Enable AlwaysOn + Create AG ---
Write-Host "`n==> Configuring WSFC cluster and Availability Group on SQL-VM-1..." -ForegroundColor Cyan

$wsfcScript = [System.IO.Path]::ChangeExtension((New-TemporaryFile).FullName, '.ps1')
@'
param(
    [string]$ClusterName,
    [string]$Node1,
    [string]$Node2,
    [string]$Node1Ip,
    [string]$Node2Ip,
    [string]$FSWPath,
    [string]$DomainUser,
    [string]$DomainPassword,
    [string]$SqlSvcAccount,
    [string]$SqlSvcPassword,
    [string]$AGName,
    [string]$ListenerName,
    [string]$ListenerIp1,
    [string]$ListenerSubnet1,
    [string]$ListenerIp2,
    [string]$ListenerSubnet2
)

$ErrorActionPreference = 'Stop'

$domainPwd = ConvertTo-SecureString $DomainPassword -AsPlainText -Force
$domainCred = New-Object System.Management.Automation.PSCredential($DomainUser, $domainPwd)

# 1) Install Failover Clustering on both nodes
Write-Output "Installing Failover Clustering..."
Invoke-Command -ComputerName $Node1 -Credential $domainCred -ScriptBlock {
    Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools -ErrorAction Stop | Out-Null
} -ErrorAction Stop
Invoke-Command -ComputerName $Node2 -Credential $domainCred -ScriptBlock {
    Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools -ErrorAction Stop | Out-Null
} -ErrorAction Stop

# 1b) Enable CredSSP to avoid Kerberos double-hop issues with New-Cluster
Write-Output "Enabling CredSSP for delegation..."
Enable-WSManCredSSP -Role Client -DelegateComputer '*.contoso.local' -Force | Out-Null
Enable-WSManCredSSP -Role Server -Force | Out-Null
Invoke-Command -ComputerName $Node2 -Credential $domainCred -ScriptBlock {
    Enable-WSManCredSSP -Role Server -Force | Out-Null
} -ErrorAction Stop

# 2) Create cluster (multi-subnet) - must run as domain admin via CredSSP
Write-Output "Creating WSFC cluster..."
$clusterExists = $null
try { $clusterExists = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue } catch {}
if (-not $clusterExists) {
    Invoke-Command -ComputerName $Node1 -Credential $domainCred -Authentication CredSSP -ScriptBlock {
        New-Cluster -Name $using:ClusterName -Node @($using:Node1, $using:Node2) `
            -StaticAddress @($using:Node1Ip, $using:Node2Ip) `
            -NoStorage -Force -ErrorAction Stop | Out-Null
    } -ErrorAction Stop
}

# 3) Set file share witness quorum
Write-Output "Setting file share witness quorum..."
Invoke-Command -ComputerName $Node1 -Credential $domainCred -Authentication CredSSP -ScriptBlock {
    Set-ClusterQuorum -FileShareWitness $using:FSWPath -ErrorAction Stop
} -ErrorAction Stop

# 4) Enable AlwaysOn on both SQL instances
Write-Output "Enabling AlwaysOn..."
Invoke-Command -ComputerName $Node1 -Credential $domainCred -ScriptBlock {
    Enable-SqlAlwaysOn -ServerInstance $using:Node1 -Force -NoServiceRestart -ErrorAction Stop
} -ErrorAction Stop
Invoke-Command -ComputerName $Node2 -Credential $domainCred -ScriptBlock {
    Enable-SqlAlwaysOn -ServerInstance $using:Node2 -Force -NoServiceRestart -ErrorAction Stop
} -ErrorAction Stop

# 5) Restart SQL in single-user mode to bootstrap sysadmin access, then restart normally
#    SYSTEM (az vm run-command context) is not SQL sysadmin by default on marketplace images.
#    Single-user mode grants sysadmin to the first connection.
Write-Output "Bootstrapping SQL sysadmin access on Node1 via single-user mode..."

# Helper function to bootstrap a SQL node via single-user mode
function Bootstrap-SqlSysadmin {
    param([string]$ServerInstance, [string]$LoginToAdd)

    # Find SQL Server registry path for startup parameters
    $instName = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -Name MSSQLSERVER).MSSQLSERVER
    $regPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instName\MSSQLServer\Parameters"
    $props = Get-ItemProperty $regPath
    $argIdx = ($props.PSObject.Properties | Where-Object { $_.Name -match '^SQLArg\d+$' } | Measure-Object).Count

    # Stop SQL Agent first so it doesn't steal the single-user connection
    Stop-Service SQLSERVERAGENT -Force -ErrorAction SilentlyContinue
    Start-Sleep 3

    # Add -m startup flag (single-user mode)
    New-ItemProperty -Path $regPath -Name "SQLArg$argIdx" -Value '-m' -PropertyType String -Force | Out-Null

    # Restart SQL in single-user mode (no Agent)
    Stop-Service MSSQLSERVER -Force -ErrorAction Stop
    Start-Sleep 5
    Start-Service MSSQLSERVER -ErrorAction Stop
    Start-Sleep 10

    # Retry sqlcmd connection in case SQL is still starting
    $maxRetry = 5
    for ($r = 1; $r -le $maxRetry; $r++) {
        $result = & sqlcmd.exe -S $ServerInstance -E -Q "SELECT 1" 2>&1
        if ($LASTEXITCODE -eq 0) { break }
        Write-Output "  sqlcmd connect attempt $r/$maxRetry failed, retrying..."
        Start-Sleep 5
    }

    & sqlcmd.exe -S $ServerInstance -E -Q "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'NT AUTHORITY\SYSTEM') CREATE LOGIN [NT AUTHORITY\SYSTEM] FROM WINDOWS; ALTER SERVER ROLE [sysadmin] ADD MEMBER [NT AUTHORITY\SYSTEM];"
    & sqlcmd.exe -S $ServerInstance -E -Q "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$LoginToAdd') CREATE LOGIN [$LoginToAdd] FROM WINDOWS; ALTER SERVER ROLE [sysadmin] ADD MEMBER [$LoginToAdd];"

    # Remove -m flag and restart normally with Agent
    Remove-ItemProperty -Path $regPath -Name "SQLArg$argIdx" -ErrorAction SilentlyContinue
    Stop-Service MSSQLSERVER -Force -ErrorAction Stop
    Start-Sleep 5
    Start-Service MSSQLSERVER -ErrorAction Stop
    Start-Service SQLSERVERAGENT -ErrorAction SilentlyContinue
    Start-Sleep 10
}

Bootstrap-SqlSysadmin -ServerInstance $Node1 -LoginToAdd $DomainUser
Write-Output "Node1 SQL sysadmin bootstrapped."

# Bootstrap Node2 via Invoke-Command (domain admin remoting + local single-user mode)
Write-Output "Bootstrapping SQL sysadmin access on Node2..."
Invoke-Command -ComputerName $Node2 -Credential $domainCred -ScriptBlock {
    $instName = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -Name MSSQLSERVER).MSSQLSERVER
    $regPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instName\MSSQLServer\Parameters"
    $props = Get-ItemProperty $regPath
    $argIdx = ($props.PSObject.Properties | Where-Object { $_.Name -match '^SQLArg\d+$' } | Measure-Object).Count

    # Stop Agent first
    Stop-Service SQLSERVERAGENT -Force -ErrorAction SilentlyContinue
    Start-Sleep 3

    New-ItemProperty -Path $regPath -Name "SQLArg$argIdx" -Value '-m' -PropertyType String -Force | Out-Null
    Stop-Service MSSQLSERVER -Force -ErrorAction Stop
    Start-Sleep 5
    Start-Service MSSQLSERVER -ErrorAction Stop
    Start-Sleep 10

    # Retry connection
    for ($r = 1; $r -le 5; $r++) {
        $result = & sqlcmd.exe -S $using:Node2 -E -Q "SELECT 1" 2>&1
        if ($LASTEXITCODE -eq 0) { break }
        Start-Sleep 5
    }

    & sqlcmd.exe -S $using:Node2 -E -Q "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'NT AUTHORITY\SYSTEM') CREATE LOGIN [NT AUTHORITY\SYSTEM] FROM WINDOWS; ALTER SERVER ROLE [sysadmin] ADD MEMBER [NT AUTHORITY\SYSTEM];"
    & sqlcmd.exe -S $using:Node2 -E -Q "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$($using:DomainUser)') CREATE LOGIN [$($using:DomainUser)] FROM WINDOWS; ALTER SERVER ROLE [sysadmin] ADD MEMBER [$($using:DomainUser)];"
    & sqlcmd.exe -S $using:Node2 -E -Q "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$($using:SqlSvcAccount)') CREATE LOGIN [$($using:SqlSvcAccount)] FROM WINDOWS;"

    Remove-ItemProperty -Path $regPath -Name "SQLArg$argIdx" -ErrorAction SilentlyContinue
    Stop-Service MSSQLSERVER -Force -ErrorAction Stop
    Start-Sleep 5
    Start-Service MSSQLSERVER -ErrorAction Stop
    Start-Service SQLSERVERAGENT -ErrorAction SilentlyContinue
    Start-Sleep 10
} -ErrorAction Stop
Write-Output "Node2 SQL sysadmin bootstrapped."

# 6) Create AG endpoints and AG
Write-Output "Creating AG endpoints and availability group..."

# Node1 endpoint (SYSTEM is now sysadmin)
Invoke-Sqlcmd -ServerInstance $Node1 -Query @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '$SqlSvcAccount')
    CREATE LOGIN [$SqlSvcAccount] FROM WINDOWS;
IF NOT EXISTS (SELECT 1 FROM sys.endpoints WHERE name = 'Hadr_endpoint')
    CREATE ENDPOINT [Hadr_endpoint] STATE = STARTED
        AS TCP (LISTENER_PORT = 5022)
        FOR DATABASE_MIRRORING (ROLE = ALL, AUTHENTICATION = WINDOWS NEGOTIATE, ENCRYPTION = REQUIRED ALGORITHM AES);
GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [$SqlSvcAccount];
"@ -ErrorAction Stop

# Node2 endpoint (domain admin is now sysadmin)
Invoke-Command -ComputerName $Node2 -Credential $domainCred -ScriptBlock {
    Invoke-Sqlcmd -ServerInstance $using:Node2 -Query @"
IF NOT EXISTS (SELECT 1 FROM sys.endpoints WHERE name = 'Hadr_endpoint')
    CREATE ENDPOINT [Hadr_endpoint] STATE = STARTED
        AS TCP (LISTENER_PORT = 5022)
        FOR DATABASE_MIRRORING (ROLE = ALL, AUTHENTICATION = WINDOWS NEGOTIATE, ENCRYPTION = REQUIRED ALGORITHM AES);
GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [$($using:SqlSvcAccount)];
"@ -ErrorAction Stop
} -ErrorAction Stop

# Create AG on Node1 (SYSTEM is now sysadmin)
# First create the AG without listener
Invoke-Sqlcmd -ServerInstance $Node1 -Query @"
IF NOT EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = '$AGName')
    CREATE AVAILABILITY GROUP [$AGName]
    WITH (AUTOMATED_BACKUP_PREFERENCE = SECONDARY, DB_FAILOVER = ON)
    FOR REPLICA ON
        N'$Node1' WITH (ENDPOINT_URL = N'TCP://${Node1}:5022', FAILOVER_MODE = AUTOMATIC, AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, SEEDING_MODE = AUTOMATIC, SECONDARY_ROLE(ALLOW_CONNECTIONS = ALL)),
        N'$Node2' WITH (ENDPOINT_URL = N'TCP://${Node2}:5022', FAILOVER_MODE = AUTOMATIC, AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, SEEDING_MODE = AUTOMATIC, SECONDARY_ROLE(ALLOW_CONNECTIONS = ALL));
"@ -ErrorAction Stop

# Join secondary to AG (domain admin is now sysadmin on Node2)
Invoke-Command -ComputerName $Node2 -Credential $domainCred -ScriptBlock {
    Invoke-Sqlcmd -ServerInstance $using:Node2 -Query "ALTER AVAILABILITY GROUP [$($using:AGName)] JOIN;" -ErrorAction Stop
    Invoke-Sqlcmd -ServerInstance $using:Node2 -Query "ALTER AVAILABILITY GROUP [$($using:AGName)] GRANT CREATE ANY DATABASE;" -ErrorAction Stop
} -ErrorAction Stop

# Add listener separately with non-default port to avoid conflict with default SQL instance on 1433
try {
    Invoke-Sqlcmd -ServerInstance $Node1 -Query @"
IF NOT EXISTS (SELECT name FROM sys.availability_group_listeners WHERE group_id = (SELECT group_id FROM sys.availability_groups WHERE name = '$AGName') AND name = '$ListenerName')
    ALTER AVAILABILITY GROUP [$AGName]
    ADD LISTENER N'$ListenerName' (
        WITH IP (
            (N'$ListenerIp1', N'$ListenerSubnet1'),
            (N'$ListenerIp2', N'$ListenerSubnet2')
        ), PORT = 14333
    );
"@ -ErrorAction Stop
} catch {
    Write-Output "Listener warning (may be non-fatal): $_"
}

Write-Output "WSFC_AG_READY"
'@ | Set-Content -Path $wsfcScript -Encoding utf8

# Compute listener subnet masks from subnet CIDRs
$sql1SubnetId = $subnetIds[1]
$sql2SubnetId = $subnetIds[2]

$ErrorActionPreference = 'Continue'
$sql1Prefix = az network vnet subnet show --ids $sql1SubnetId --query 'addressPrefix' -o tsv 2>$null
$sql2Prefix = az network vnet subnet show --ids $sql2SubnetId --query 'addressPrefix' -o tsv 2>$null
$ErrorActionPreference = 'Stop'

function ConvertTo-SubnetMask([string]$cidr) {
    $bits = [int]($cidr.Split('/')[-1])
    $mask = ([math]::Pow(2, 32) - [math]::Pow(2, 32 - $bits))
    $bytes = [BitConverter]::GetBytes([uint32]$mask)
    [Array]::Reverse($bytes)
    return ($bytes -join '.')
}

$listenerSubnet1 = ConvertTo-SubnetMask $sql1Prefix
$listenerSubnet2 = ConvertTo-SubnetMask $sql2Prefix

$domainAdmin = "$domainNetBiosName\$adminUsername"
$sqlSvcSam = $sqlServiceAccount.Split('@')[0]
$sqlSvcDomain = "$domainNetBiosName\$sqlSvcSam"

$wsfcParams = @(
    "ClusterName=sqlha-cl",
    "Node1=SQL-VM-1",
    "Node2=SQL-VM-2",
    "Node1Ip=10.38.1.10",
    "Node2Ip=10.38.2.10",
    "FSWPath=\\$dcVmName\$fswShareName",
    "DomainUser=$domainAdmin",
    "SqlSvcAccount=$sqlSvcDomain",
    "AGName=ag-sql-ha",
    "ListenerName=ag-listener",
    "ListenerIp1=10.38.1.11",
    "ListenerSubnet1=$listenerSubnet1",
    "ListenerIp2=10.38.2.11",
    "ListenerSubnet2=$listenerSubnet2"
)
$wsfcProtectedParams = @(
    "DomainPassword=$adminPassword",
    "SqlSvcPassword=$sqlServiceAccountPassword"
)

Invoke-VmScript -ResourceGroup $rgName -VmName 'SQL-VM-1' -RunCommandName 'ConfigureWSFCAG' `
    -ScriptPath $wsfcScript -Parameters $wsfcParams -ProtectedParameters $wsfcProtectedParams `
    -SuccessMarker 'WSFC_AG_READY' -TimeoutSeconds 900 -PollMaxAttempts 90
Remove-Item $wsfcScript -Force -ErrorAction SilentlyContinue

Write-Host "  [OK] WSFC cluster, file share witness, and AG configured" -ForegroundColor Green

# =====================================================================
# Phase 4: Register SQL IaaS Agent (after WSFC/AG so SQL is running normally)
# =====================================================================
Write-Host "`n==> Registering SQL IaaS Agent on SQL VMs..." -ForegroundColor Cyan

$ErrorActionPreference = 'Continue'
foreach ($vmName in @('SQL-VM-1', 'SQL-VM-2')) {
    Write-Host "  Registering $vmName..." -ForegroundColor Gray
    $vmId = az vm show --resource-group $rgName --name $vmName --query 'id' -o tsv 2>$null
    az sql vm create `
        --name $vmName `
        --resource-group $rgName `
        --license-type PAYG `
        --sql-mgmt-type Full `
        --location westus3 2>$null | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK] $vmName registered" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] $vmName registration returned non-zero (may already be registered)" -ForegroundColor Yellow
    }
}
$ErrorActionPreference = 'Stop'

Write-Host "`n[OK] All phases complete." -ForegroundColor Green
