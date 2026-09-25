<#
.SYNOPSIS
    Removes what Enable-SqlAgPatching.ps1 created: Event Grid subscriptions and system topics,
    maintenance configuration assignments and configurations, role assignments, webhooks and
    the Automation account.

.DESCRIPTION
    After this, the SQL nodes are no longer patched on a schedule by Update Manager.
    -RemoveWindowsUpdatePolicy also reverts the Windows Update policy on the nodes
    (Microsoft Update registration and the "notify only" setting).

.EXAMPLE
    .\scripts\patching\Disable-SqlAgPatching.ps1
#>
[CmdletBinding()]
param(
    [string]$EnvironmentName,
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$ArcResourceGroup,
    [string]$PatchingResourceGroup,
    [string]$AutomationAccountName = 'aa-sql-ag-patching',
    [string[]]$Nodes = @('SQL-VM-1', 'SQL-VM-2'),
    [switch]$KeepAutomationAccount,
    [switch]$RemoveWindowsUpdatePolicy,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\arc\ArcEvalCommon.ps1')
. (Join-Path $PSScriptRoot 'runbooks\SqlAgPatchCommon.ps1')
function Write-Log([string]$Message) { Write-Info $Message }

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$automationApi = '2023-11-01'

$azdEnv = Get-AzdEnvironmentValues -RepoRoot $repoRoot -EnvironmentName $EnvironmentName
if (-not $SubscriptionId) { $SubscriptionId = $azdEnv['AZURE_SUBSCRIPTION_ID'] }
if (-not $ResourceGroup) { $ResourceGroup = $azdEnv['AZURE_RESOURCE_GROUP'] }
if (-not $ArcResourceGroup) {
    if (-not $ResourceGroup) { throw 'Provide -ArcResourceGroup (or -ResourceGroup / an azd environment with AZURE_RESOURCE_GROUP).' }
    $ArcResourceGroup = "$ResourceGroup-arc"
}
if (-not $PatchingResourceGroup) { $PatchingResourceGroup = $ArcResourceGroup }

$account = Invoke-Az @('account', 'show') -Json
if ($SubscriptionId -and $account.id -ne $SubscriptionId) {
    Invoke-Az @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
    $account = Invoke-Az @('account', 'show') -Json
}
$SubscriptionId = $account.id
$rgPath = "/subscriptions/$SubscriptionId/resourceGroups/$PatchingResourceGroup"

# Maintenance configurations created by Enable-SqlAgPatching.ps1 carry the SqlAgTarget tag.
$configs = @((Invoke-Arm -Path "$rgPath/providers/Microsoft.Maintenance/maintenanceConfigurations?api-version=$($script:MaintenanceApi)").value |
    Where-Object { $_ -and $_.tags.SqlAgTarget })

Write-Section 'Removing AG-aware patching'
Write-Info "Patching RG : $PatchingResourceGroup"
Write-Info "Configs     : $(if ($configs) { ($configs.name) -join ', ' } else { 'none' })"
Write-Info "Automation  : $(if ($KeepAutomationAccount) { "keep $AutomationAccountName" } else { "delete $AutomationAccountName" })"
if (-not $Force) {
    $answer = Read-Host 'Type YES to remove the patching schedules and automation'
    if ($answer -cne 'YES') { Write-Host 'Aborted.'; return }
}

$aaPath = "$rgPath/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName"
$aa = Invoke-Arm -Path "${aaPath}?api-version=$automationApi" -AllowNotFound
$principalId = if ($aa) { $aa.identity.principalId } else { $null }

# Remove every role assignment of the runbook identity (configurations, Arc SQL instances, machines).
if ($principalId) {
    Write-Section 'Managed identity role assignments'
    $assignments = Invoke-Az @('role', 'assignment', 'list', '--assignee', $principalId, '--all') -Json
    foreach ($ra in @($assignments | Where-Object { $_ })) {
        Invoke-Az @('role', 'assignment', 'delete', '--ids', $ra.id) -AllowFailure | Out-Null
        Write-Ok "Removed $($ra.roleDefinitionName) on $(($ra.scope -split '/')[-1])"
    }
}

foreach ($mc in $configs) {
    Write-Section "Configuration $($mc.name)"
    $topicName = "st-$($mc.name)"
    $topic = Invoke-Az @('eventgrid', 'system-topic', 'show', '-g', $PatchingResourceGroup, '-n', $topicName) -Json -AllowFailure
    if ($topic) {
        Invoke-Az @('eventgrid', 'system-topic', 'delete', '-g', $PatchingResourceGroup, '-n', $topicName, '--yes') | Out-Null
        Write-Ok "Deleted system topic $topicName (and its event subscriptions)"
    }

    $target = $mc.tags.SqlAgTarget
    $machineRg = if ($mc.tags.SqlAgMachineResourceGroup) { $mc.tags.SqlAgMachineResourceGroup } else { $ArcResourceGroup }
    $machineId = "/subscriptions/$SubscriptionId/resourceGroups/$machineRg/providers/Microsoft.HybridCompute/machines/$target"
    Invoke-Arm -Method DELETE -Path "$machineId/providers/Microsoft.Maintenance/configurationAssignments/$($mc.name)?api-version=$($script:MaintenanceApi)" -AllowNotFound | Out-Null
    Write-Ok "Removed assignment of $target"

    Invoke-Arm -Method DELETE -Path "$($mc.id)?api-version=$($script:MaintenanceApi)" -AllowNotFound | Out-Null
    Write-Ok "Deleted maintenance configuration $($mc.name)"
}

if ($aa -and -not $KeepAutomationAccount) {
    Write-Section "Automation account $AutomationAccountName"
    Invoke-Arm -Method DELETE -Path "${aaPath}?api-version=$automationApi" -AllowNotFound | Out-Null
    Write-Ok 'Deleted (runbooks, webhooks and job history included)'
}

if ($RemoveWindowsUpdatePolicy) {
    Write-Section 'Reverting Windows Update policy on the nodes'
    $wuScript = "& {`n" + [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Set-WindowsUpdatePolicy.ps1')) + "`n} -Remove"
    foreach ($node in $Nodes) {
        $m = Invoke-Arm -Path "/subscriptions/$SubscriptionId/resourceGroups/$ArcResourceGroup/providers/Microsoft.HybridCompute/machines/${node}?api-version=$($script:HybridComputeApi)" -AllowNotFound
        if (-not $m -or $m.properties.status -ne 'Connected') { Write-Warn "$node is not a connected Arc machine; skipped."; continue }
        $iv = Invoke-ArcRunCommand -MachineId $m.id -Location $m.location -Name 'sqlagpatch-wupolicy-remove' -Script $wuScript -TimeoutSeconds 300
        $line = @(([string]$iv.output) -split "`r?`n" | Where-Object { $_ -like 'WUPOLICY:*' }) | Select-Object -Last 1
        if ($line) { Write-Ok $line.Substring(10) } else { Write-Warn "${node}: $($iv.output) $($iv.error)" }
    }
}

Write-Section 'Done'
Write-Info 'The SQL nodes are no longer patched by these schedules. Patch them manually (secondary first) or re-run Enable-SqlAgPatching.ps1.'
