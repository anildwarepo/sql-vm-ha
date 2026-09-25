<#
.SYNOPSIS
    Onboards the SQL Server VMs of this deployment to Azure Arc (Arc-enabled servers +
    SQL Server enabled by Azure Arc), emulating SQL Server VMs that run outside Azure (e.g. AWS).

.DESCRIPTION
    EVALUATION / TESTING ONLY. Arc is not supported on Azure VMs in production. This script
    applies the documented evaluation workaround:
    https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine

    For each VM it:
      1. Removes the SQL IaaS Agent registration (Microsoft.SqlVirtualMachine resource).
      2. Removes all Azure VM extensions and managed Run Commands.
      3. Uses Azure Run Command one last time to start a SYSTEM scheduled task that
         (Install-ArcAgentOnVm.ps1) sets MSFT_ARC_TEST, installs the Connected Machine agent,
         blocks IMDS, disables the Azure guest agent and runs 'azcmagent connect'.
      4. Waits for the Arc machine to be Connected.
      5. Installs the Azure extension for SQL Server (WindowsAgent.SqlServer) with the
         requested license type and waits for the SQL Server - Azure Arc resources.

    Side effects on the Azure VMs (until Disable-SqlArcEvaluation.ps1 is run):
      - Azure VM extensions, Azure VM Run Command, SQL IaaS Agent features, Defender for SQL on
        Azure VMs, and 'azd provision' / the repo hooks no longer work against these VMs.
      - Azure IMDS / VM managed identity is blocked inside the guest.
    The AG, WSFC, listener and SQL logins keep working.

    Authentication: a short-lived ARM access token for the signed-in az CLI user is passed to
    azcmagent (no service principal is created). Your account needs 'Azure Connected Machine
    Onboarding' (or Contributor) on the Arc resource group, plus rights to register providers.

.EXAMPLE
    .\scripts\arc\Enable-SqlArcEvaluation.ps1

.EXAMPLE
    .\scripts\arc\Enable-SqlArcEvaluation.ps1 -VmNames SQL-VM-2 -ArcResourceGroup rg-aws-sql-arc -LicenseType LicenseOnly -Force
#>
[CmdletBinding()]
param(
    [string]$EnvironmentName,
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string[]]$VmNames = @('SQL-VM-1', 'SQL-VM-2'),
    [string]$ArcResourceGroup,
    [string]$Location,
    # Paid = SQL license with Software Assurance (no Arc SQL charge, full feature set).
    # PAYG would bill SQL licensing through Arc on top of the PAYG marketplace image.
    [ValidateSet('Paid', 'PAYG', 'LicenseOnly')]
    [string]$LicenseType = 'Paid',
    [hashtable]$Tags = @{ Environment = 'arc-evaluation'; EmulatedCloud = 'AWS' },
    # Let Arc auto-onboarding install the SQL extension instead of this script.
    [switch]$AutomaticSqlOnboarding,
    [int]$TimeoutMinutes = 20,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ArcEvalCommon.ps1')

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$installScript = Join-Path $PSScriptRoot 'Install-ArcAgentOnVm.ps1'
$taskName = 'ArcEvalOnboard'
$sqlExtensionName = 'WindowsAgent.SqlServer'

# ---------------------------------------------------------------------------
# Resolve settings (parameters override the azd environment)
# ---------------------------------------------------------------------------
$azdEnv = Get-AzdEnvironmentValues -RepoRoot $repoRoot -EnvironmentName $EnvironmentName
if (-not $SubscriptionId) { $SubscriptionId = $azdEnv['AZURE_SUBSCRIPTION_ID'] }
if (-not $ResourceGroup) { $ResourceGroup = $azdEnv['AZURE_RESOURCE_GROUP'] }
if (-not $Location) { $Location = $azdEnv['AZURE_LOCATION'] }
if (-not $ResourceGroup) { throw 'ResourceGroup not provided and AZURE_RESOURCE_GROUP not found in the azd environment.' }

Write-Section 'Checking Azure CLI context'
$account = Invoke-Az @('account', 'show') -Json
if ($SubscriptionId -and $account.id -ne $SubscriptionId) {
    Invoke-Az @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
    $account = Invoke-Az @('account', 'show') -Json
}
$SubscriptionId = $account.id
$tenantId = $account.tenantId
if (-not $Location) { $Location = (Invoke-Az @('group', 'show', '-n', $ResourceGroup) -Json).location }
if (-not $ArcResourceGroup) { $ArcResourceGroup = "$ResourceGroup-arc" }

Write-Info "Subscription   : $($account.name) ($SubscriptionId)"
Write-Info "VM RG          : $ResourceGroup"
Write-Info "Arc RG         : $ArcResourceGroup ($Location)"
Write-Info "VMs            : $($VmNames -join ', ')"
Write-Info "SQL license    : $LicenseType"

if (-not $Force) {
    Write-Host ''
    Write-Warning ('EVALUATION ONLY: this removes the SQL IaaS Agent registration and all VM extensions, ' +
        'blocks IMDS and disables the Azure guest agent on: ' + ($VmNames -join ', ') +
        '. Azure VM Run Command, VM extensions and the azd hooks stop working on these VMs until ' +
        'Disable-SqlArcEvaluation.ps1 is run.')
    $answer = Read-Host "Type YES to continue"
    if ($answer -cne 'YES') { Write-Host 'Aborted.'; return }
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
Write-Section 'Registering resource providers'
foreach ($ns in 'Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.HybridConnectivity',
                'Microsoft.AzureArcData', 'Microsoft.Compute') {
    $state = Invoke-Az @('provider', 'show', '-n', $ns, '--query', 'registrationState', '-o', 'tsv')
    if ($state -ne 'Registered') {
        Write-Info "Registering $ns ($state)..."
        Invoke-Az @('provider', 'register', '-n', $ns, '--wait') | Out-Null
    }
    Write-Ok "$ns registered"
}

Write-Section 'Ensuring az CLI connectedmachine extension'
Invoke-Az @('extension', 'add', '--name', 'connectedmachine', '--upgrade') | Out-Null
Write-Ok 'connectedmachine extension ready'

Write-Section "Ensuring Arc resource group '$ArcResourceGroup'"
$tagArgs = @($Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
Invoke-Az (@('group', 'create', '-n', $ArcResourceGroup, '-l', $Location, '--tags') + $tagArgs) | Out-Null
Write-Ok "$ArcResourceGroup ready"

function Get-ArcMachine([string]$Name) {
    Invoke-Az @('connectedmachine', 'show', '-g', $ArcResourceGroup, '-n', $Name) -Json -AllowFailure
}

# ---------------------------------------------------------------------------
# Prepare each Azure VM and launch the on-VM onboarding task
# ---------------------------------------------------------------------------
$agentTags = [ordered]@{}
foreach ($kv in $Tags.GetEnumerator()) { $agentTags[$kv.Key] = $kv.Value }
$agentTags['SourceAzureVm'] = $ResourceGroup
if (-not $AutomaticSqlOnboarding) {
    # Opt out of auto-onboarding so this script controls the license type.
    $agentTags['ArcSQLServerExtensionDeployment'] = 'Disabled'
}
$agentTagString = ($agentTags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ','

$launched = @()
foreach ($vm in $VmNames) {
    Write-Section "Preparing $vm"

    $existing = Get-ArcMachine $vm
    if ($existing -and $existing.status -eq 'Connected') {
        Write-Ok "$vm is already connected to Azure Arc - skipping VM preparation"
        $launched += $vm
        continue
    }

    $view = Invoke-Az @('vm', 'get-instance-view', '-g', $ResourceGroup, '-n', $vm) -Json
    $power = ($view.instanceView.statuses | Where-Object code -like 'PowerState/*').code
    if ($power -ne 'PowerState/running') { throw "$vm is not running ($power). Start it and rerun." }
    $agentStatus = ($view.instanceView.vmAgent.statuses | Select-Object -First 1).displayStatus
    if ($agentStatus -ne 'Ready') {
        throw ("$vm Azure VM agent is '$agentStatus'. If it was already disabled by a previous run, " +
            "run scripts\arc\Install-ArcAgentOnVm.ps1 on the VM over RDP instead.")
    }

    # 1. SQL IaaS Agent registration
    $sqlVm = Invoke-Az @('sql', 'vm', 'show', '-g', $ResourceGroup, '-n', $vm) -Json -AllowFailure
    if ($sqlVm) {
        Write-Info 'Removing SQL IaaS Agent registration (Microsoft.SqlVirtualMachine)...'
        Invoke-Az @('sql', 'vm', 'delete', '-g', $ResourceGroup, '-n', $vm, '--yes') | Out-Null
        Write-Ok 'SQL IaaS Agent registration removed'
    }

    # 2. VM extensions and managed Run Commands
    $extensions = Invoke-Az @('vm', 'extension', 'list', '-g', $ResourceGroup, '--vm-name', $vm) -Json
    foreach ($ext in $extensions) {
        Write-Info "Removing VM extension $($ext.name)..."
        Invoke-Az @('vm', 'extension', 'delete', '-g', $ResourceGroup, '--vm-name', $vm, '-n', $ext.name) | Out-Null
    }
    $runCommands = Invoke-Az @('vm', 'run-command', 'list', '-g', $ResourceGroup, '--vm-name', $vm) -Json
    foreach ($rc in $runCommands) {
        Write-Info "Removing managed Run Command $($rc.name)..."
        Invoke-Az @('vm', 'run-command', 'delete', '-g', $ResourceGroup, '--vm-name', $vm,
            '--run-command-name', $rc.name, '--yes') | Out-Null
    }
    Write-Ok 'VM extensions removed'

    # The SQL IaaS Agent also publishes sqlServerInstances (host type "Azure Virtual Machine")
    # once Microsoft.AzureArcData is registered; they are not removed with the registration.
    $vmId = $view.id
    foreach ($inst in @(Invoke-Az @('resource', 'list', '-g', $ResourceGroup,
            '--resource-type', 'Microsoft.AzureArcData/sqlServerInstances') -Json)) {
        if (-not $inst) { continue }
        $detail = Invoke-Az @('resource', 'show', '--ids', $inst.id) -Json -AllowFailure
        if ($detail -and $detail.properties.containerResourceId -ieq $vmId) {
            Write-Info "Removing Azure VM SQL instance resource $($inst.name)..."
            Invoke-Az @('resource', 'delete', '--ids', $inst.id) -AllowFailure | Out-Null
        }
    }

    # 3. Launch the on-VM onboarding task (last use of Azure Run Command on this VM)
    $token = Invoke-Az @('account', 'get-access-token', '--resource', 'https://management.azure.com/') -Json
    $config = @{
        TenantId            = $tenantId
        SubscriptionId      = $SubscriptionId
        ResourceGroup       = $ArcResourceGroup
        Location            = $Location
        ResourceName        = $vm
        AccessToken         = $token.accessToken
        Tags                = $agentTagString
        InitialDelaySeconds = 60
    }
    $wrapperPath = Join-Path ([IO.Path]::GetTempPath()) "arc-eval-$vm-$([guid]::NewGuid().ToString('N')).ps1"
    try {
        [IO.File]::WriteAllText($wrapperPath,
            (New-VmScheduledTaskWrapper -PayloadPath $installScript -TaskName $taskName -Config $config),
            (New-Object Text.UTF8Encoding $false))
        Write-Info 'Starting Arc onboarding task on the VM via Run Command...'
        $message = Invoke-Az @('vm', 'run-command', 'invoke', '-g', $ResourceGroup, '-n', $vm,
            '--command-id', 'RunPowerShellScript', '--scripts', "@$wrapperPath",
            '--query', 'value[].message', '-o', 'tsv')
    }
    finally {
        Remove-Item $wrapperPath -Force -ErrorAction SilentlyContinue
        $config.AccessToken = $null; $token = $null
    }
    if ($message -notmatch 'ARC_EVAL_TASK_STARTED') { throw "Failed to start onboarding task on ${vm}:`n$message" }
    Write-Ok "Onboarding task started on $vm (log: C:\ArcEval\arc-onboard.log)"
    $launched += $vm
}

# ---------------------------------------------------------------------------
# Wait for Arc connection
# ---------------------------------------------------------------------------
Write-Section 'Waiting for Arc-enabled servers to connect'
$failed = @()
foreach ($vm in $launched) {
    $machine = Wait-Until -Description "$vm to report Connected" -TimeoutMinutes $TimeoutMinutes -Condition {
        $m = Get-ArcMachine $vm
        if ($m -and $m.status -eq 'Connected') { $m }
    }
    if ($machine) {
        Write-Ok "$vm connected (agent $($machine.agentVersion)) -> $($machine.id)"
    } else {
        Write-Warn "$vm did not connect within $TimeoutMinutes minutes. RDP to the VM and check C:\ArcEval\arc-onboard.log."
        $failed += $vm
    }
}
$connected = @($launched | Where-Object { $_ -notin $failed })

# ---------------------------------------------------------------------------
# Azure extension for SQL Server
# ---------------------------------------------------------------------------
if ($connected.Count -gt 0) {
    Write-Section 'Installing Azure extension for SQL Server'
    $settingsPath = Join-Path ([IO.Path]::GetTempPath()) "arc-sql-settings-$([guid]::NewGuid().ToString('N')).json"
    @{ SqlManagement = @{ IsEnabled = $true }; LicenseType = $LicenseType; ExcludedSqlInstances = @() } |
        ConvertTo-Json -Compress | Set-Content -Path $settingsPath -Encoding ascii
    try {
        foreach ($vm in $connected) {
            $ext = Invoke-Az @('connectedmachine', 'extension', 'show', '-g', $ArcResourceGroup,
                '--machine-name', $vm, '-n', $sqlExtensionName) -Json -AllowFailure
            if ($ext) { Write-Ok "$vm already has $sqlExtensionName ($($ext.properties.provisioningState))"; continue }
            if ($AutomaticSqlOnboarding) { Write-Info "$vm will be onboarded by Arc automatic SQL onboarding"; continue }

            Write-Info "Creating $sqlExtensionName on $vm (LicenseType=$LicenseType)..."
            Invoke-Az @('connectedmachine', 'extension', 'create', '-g', $ArcResourceGroup,
                '--machine-name', $vm, '-n', $sqlExtensionName, '--location', $Location,
                '--publisher', 'Microsoft.AzureData', '--type', $sqlExtensionName,
                '--settings', "@$settingsPath", '--no-wait') | Out-Null
        }
    }
    finally { Remove-Item $settingsPath -Force -ErrorAction SilentlyContinue }

    foreach ($vm in $connected) {
        $ext = Wait-Until -Description "$sqlExtensionName on $vm" -TimeoutMinutes $TimeoutMinutes -Condition {
            $e = Invoke-Az @('connectedmachine', 'extension', 'show', '-g', $ArcResourceGroup,
                '--machine-name', $vm, '-n', $sqlExtensionName) -Json -AllowFailure
            if ($e -and $e.properties.provisioningState -in 'Succeeded', 'Failed') { $e }
        }
        if (-not $ext) { Write-Warn "$sqlExtensionName on $vm did not finish within $TimeoutMinutes minutes"; $failed += $vm }
        elseif ($ext.properties.provisioningState -eq 'Failed') {
            Write-Warn "$sqlExtensionName failed on ${vm}: $($ext.properties.instanceView.status.message)"; $failed += $vm
        }
        else { Write-Ok "$sqlExtensionName succeeded on $vm" }
    }

    Write-Section 'Waiting for SQL Server - Azure Arc resources'
    $instances = Wait-Until -Description 'Microsoft.AzureArcData/sqlServerInstances' -TimeoutMinutes 10 -Condition {
        $r = @(Invoke-Az @('resource', 'list', '-g', $ArcResourceGroup,
            '--resource-type', 'Microsoft.AzureArcData/sqlServerInstances') -Json) |
            Where-Object { $n = $_.name; $connected | Where-Object { $n -eq $_ -or $n -like "${_}_*" } }
        $missing = @($connected | Where-Object { $vmName = $_; -not ($r | Where-Object { $_.name -eq $vmName -or $_.name -like "${vmName}_*" }) })
        if ($missing.Count -eq 0) { $r }
    }
    if ($instances) {
        $instances | ForEach-Object { Write-Ok "SQL Server - Azure Arc: $($_.name)" }
    } else {
        Write-Warn 'SQL Server instance resources not visible yet; they can take several more minutes to appear.'
    }
}

Write-Section 'Summary'
Write-Info "Arc resource group: https://portal.azure.com/#@$tenantId/resource/subscriptions/$SubscriptionId/resourceGroups/$ArcResourceGroup/overview"
Write-Info 'Revert with: .\scripts\arc\Disable-SqlArcEvaluation.ps1'
if ($failed.Count -gt 0) {
    Write-Warn "Incomplete: $(($failed | Select-Object -Unique) -join ', ')"
    exit 1
}
Write-Ok 'Azure Arc evaluation onboarding complete'
