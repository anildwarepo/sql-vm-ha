# Shared code for the SQL AG patching runbooks.
# Enable-SqlAgPatching.ps1 inlines this file into each runbook at the '# <<SqlAgPatchCommon>>' marker,
# because Azure Automation runbooks cannot dot-source other files.
# Compatible with Windows PowerShell 5.1 (Automation sandbox) and PowerShell 7 (local testing).
# AG state and failover use the SQL Server enabled by Azure Arc availability group API (ARM only):
#   POST .../sqlServerInstances/{instance}/availabilityGroups/{ag}/getDetailView
#   POST .../sqlServerInstances/{instance}/availabilityGroups/{ag}/failover
# Functions that log (Write-Output) return their result in $script:NodeResult instead of the pipeline.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$script:HybridComputeApi = '2026-07-15'
$script:MaintenanceApi = '2023-04-01'
$script:ApplyUpdatesApi = '2023-09-01-preview'
$script:ArcDataApi = '2026-01-01'
$script:ArmToken = $null
$script:ArmTokenExpires = [datetime]::MinValue
$script:NodeResult = $null

function Write-Log([string]$Message) {
    Write-Output ('{0:u} {1}' -f [datetime]::UtcNow, $Message)
}

function Get-ArmToken {
    if ($script:ArmToken -and [datetime]::UtcNow -lt $script:ArmTokenExpires) { return $script:ArmToken }
    if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
        # Automation account system-assigned managed identity
        $r = Invoke-RestMethod -Method Get -Uri "$($env:IDENTITY_ENDPOINT)?resource=https://management.azure.com/" `
            -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER; 'Metadata' = 'True' }
        $script:ArmToken = $r.access_token
    }
    else {
        # Local testing: use the signed-in az CLI account
        $script:ArmToken = (& az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv)
        if (-not $script:ArmToken) { throw 'No managed identity endpoint and no az CLI login available.' }
    }
    $script:ArmTokenExpires = [datetime]::UtcNow.AddMinutes(30)
    return $script:ArmToken
}

function Invoke-Arm {
    param(
        [string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Path,
        [object]$Body,
        [switch]$AllowNotFound
    )
    $uri = if ($Path -like 'https://*') { $Path } else { "https://management.azure.com$Path" }
    $request = @{
        Method  = $Method
        Uri     = $uri
        Headers = @{ Authorization = "Bearer $(Get-ArmToken)" }
    }
    if ($null -ne $Body) {
        $request.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
        $request.ContentType = 'application/json'
    }
    elseif ($Method -in 'POST', 'PUT', 'PATCH') {
        # ARM rejects bodiless POSTs without Content-Length (Windows PowerShell 5.1 omits it)
        $request.Body = '{}'
        $request.ContentType = 'application/json'
    }
    try {
        return Invoke-RestMethod @request
    }
    catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($AllowNotFound -and $status -eq 404) { return $null }
        throw "ARM $Method $uri failed ($status): $($_.ErrorDetails.Message) $($_.Exception.Message)"
    }
}

function ConvertTo-UtcDateTime($Value) {
    # Event Grid timestamps are ISO 8601 UTC strings (PowerShell 7's ConvertFrom-Json turns them into DateTime).
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { return $parsed }
    return $null
}

function Get-MaintenanceEvent {
    # Returns the first Event Grid event of the requested type from the webhook payload, or $null.
    param([object]$WebhookData, [Parameter(Mandatory)][string]$EventType)
    if ($WebhookData -is [string]) { $WebhookData = $WebhookData | ConvertFrom-Json }
    if (-not $WebhookData -or -not $WebhookData.RequestBody) {
        throw 'This runbook must be started by its Event Grid webhook (WebhookData.RequestBody is empty).'
    }
    $parsed = $WebhookData.RequestBody | ConvertFrom-Json
    # foreach unrolls both a single event and an array of events (PowerShell 5.1 returns arrays unenumerated)
    foreach ($evt in $parsed) {
        if ($evt.eventType -eq $EventType) { return $evt }
    }
    return $null
}

function Get-PatchContext {
    # Reads the maintenance configuration named in the event. Its SqlAg* tags (written by
    # Enable-SqlAgPatching.ps1) describe which node this wave patches and who its partner is.
    param([Parameter(Mandatory)]$MaintenanceEvent)
    $mcId = [string]$MaintenanceEvent.data.MaintenanceConfigurationId
    if (-not $mcId) { throw 'Event has no data.MaintenanceConfigurationId.' }
    $mc = Invoke-Arm -Path "${mcId}?api-version=$($script:MaintenanceApi)"
    $tags = $mc.tags
    foreach ($required in 'SqlAgTarget', 'SqlAgPartner', 'SqlAgName', 'SqlAgMachineResourceGroup') {
        if (-not $tags.$required) { throw "Maintenance configuration $mcId is missing tag '$required'." }
    }
    return [pscustomobject]@{
        MaintenanceConfigurationId = $mcId
        CorrelationId              = [string]$MaintenanceEvent.data.CorrelationId
        StartDateTime              = [string]$MaintenanceEvent.data.StartDateTime
        CancellationCutOff         = [string]$MaintenanceEvent.data.CancellationCutOffDateTime
        Status                     = [string]$MaintenanceEvent.data.Status
        SubscriptionId             = ($mcId -split '/')[2]
        MachineResourceGroup       = [string]$tags.SqlAgMachineResourceGroup
        Target                     = [string]$tags.SqlAgTarget
        Partner                    = [string]$tags.SqlAgPartner
        AgName                     = [string]$tags.SqlAgName
        PreferredPrimary           = [string]$tags.SqlAgPreferredPrimary
        # Arc SQL instance resource names; default instances are named after the machine
        Instances                  = @{
            ([string]$tags.SqlAgTarget)  = $(if ($tags.SqlAgTargetInstance) { [string]$tags.SqlAgTargetInstance } else { [string]$tags.SqlAgTarget })
            ([string]$tags.SqlAgPartner) = $(if ($tags.SqlAgPartnerInstance) { [string]$tags.SqlAgPartnerInstance } else { [string]$tags.SqlAgPartner })
        }
    }
}

function Stop-MaintenanceRun {
    # Cancels this maintenance run (only works before CancellationCutOffDateTime).
    param([Parameter(Mandatory)]$Context, [string]$Reason)
    if (-not $Context.CorrelationId) { Write-Log 'No CorrelationId in the event; cannot cancel.'; return }
    Write-Log "Cancelling maintenance run $($Context.CorrelationId): $Reason"
    try {
        Invoke-Arm -Method PUT -Path "$($Context.CorrelationId)?api-version=$($script:ApplyUpdatesApi)" `
            -Body @{ properties = @{ status = 'Cancel' } } | Out-Null
        Write-Log 'Maintenance run cancelled. The node will not be patched in this window.'
    }
    catch {
        Write-Log "ERROR: cancellation failed (cut-off was $($Context.CancellationCutOff)): $($_.Exception.Message)"
    }
}

function Invoke-ArcRunCommand {
    # Runs a script on an Arc machine with Arc Run Command, waits, deletes the run command and
    # returns its instanceView (executionState, exitCode, output, error). Does not write output.
    param(
        [Parameter(Mandatory)][string]$MachineId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Script,
        [hashtable]$Parameters = @{},
        [int]$TimeoutSeconds = 600
    )
    $rcPath = "$MachineId/runCommands/${Name}?api-version=$($script:HybridComputeApi)"
    $body = @{
        location   = $Location
        properties = @{
            source           = @{ script = $Script }
            parameters       = @($Parameters.Keys | ForEach-Object { @{ name = $_; value = [string]$Parameters[$_] } })
            timeoutInSeconds = $TimeoutSeconds
            asyncExecution   = $false
        }
    }
    Invoke-Arm -Method PUT -Path $rcPath -Body $body | Out-Null
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds + 240)
    do {
        Start-Sleep -Seconds 10
        $rc = Invoke-Arm -Path $rcPath
        $state = [string]$rc.properties.provisioningState
        $exec = [string]$rc.properties.instanceView.executionState
        # provisioningState can report Succeeded briefly before the instance view is filled in
        $done = ($state -in 'Failed', 'Canceled') -or
            ($state -eq 'Succeeded' -and $exec -in 'Succeeded', 'Failed', 'TimedOut', 'Canceled')
    } while (-not $done -and (Get-Date) -lt $deadline)
    try { Invoke-Arm -Method DELETE -Path $rcPath -AllowNotFound | Out-Null } catch { }
    $iv = $rc.properties.instanceView
    if (-not $iv) { $iv = [pscustomobject]@{ executionState = $state; exitCode = $null; output = ''; error = "Run command ended in state '$state'." } }
    return $iv
}

function Get-ArcSqlInstanceId {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Machine)
    $name = $Machine
    if ($Context.Instances -and $Context.Instances[$Machine]) { $name = $Context.Instances[$Machine] }
    return "/subscriptions/$($Context.SubscriptionId)/resourceGroups/$($Context.MachineResourceGroup)/providers/Microsoft.AzureArcData/sqlServerInstances/$name"
}

function Write-SqlAgState($State) {
    Write-Log ("AG state on {0}: role={1} mode={2} connected={3} health={4} healthy={5} failoverReady={6} (collected {7:HH:mm:ss}Z){8}" -f
        $State.machine, $State.role, $State.mode, $State.connected, $State.replicaHealth, $State.healthy, $State.failoverReady,
        $State.collected, $(if ($State.message) { " - $($State.message)" } else { '' }))
    foreach ($db in @($State.databases)) {
        if ($db) { Write-Log ("  {0} @ {1}: {2} / {3}" -f $db.databaseName, $db.replicaName, $db.synchronizationStateDescription, $db.synchronizationHealthDescription) }
    }
}

function Get-SqlAgState {
    # Reads live AG state for the instance on $Machine with the Arc getDetailView API.
    # The result is stored in $script:NodeResult. A secondary only reports its own replica and databases.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Machine, [switch]$Quiet)
    $script:NodeResult = $null
    $requestedUtc = [datetime]::UtcNow.AddSeconds(-60)
    $view = Invoke-Arm -Method POST -Path "$(Get-ArcSqlInstanceId $Context $Machine)/availabilityGroups/$($Context.AgName)/getDetailView?api-version=$($script:ArcDataApi)"
    $p = $view.properties
    $replicas = @($p.replicas.value | Where-Object { $_ })
    $databases = @($p.databases.value | Where-Object { $_ })

    $localName = ($databases | Where-Object { $_.isLocal } | Select-Object -First 1).replicaName
    if (-not $localName) { $localName = [string]$p.serverName }
    $local = $replicas | Where-Object { $_.replicaName -eq $localName } | Select-Object -First 1

    $s = [ordered]@{
        machine       = $Machine
        replica       = [string]$localName
        role          = [string]$local.state.availabilityGroupReplicaRole
        mode          = [string]$local.configure.availabilityModeDescription
        connected     = [string]$local.state.connectedStateDescription
        replicaHealth = [string]$local.state.synchronizationHealthDescription
        collected     = ConvertTo-UtcDateTime $p.collectionTimestamp
        replicas      = $replicas
        databases     = $databases
        fresh         = $false
        healthy       = $false
        failoverReady = $false
        message       = ''
    }

    # The primary sees every replica and database; a secondary only its own.
    $modeOf = @{}
    foreach ($r in $replicas) { $modeOf[[string]$r.replicaName] = [string]$r.configure.availabilityModeDescription }
    $checked = if ($s.role -eq 'PRIMARY') { $databases } else { @($databases | Where-Object { $_.isLocal }) }
    $bad = @($checked | Where-Object {
            $m = $modeOf[[string]$_.replicaName]
            ($_.isSuspended -eq $true) -or
            ($m -eq 'SYNCHRONOUS_COMMIT' -and $_.synchronizationStateDescription -ne 'SYNCHRONIZED') -or
            ($m -ne 'SYNCHRONOUS_COMMIT' -and $_.synchronizationStateDescription -notin 'SYNCHRONIZED', 'SYNCHRONIZING')
        })
    $disconnected = @($replicas | Where-Object { $_.state.connectedStateDescription -ne 'CONNECTED' })

    # getDetailView queries the instance through the Arc SQL extension; an old timestamp means cached data.
    $s.fresh = [bool]($s.collected -and $s.collected -ge $requestedUtc)
    if (-not $s.fresh) { $s.message = "stale data (collected $($s.collected))" }
    elseif ($s.role -notin 'PRIMARY', 'SECONDARY') { $s.message = "replica role is '$($s.role)'" }
    elseif ($s.connected -ne 'CONNECTED') { $s.message = "replica is $($s.connected)" }
    elseif ($s.replicaHealth -ne 'HEALTHY') { $s.message = "replica synchronization health is $($s.replicaHealth)" }
    elseif (@($databases | Where-Object { $_.isLocal }).Count -eq 0) { $s.message = 'no local availability databases' }
    elseif ($bad.Count -gt 0) { $s.message = "$($bad.Count) database copies not synchronized or suspended" }
    elseif ($s.role -eq 'PRIMARY' -and $disconnected.Count -gt 0) { $s.message = "$($disconnected.Count) replicas not connected" }
    else { $s.healthy = $true }

    # A planned (no data loss) failover target must be a healthy synchronous-commit secondary.
    $s.failoverReady = $s.healthy -and $s.role -eq 'SECONDARY' -and $s.mode -eq 'SYNCHRONOUS_COMMIT'
    $script:NodeResult = [pscustomobject]$s
    if (-not $Quiet) { Write-SqlAgState $script:NodeResult }
}

function Wait-SqlAgHealthy {
    # Polls until the instance on $Machine is healthy (and failover-ready if it is a synchronous secondary).
    # Errors while the host reboots or the Arc SQL extension reconnects are retried until the timeout.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Machine, [Parameter(Mandatory)][int]$TimeoutSeconds)
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    $last = ''
    while ($true) {
        try {
            Get-SqlAgState -Context $Context -Machine $Machine -Quiet
            $st = $script:NodeResult
            if ($st.healthy -and ($st.role -ne 'SECONDARY' -or $st.mode -ne 'SYNCHRONOUS_COMMIT' -or $st.failoverReady)) {
                Write-SqlAgState $st
                return
            }
            $last = "role=$($st.role), $($st.message)"
        }
        catch { $last = $_.Exception.Message }
        if ([datetime]::UtcNow -ge $deadline) {
            $script:NodeResult = $null
            throw "$Machine is not healthy after $TimeoutSeconds seconds: $last"
        }
        Write-Log "Waiting for $Machine to be healthy: $last"
        Start-Sleep -Seconds 20
    }
}

function Invoke-SqlAgFailover {
    # Planned failover of the AG to the instance on $Machine with the Arc failover API.
    # The API currently answers HTTP 400 "Failover retrieve null resource" even when the failover
    # succeeds, so the outcome is always verified with getDetailView. Result in $script:NodeResult.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Machine, [int]$TimeoutSeconds = 180)
    Get-SqlAgState -Context $Context -Machine $Machine
    $st = $script:NodeResult
    if ($st.role -eq 'PRIMARY') { Write-Log "$Machine is already the primary replica; no failover needed."; return }
    if (-not $st.failoverReady) { throw "$Machine is not ready for a planned failover: role=$($st.role), mode=$($st.mode), $($st.message)" }

    Write-Log "Requesting failover of $($Context.AgName) to $Machine..."
    try {
        Invoke-Arm -Method POST -Path "$(Get-ArcSqlInstanceId $Context $Machine)/availabilityGroups/$($Context.AgName)/failover?api-version=$($script:ArcDataApi)" | Out-Null
    }
    catch {
        if ($_.Exception.Message -notmatch 'Failover retrieve null resource') { throw }
        Write-Log 'Failover API returned "Failover retrieve null resource" (known response); verifying the outcome...'
    }

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        Start-Sleep -Seconds 10
        try { Get-SqlAgState -Context $Context -Machine $Machine -Quiet; $st = $script:NodeResult } catch { $st = $null }
        if ($st -and $st.role -eq 'PRIMARY') { break }
        if ([datetime]::UtcNow -ge $deadline) { throw "Failover to $Machine was requested but it is not the primary after $TimeoutSeconds seconds." }
    }
    Write-Log "Failover complete: $Machine is the primary replica."
    Write-SqlAgState $st
}

function Get-SqlPatchLevel {
    # SQL Server build from the Arc SQL instance inventory (refreshed by the extension, may lag after a CU).
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Machine)
    try {
        $i = Invoke-Arm -Path "$(Get-ArcSqlInstanceId $Context $Machine)?api-version=$($script:ArcDataApi)"
        return "$($i.properties.version) $($i.properties.edition), build $($i.properties.patchLevel)"
    }
    catch { return 'unknown' }
}