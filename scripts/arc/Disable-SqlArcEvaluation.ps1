<#
.SYNOPSIS
    Reverts Enable-SqlArcEvaluation.ps1: removes the Arc SQL extension and Arc resources,
    uninstalls the Connected Machine agent, re-enables the Azure VM guest agent and
    re-registers the SQL IaaS Agent extension.

.DESCRIPTION
    Uses Arc Run Command (the Azure VM Run Command is unavailable while the guest agent is
    disabled) to start Remove-ArcAgentOnVm.ps1 as a one-time SYSTEM scheduled task, then waits
    for the Azure VM agent to report Ready before deleting the Arc machine resource.

    If a VM is not reachable through Arc, RDP to it and run scripts\arc\Remove-ArcAgentOnVm.ps1
    from an elevated PowerShell, then rerun this script to clean up Azure resources.

.EXAMPLE
    .\scripts\arc\Disable-SqlArcEvaluation.ps1
#>
[CmdletBinding()]
param(
    [string]$EnvironmentName,
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string[]]$VmNames = @('SQL-VM-1', 'SQL-VM-2'),
    [string]$ArcResourceGroup,
    [string]$Location,
    [switch]$SkipSqlIaasRegistration,
    [int]$TimeoutMinutes = 20,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ArcEvalCommon.ps1')

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$removeScript = Join-Path $PSScriptRoot 'Remove-ArcAgentOnVm.ps1'
$taskName = 'ArcEvalOffboard'

$azdEnv = Get-AzdEnvironmentValues -RepoRoot $repoRoot -EnvironmentName $EnvironmentName
if (-not $SubscriptionId) { $SubscriptionId = $azdEnv['AZURE_SUBSCRIPTION_ID'] }
if (-not $ResourceGroup) { $ResourceGroup = $azdEnv['AZURE_RESOURCE_GROUP'] }
if (-not $Location) { $Location = $azdEnv['AZURE_LOCATION'] }
if (-not $ResourceGroup) { throw 'ResourceGroup not provided and AZURE_RESOURCE_GROUP not found in the azd environment.' }

$account = Invoke-Az @('account', 'show') -Json
if ($SubscriptionId -and $account.id -ne $SubscriptionId) {
    Invoke-Az @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
}
if (-not $Location) { $Location = (Invoke-Az @('group', 'show', '-n', $ResourceGroup) -Json).location }
if (-not $ArcResourceGroup) { $ArcResourceGroup = "$ResourceGroup-arc" }

Write-Section 'Reverting Azure Arc evaluation'
Write-Info "VM RG  : $ResourceGroup"
Write-Info "Arc RG : $ArcResourceGroup"
Write-Info "VMs    : $($VmNames -join ', ')"
if (-not $Force) {
    $answer = Read-Host 'Type YES to remove the Arc resources and restore the Azure VM agent'
    if ($answer -cne 'YES') { Write-Host 'Aborted.'; return }
}

Invoke-Az @('extension', 'add', '--name', 'connectedmachine', '--upgrade') | Out-Null

function Get-VmAgentStatus([string]$Name) {
    $view = Invoke-Az @('vm', 'get-instance-view', '-g', $ResourceGroup, '-n', $Name) -Json
    ($view.instanceView.vmAgent.statuses | Select-Object -First 1).displayStatus
}

$failed = @()
foreach ($vm in $VmNames) {
    Write-Section "Reverting $vm"
    $machine = Invoke-Az @('connectedmachine', 'show', '-g', $ArcResourceGroup, '-n', $vm) -Json -AllowFailure

    if ($machine) {
        # SQL Server - Azure Arc resources and the SQL extension
        $sqlInstances = Invoke-Az @('resource', 'list', '-g', $ArcResourceGroup,
            '--resource-type', 'Microsoft.AzureArcData/sqlServerInstances') -Json
        foreach ($ext in @(Invoke-Az @('connectedmachine', 'extension', 'list', '-g', $ArcResourceGroup,
                '--machine-name', $vm) -Json)) {
            if (-not $ext) { continue }
            Write-Info "Removing Arc extension $($ext.name)..."
            Invoke-Az @('connectedmachine', 'extension', 'delete', '-g', $ArcResourceGroup,
                '--machine-name', $vm, '-n', $ext.name, '--yes') -AllowFailure | Out-Null
        }
        foreach ($inst in @($sqlInstances)) {
            if (-not $inst) { continue }
            $props = (Invoke-Az @('resource', 'show', '--ids', $inst.id) -Json).properties
            if ($props.containerResourceId -and $props.containerResourceId -ieq $machine.id) {
                Write-Info "Removing SQL Server - Azure Arc resource $($inst.name)..."
                Invoke-Az @('resource', 'delete', '--ids', $inst.id) -AllowFailure | Out-Null
            }
        }
    }

    if ((Get-VmAgentStatus $vm) -ne 'Ready') {
        if (-not $machine -or $machine.status -ne 'Connected') {
            Write-Warn "$vm is not connected to Arc and its Azure VM agent is not Ready. RDP to the VM and run scripts\arc\Remove-ArcAgentOnVm.ps1, then rerun this script."
            $failed += $vm
            continue
        }

        Write-Info 'Starting offboarding task on the VM via Arc Run Command...'
        $wrapperPath = Join-Path ([IO.Path]::GetTempPath()) "arc-offboard-$vm-$([guid]::NewGuid().ToString('N')).ps1"
        try {
            [IO.File]::WriteAllText($wrapperPath,
                (New-VmScheduledTaskWrapper -PayloadPath $removeScript -TaskName $taskName -Config @{ InitialDelaySeconds = 60 }),
                (New-Object Text.UTF8Encoding $false))
            Invoke-Az @('connectedmachine', 'run-command', 'create', '-g', $ArcResourceGroup, '--machine-name', $vm,
                '-n', $taskName, '--location', $Location, '--script', "@$wrapperPath") | Out-Null
        }
        finally { Remove-Item $wrapperPath -Force -ErrorAction SilentlyContinue }
        Write-Ok "Offboarding task started on $vm (log: C:\ArcEval\arc-offboard.log)"

        $ready = Wait-Until -Description "$vm Azure VM agent to report Ready" -TimeoutMinutes $TimeoutMinutes -Condition {
            (Get-VmAgentStatus $vm) -eq 'Ready'
        }
        if (-not $ready) {
            Write-Warn "$vm Azure VM agent did not become Ready. RDP to the VM and check C:\ArcEval\arc-offboard.log."
            $failed += $vm
            continue
        }
    }
    Write-Ok "$vm Azure VM agent is Ready"

    if ($machine) {
        Write-Info 'Deleting Arc machine resource...'
        Invoke-Az @('connectedmachine', 'delete', '-g', $ArcResourceGroup, '-n', $vm, '--yes') | Out-Null
        Write-Ok "Arc machine $vm deleted"
    }

    if (-not $SkipSqlIaasRegistration) {
        $sqlVm = Invoke-Az @('sql', 'vm', 'show', '-g', $ResourceGroup, '-n', $vm) -Json -AllowFailure
        if (-not $sqlVm) {
            Write-Info 'Re-registering SQL IaaS Agent extension...'
            Invoke-Az @('sql', 'vm', 'create', '-g', $ResourceGroup, '-n', $vm, '--location', $Location,
                '--license-type', 'PAYG', '--sql-mgmt-type', 'Full') | Out-Null
        }
        Write-Ok 'SQL IaaS Agent registered'
    }
}

Write-Section 'Summary'
if ($failed.Count -gt 0) {
    Write-Warn "Incomplete: $($failed -join ', ')"
    exit 1
}
Write-Ok "Reverted. The (now empty) resource group '$ArcResourceGroup' was left in place; delete it with: az group delete -n $ArcResourceGroup"
