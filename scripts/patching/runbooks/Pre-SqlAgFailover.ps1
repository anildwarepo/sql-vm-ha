<#
.SYNOPSIS
    Azure Update Manager pre-maintenance runbook for a SQL Server Always On AG node.

.DESCRIPTION
    Started by an Event Grid webhook (Microsoft.Maintenance.PreMaintenanceEvent) about 30-40 minutes
    before a maintenance configuration's window opens. The configuration's tags name the node that will
    be patched (SqlAgTarget) and its AG partner (SqlAgPartner).

      - Partner is already PRIMARY  -> nothing to do; the target is a secondary and can be patched.
      - Partner is SECONDARY        -> planned (no data loss) failover of the AG to the partner.
      - Anything else (partner offline, not synchronized, failover fails) -> the maintenance run is
        cancelled so the node that hosts the primary replica is never rebooted.

    AG state and failover use the Arc availability group API (getDetailView / failover); no Run Command or T-SQL.

    Must finish within 20 minutes. Idempotent, because Event Grid may deliver an event more than once.
#>
param(
    [Parameter(Mandatory = $false)]
    [object]$WebhookData
)

# <<SqlAgPatchCommon>>

$evt = Get-MaintenanceEvent -WebhookData $WebhookData -EventType 'Microsoft.Maintenance.PreMaintenanceEvent'
if (-not $evt) {
    Write-Log 'No PreMaintenanceEvent in the payload (validation or unrelated event); nothing to do.'
    return
}

# Enough to cancel even if reading the maintenance configuration fails.
$cancelCtx = [pscustomobject]@{
    CorrelationId      = [string]$evt.data.CorrelationId
    CancellationCutOff = [string]$evt.data.CancellationCutOffDateTime
}
# Patching can only be cancelled before the cut-off; keep 2 minutes in reserve for the cancel call.
$cutOffUtc = ConvertTo-UtcDateTime $evt.data.CancellationCutOffDateTime
if (-not $cutOffUtc) { $cutOffUtc = [datetime]::UtcNow.AddMinutes(15) }
function Get-SecondsLeft { [int](($cutOffUtc - [datetime]::UtcNow).TotalSeconds - 120) }

try {
    $ctx = Get-PatchContext -MaintenanceEvent $evt
    $cancelCtx = $ctx
    Write-Log ("Pre-maintenance: config={0} run={1} start={2} cancelCutOff={3}" -f $ctx.MaintenanceConfigurationId, $ctx.CorrelationId, $ctx.StartDateTime, $ctx.CancellationCutOff)
    Write-Log ("Target (to be patched)={0} partner={1} AG={2}" -f $ctx.Target, $ctx.Partner, $ctx.AgName)

    Get-SqlAgState -Context $ctx -Machine $ctx.Partner
    $partner = $script:NodeResult
    if (-not $partner.fresh) { throw "Could not read current AG state of $($ctx.Partner): $($partner.message)" }

    if ($partner.role -eq 'PRIMARY') {
        Write-Log "$($ctx.Partner) is already the primary replica. $($ctx.Target) is a secondary and is safe to patch."
    }
    elseif ($partner.role -eq 'SECONDARY') {
        if (-not $partner.failoverReady) {
            # e.g. the partner was patched in the previous wave and is still catching up.
            # Leave ~4 minutes after the wait for the failover and its verification.
            $wait = [Math]::Min(600, (Get-SecondsLeft) - 240)
            if ($wait -lt 60) { throw "$($ctx.Partner) is not failover-ready and there is no time left to wait before the cancellation cut-off." }
            Write-Log "$($ctx.Partner) is not failover-ready yet ($($partner.message)); waiting up to $wait seconds..."
            Wait-SqlAgHealthy -Context $ctx -Machine $ctx.Partner -TimeoutSeconds $wait
            $partner = $script:NodeResult
        }
        if (-not $partner.failoverReady) {
            throw "$($ctx.Partner) is SECONDARY but not failover-ready; refusing to patch the primary."
        }
        if ((Get-SecondsLeft) -lt 180) { throw 'Not enough time left before the cancellation cut-off to fail over safely.' }
        Write-Log "$($ctx.Target) hosts the primary replica. Failing $($ctx.AgName) over to $($ctx.Partner)..."
        Invoke-SqlAgFailover -Context $ctx -Machine $ctx.Partner -TimeoutSeconds ([Math]::Min(180, (Get-SecondsLeft)))
        Write-Log "$($ctx.Partner) is primary; $($ctx.Target) will be patched as a secondary."
    }
    else {
        throw "$($ctx.Partner) has unexpected AG role '$($partner.role)'."
    }
}
catch {
    $reason = $_.Exception.Message
    Write-Log "ERROR: $reason"
    Stop-MaintenanceRun -Context $cancelCtx -Reason $reason
    throw
}