<#
.SYNOPSIS
    Azure Update Manager post-maintenance runbook for a SQL Server Always On AG node.

.DESCRIPTION
    Started by an Event Grid webhook (Microsoft.Maintenance.PostMaintenanceEvent) when a maintenance
    window finishes. Validates the node that was just patched (SqlAgTarget tag):

      - waits (up to 45 minutes) until the Arc SQL extension reports the AG replica connected and synchronized,
      - logs the SQL Server build from the Arc SQL inventory,
      - optionally fails the AG back when the patched node is the preferred primary (SqlAgPreferredPrimary).

    The job fails (visible in the Automation account and alertable) if the node does not become healthy.
    An unhealthy node also makes the next wave's pre-maintenance runbook cancel that wave, because the
    partner will not be failover-ready.
#>
param(
    [Parameter(Mandatory = $false)]
    [object]$WebhookData
)

# <<SqlAgPatchCommon>>

$evt = Get-MaintenanceEvent -WebhookData $WebhookData -EventType 'Microsoft.Maintenance.PostMaintenanceEvent'
if (-not $evt) {
    Write-Log 'No PostMaintenanceEvent in the payload (validation or unrelated event); nothing to do.'
    return
}

$ctx = Get-PatchContext -MaintenanceEvent $evt
Write-Log ("Post-maintenance: config={0} run={1} status={2}" -f $ctx.MaintenanceConfigurationId, $ctx.CorrelationId, $ctx.Status)
Write-Log ("Validating patched node {0} (partner {1}, AG {2})" -f $ctx.Target, $ctx.Partner, $ctx.AgName)

if ($ctx.Status -eq 'Canceled' -or $ctx.Status -eq 'Cancelled') {
    Write-Log 'The maintenance run was cancelled; validating current state only.'
}

# The node may still be rebooting and the Arc SQL extension reconnecting; allow 45 minutes in total.
Wait-SqlAgHealthy -Context $ctx -Machine $ctx.Target -TimeoutSeconds 2700
$target = $script:NodeResult
Write-Log ("{0} is healthy: role={1}; {2}." -f $ctx.Target, $target.role, (Get-SqlPatchLevel -Context $ctx -Machine $ctx.Target))

if ($ctx.PreferredPrimary -and $ctx.PreferredPrimary -eq $ctx.Target -and $target.role -eq 'SECONDARY') {
    if ($target.failoverReady) {
        Write-Log "$($ctx.Target) is the preferred primary. Failing $($ctx.AgName) back to it..."
        Invoke-SqlAgFailover -Context $ctx -Machine $ctx.Target
    }
    else {
        Write-Log "WARNING: $($ctx.Target) is the preferred primary but not failover-ready; leaving the AG on $($ctx.Partner)."
    }
}

Write-Log 'Post-maintenance validation complete.'