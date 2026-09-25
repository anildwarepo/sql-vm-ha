<#
.SYNOPSIS
    Sets up availability-group-aware patching for the Arc-enabled SQL nodes with Azure Update Manager.

.DESCRIPTION
    Creates (idempotently):
      - an Azure Automation account with a system-assigned managed identity,
      - two PowerShell runbooks: Pre-SqlAgFailover and Post-SqlAgValidate,
      - one Update Manager maintenance configuration per node ("waves"), staggered so the nodes
        are never patched at the same time; tags on each configuration tell the runbooks which
        node is patched and who its AG partner is,
      - an assignment of each Arc machine to its configuration,
      - role assignments for the managed identity (Arc SQL AG API on the SQL instances, cancel on the configurations),
      - two webhooks and, per configuration, an Event Grid system topic with pre/post event subscriptions.

    Each wave:
      pre-event (~30-40 min before the window)  -> Pre-SqlAgFailover: if the node to patch is the
          primary, planned failover to the partner; if that is not safe, the run is cancelled.
      window                                     -> Update Manager installs Windows + SQL updates, reboots.
      post-event                                 -> Post-SqlAgValidate: waits for SQL/AG health and
          fails back if the patched node is the preferred primary.

    Unless -SkipWindowsUpdatePolicy, the nodes are also registered with Microsoft Update (needed for
    SQL Server CUs) and set to "notify only" so Windows never installs or reboots on its own.
    Unless -KeepOtherAssignments, other Update Manager schedules assigned to the nodes (for example
    "autoupdate-config") are removed, because they would patch both nodes at the same time.

.EXAMPLE
    .\scripts\patching\Enable-SqlAgPatching.ps1

.EXAMPLE
    .\scripts\patching\Enable-SqlAgPatching.ps1 -RecurEvery 'Month Second Saturday' -StartTime '22:00' -GapMinutes 120
#>
[CmdletBinding()]
param(
    [string]$EnvironmentName,
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$ArcResourceGroup,
    # Resource group for the Automation account, maintenance configurations and Event Grid topics
    [string]$PatchingResourceGroup,
    [string]$Location,
    [string]$AutomationAccountName = 'aa-sql-ag-patching',
    [string]$AvailabilityGroupName = 'ag-sql-ha',
    # Patched first. Default: the node that is normally the secondary.
    [string]$FirstNode = 'SQL-VM-2',
    [string]$SecondNode = 'SQL-VM-1',
    # After it is patched, the AG is failed back to this node. Empty = never fail back.
    [string]$PreferredPrimary = 'SQL-VM-1',
    # Update Manager recurrence, e.g. 'Week Saturday', 'Month Second Tuesday Offset4', '1Day'
    [string]$RecurEvery = 'Week Saturday',
    # First wave start (HH:mm, in -TimeZone). The second wave starts WindowDuration + GapMinutes later.
    [string]$StartTime = '01:00',
    # Date the schedules become effective (yyyy-MM-dd). Default: tomorrow.
    [string]$StartDate,
    [string]$TimeZone = 'Pacific Standard Time',
    [string]$WindowDuration = '02:00',
    [int]$GapMinutes = 90,
    [string[]]$Classifications = @('Critical', 'Security', 'UpdateRollup', 'FeaturePack', 'ServicePack', 'Definition', 'Tools', 'Updates'),
    [string[]]$ExcludeKbs = @(),
    [ValidateSet('IfRequired', 'Always', 'Never')]
    [string]$RebootSetting = 'IfRequired',
    [int]$WebhookExpiryDays = 365,
    [switch]$SkipWindowsUpdatePolicy,
    [switch]$RotateWebhooks,
    [switch]$KeepOtherAssignments,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\arc\ArcEvalCommon.ps1')
$commonPath = Join-Path $PSScriptRoot 'runbooks\SqlAgPatchCommon.ps1'
. $commonPath
# The runbook helpers log with Write-Output; keep the setup console output readable.
function Write-Log([string]$Message) { Write-Info $Message }

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$automationApi = '2023-11-01'
$webhookApi = '2015-10-31'
$preEventType = 'Microsoft.Maintenance.PreMaintenanceEvent'
$postEventType = 'Microsoft.Maintenance.PostMaintenanceEvent'
$runbooks = [ordered]@{
    'Pre-SqlAgFailover'  = @{ File = 'Pre-SqlAgFailover.ps1'; Webhook = 'wh-pre-sqlag-failover'; EventType = $preEventType; Subscription = 'pre-sqlag-failover' }
    'Post-SqlAgValidate' = @{ File = 'Post-SqlAgValidate.ps1'; Webhook = 'wh-post-sqlag-validate'; EventType = $postEventType; Subscription = 'post-sqlag-validate' }
}

# ---------------------------------------------------------------- inputs
$azdEnv = Get-AzdEnvironmentValues -RepoRoot $repoRoot -EnvironmentName $EnvironmentName
if (-not $SubscriptionId) { $SubscriptionId = $azdEnv['AZURE_SUBSCRIPTION_ID'] }
if (-not $ResourceGroup) { $ResourceGroup = $azdEnv['AZURE_RESOURCE_GROUP'] }
if (-not $ArcResourceGroup) {
    if (-not $ResourceGroup) { throw 'Provide -ArcResourceGroup (or -ResourceGroup / an azd environment with AZURE_RESOURCE_GROUP).' }
    $ArcResourceGroup = "$ResourceGroup-arc"
}
if (-not $PatchingResourceGroup) { $PatchingResourceGroup = $ArcResourceGroup }
if ($FirstNode -eq $SecondNode) { throw 'FirstNode and SecondNode must be different.' }
if ($PreferredPrimary -and $PreferredPrimary -notin $FirstNode, $SecondNode) { throw "PreferredPrimary must be '$FirstNode', '$SecondNode' or empty." }

$account = Invoke-Az @('account', 'show') -Json
if ($SubscriptionId -and $account.id -ne $SubscriptionId) {
    Invoke-Az @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
    $account = Invoke-Az @('account', 'show') -Json
}
$SubscriptionId = $account.id
if (-not $Location) { $Location = (Invoke-Az @('group', 'show', '-n', $ArcResourceGroup) -Json).location }

# ---------------------------------------------------------------- schedule
$duration = [TimeSpan]::ParseExact($WindowDuration, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture)
if ($duration -lt [TimeSpan]::FromMinutes(90) -or $duration -gt [TimeSpan]::FromMinutes(235)) {
    throw 'WindowDuration must be between 01:30 and 03:55 (Update Manager limits).'
}
if ($GapMinutes -lt 60) { throw 'GapMinutes must be at least 60 so the first node is validated before the second pre-event fires (30-40 min before its window).' }
$tz = [TimeZoneInfo]::FindSystemTimeZoneById($TimeZone)
if (-not $StartDate) { $StartDate = [TimeZoneInfo]::ConvertTimeFromUtc([datetime]::UtcNow, $tz).AddDays(1).ToString('yyyy-MM-dd') }
$wave1Start = [datetime]::ParseExact("$StartDate $StartTime", 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
$wave2Start = $wave1Start.Add($duration).AddMinutes($GapMinutes)
if ($wave2Start.Add($duration).Date -ne $wave1Start.Date) {
    throw "The second wave ($($wave2Start.ToString('HH:mm')) + $WindowDuration) crosses midnight; use an earlier -StartTime, a shorter -WindowDuration or a smaller -GapMinutes."
}
$leadMinutes = ([TimeZoneInfo]::ConvertTimeToUtc([datetime]::SpecifyKind($wave1Start, 'Unspecified'), $tz) - [datetime]::UtcNow).TotalMinutes
if ($leadMinutes -lt 60) { throw "The first window starts in $([int]$leadMinutes) minutes; pre-events need at least 40 minutes of lead time. Use a later -StartDate/-StartTime." }

$waves = @(
    [pscustomobject]@{ Wave = 1; Target = $FirstNode; Partner = $SecondNode; Start = $wave1Start },
    [pscustomobject]@{ Wave = 2; Target = $SecondNode; Partner = $FirstNode; Start = $wave2Start }
)
foreach ($w in $waves) { $w | Add-Member -NotePropertyName ConfigName -NotePropertyValue ("mc-sqlag-{0}" -f $w.Target.ToLower()) }

Write-Section 'AG-aware patching with Azure Update Manager'
Write-Info "Subscription     : $($account.name) ($SubscriptionId)"
Write-Info "Arc machines RG  : $ArcResourceGroup"
Write-Info "Patching RG      : $PatchingResourceGroup ($Location)"
Write-Info "Automation       : $AutomationAccountName"
Write-Info "Availability grp : $AvailabilityGroupName (preferred primary: $(if ($PreferredPrimary) { $PreferredPrimary } else { 'none' }))"
Write-Info "Recurrence       : $RecurEvery, $TimeZone, effective $StartDate"
foreach ($w in $waves) {
    Write-Info ("Wave {0}           : {1} {2}-{3} ({4})" -f $w.Wave, $w.Target, $w.Start.ToString('HH:mm'), $w.Start.Add($duration).ToString('HH:mm'), $w.ConfigName)
}
Write-Info "Classifications  : $($Classifications -join ', '); reboot $RebootSetting"
Write-Warn 'These schedules install updates and REBOOT the SQL nodes (one at a time) in each window.'
if (-not $Force) {
    $answer = Read-Host 'Type YES to continue'
    if ($answer -cne 'YES') { Write-Host 'Aborted.'; return }
}

# ---------------------------------------------------------------- providers + machines
Write-Section 'Checking resource providers and Arc machines'
foreach ($ns in 'Microsoft.Maintenance', 'Microsoft.Automation', 'Microsoft.EventGrid') {
    $state = Invoke-Az @('provider', 'show', '-n', $ns, '--query', 'registrationState', '-o', 'tsv')
    if ($state -ne 'Registered') {
        Write-Info "Registering $ns..."
        Invoke-Az @('provider', 'register', '-n', $ns, '--wait') | Out-Null
    }
}
Invoke-Az @('extension', 'add', '--name', 'connectedmachine', '--upgrade') | Out-Null

$machines = @{}
foreach ($node in $FirstNode, $SecondNode) {
    $m = Invoke-Arm -Path "/subscriptions/$SubscriptionId/resourceGroups/$ArcResourceGroup/providers/Microsoft.HybridCompute/machines/${node}?api-version=$($script:HybridComputeApi)" -AllowNotFound
    if (-not $m) { throw "Arc machine $node not found in $ArcResourceGroup. Run scripts\arc\Enable-SqlArcEvaluation.ps1 first." }
    if ($m.properties.status -ne 'Connected') { throw "Arc machine $node is '$($m.properties.status)'; it must be Connected." }
    $machines[$node] = $m
    Write-Ok "$node is Connected ($($m.properties.osSku))"
}

# The runbooks read AG state and fail over through the Arc SQL instance that hosts the AG replica.
$instances = @{}
$sqlList = Invoke-Arm -Path "/subscriptions/$SubscriptionId/resourceGroups/$ArcResourceGroup/providers/Microsoft.AzureArcData/sqlServerInstances?api-version=$($script:ArcDataApi)"
foreach ($node in $FirstNode, $SecondNode) {
    foreach ($inst in @($sqlList.value)) {
        if (-not $inst -or [string]$inst.properties.containerResourceId -ne $machines[$node].id) { continue }
        $agRes = Invoke-Arm -Path "$($inst.id)/availabilityGroups/${AvailabilityGroupName}?api-version=$($script:ArcDataApi)" -AllowNotFound
        if ($agRes) { $instances[$node] = $inst; break }
    }
    if (-not $instances[$node]) {
        throw "No SQL Server - Azure Arc instance on $node hosts availability group '$AvailabilityGroupName'. Check that the Arc SQL extension is installed and has reported the AG."
    }
    Write-Ok "$node hosts $AvailabilityGroupName on Arc SQL instance $($instances[$node].name) ($($instances[$node].properties.patchLevel))"
}
Invoke-Az @('group', 'create', '-n', $PatchingResourceGroup, '-l', $Location) | Out-Null

# ---------------------------------------------------------------- other schedules on the nodes
Write-Section 'Checking existing Update Manager assignments on the nodes'
$ourConfigIds = @($waves | ForEach-Object {
        "/subscriptions/$SubscriptionId/resourceGroups/$PatchingResourceGroup/providers/Microsoft.Maintenance/maintenanceConfigurations/$($_.ConfigName)".ToLower()
    })
foreach ($node in $FirstNode, $SecondNode) {
    $ownIndex = if ($node -eq $FirstNode) { 0 } else { 1 }
    $list = Invoke-Arm -Path "$($machines[$node].id)/providers/Microsoft.Maintenance/configurationAssignments?api-version=$($script:MaintenanceApi)"
    foreach ($a in @($list.value)) {
        if (-not $a) { continue }
        $mcId = [string]$a.properties.maintenanceConfigurationId
        # Each node may only be in its own wave; being in the other wave would patch both nodes together.
        if ($mcId.ToLower() -eq $ourConfigIds[$ownIndex]) { continue }
        $mcName = ($mcId -split '/')[-1]
        if ($KeepOtherAssignments -and $ourConfigIds -notcontains $mcId.ToLower()) {
            Write-Warn "$node is also assigned to '$mcName'. It may patch both nodes at the same time (kept because of -KeepOtherAssignments)."
            continue
        }
        Invoke-Arm -Method DELETE -Path "$($machines[$node].id)/providers/Microsoft.Maintenance/configurationAssignments/$($a.name)?api-version=$($script:MaintenanceApi)" -AllowNotFound | Out-Null
        Write-Ok "Removed $node from maintenance configuration '$mcName' (assignment $($a.name))"
        if ($mcName -eq 'autoupdate-config') {
            Write-Warn "'autoupdate-config' is typically created by SQL Server - Azure Arc > Updates. Turn automatic updates off there so it is not re-created."
        }
    }
}
Write-Info 'Dynamic-scope schedules (subscription/resource-group filters) are not checked; make sure none of them include the SQL nodes.'

# ---------------------------------------------------------------- Windows Update policy
if (-not $SkipWindowsUpdatePolicy) {
    Write-Section 'Registering Microsoft Update and disabling automatic installs on the nodes'
    $wuScript = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Set-WindowsUpdatePolicy.ps1'))
    foreach ($node in $FirstNode, $SecondNode) {
        $iv = Invoke-ArcRunCommand -MachineId $machines[$node].id -Location $machines[$node].location `
            -Name 'sqlagpatch-wupolicy' -Script $wuScript -TimeoutSeconds 300
        $out = [string]$iv.output
        $line = @($out -split "`r?`n" | Where-Object { $_ -like 'WUPOLICY:*' }) | Select-Object -Last 1
        if (-not $line -or $line -notmatch 'MicrosoftUpdateRegisteredWithAU=True') {
            throw "Windows Update policy failed on ${node}: $out $($iv.error)"
        }
        Write-Ok $line.Substring(10)
    }
}

# ---------------------------------------------------------------- Automation account + runbooks
Write-Section "Automation account $AutomationAccountName"
$aaPath = "/subscriptions/$SubscriptionId/resourceGroups/$PatchingResourceGroup/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName"
$aa = Invoke-Arm -Path "${aaPath}?api-version=$automationApi" -AllowNotFound
if (-not $aa -or -not $aa.identity.principalId) {
    $aa = Invoke-Arm -Method PUT -Path "${aaPath}?api-version=$automationApi" -Body @{
        location   = $Location
        identity   = @{ type = 'SystemAssigned' }
        properties = @{ sku = @{ name = 'Basic' }; publicNetworkAccess = $true }
    }
    $aa = Wait-Until -Description 'Automation account managed identity' -TimeoutMinutes 5 -IntervalSeconds 10 -Condition {
        $x = Invoke-Arm -Path "${aaPath}?api-version=$automationApi"
        if ($x.identity.principalId) { $x }
    }
    if (-not $aa) { throw 'The Automation account managed identity was not created.' }
}
$principalId = $aa.identity.principalId
Write-Ok "Automation account ready (managed identity $principalId)"

function Get-ArmText([string]$Path) {
    # Raw GET (runbook content is text/powershell, not JSON). Returns '' when not available yet.
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Method Get -Uri "https://management.azure.com$Path" -Headers @{ Authorization = "Bearer $(Get-ArmToken)" }
        if ($r.Content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($r.Content) }
        return [string]$r.Content
    }
    catch { return '' }
}
function Get-NormalizedText([string]$Text) { ($Text.TrimStart([char]0xFEFF) -replace "`r`n", "`n").Trim() }
function Get-WebhookStamp($Webhook) {
    $t = ConvertTo-UtcDateTime $Webhook.properties.creationTime
    if ($t) { return $t.ToString('yyyyMMddHHmmssfff') }
    return ''
}

$commonCode = [IO.File]::ReadAllText($commonPath)
foreach ($rbName in $runbooks.Keys) {
    $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "runbooks\$($runbooks[$rbName].File)"))
    if (-not $source.Contains('# <<SqlAgPatchCommon>>')) { throw "$rbName is missing the '# <<SqlAgPatchCommon>>' marker." }
    $content = $source.Replace('# <<SqlAgPatchCommon>>', $commonCode)
    $expected = Get-NormalizedText $content
    $rbPath = "$aaPath/runbooks/$rbName"

    Invoke-Arm -Method PUT -Path "${rbPath}?api-version=$automationApi" -Body @{
        location   = $Location
        properties = @{ runbookType = 'PowerShell'; logProgress = $false; logVerbose = $false; description = 'AG-aware patching for SQL Server (Update Manager event handler)' }
    } | Out-Null
    Invoke-RestMethod -Method Put -Uri "https://management.azure.com$rbPath/draft/content?api-version=$automationApi" `
        -Headers @{ Authorization = "Bearer $(Get-ArmToken)" } -ContentType 'text/powershell' `
        -Body ([Text.Encoding]::UTF8.GetBytes($content)) | Out-Null
    # Both calls can complete asynchronously, so compare content instead of trusting the runbook state.
    $ok = Wait-Until -Description "runbook $rbName draft upload" -TimeoutMinutes 5 -IntervalSeconds 10 -Condition {
        (Get-NormalizedText (Get-ArmText "$rbPath/draft/content?api-version=$automationApi")) -eq $expected
    }
    if (-not $ok) { throw "The draft content of runbook $rbName was not updated." }
    Invoke-Arm -Method POST -Path "$rbPath/publish?api-version=$automationApi" | Out-Null
    $ok = Wait-Until -Description "runbook $rbName to publish" -TimeoutMinutes 5 -IntervalSeconds 10 -Condition {
        (Invoke-Arm -Path "${rbPath}?api-version=$automationApi").properties.state -eq 'Published' -and
        (Get-NormalizedText (Get-ArmText "$rbPath/content?api-version=$automationApi")) -eq $expected
    }
    if (-not $ok) { throw "Runbook $rbName was not published with the new content." }
    Write-Ok "Runbook $rbName published"
}

# ---------------------------------------------------------------- maintenance configurations
Write-Section 'Maintenance configurations'
foreach ($w in $waves) {
    $mcPath = "/subscriptions/$SubscriptionId/resourceGroups/$PatchingResourceGroup/providers/Microsoft.Maintenance/maintenanceConfigurations/$($w.ConfigName)"
    $mc = Invoke-Arm -Method PUT -Path "${mcPath}?api-version=$($script:MaintenanceApi)" -Body @{
        location   = $Location
        tags       = @{
            SqlAgTarget               = $w.Target
            SqlAgPartner              = $w.Partner
            SqlAgName                 = $AvailabilityGroupName
            SqlAgMachineResourceGroup = $ArcResourceGroup
            SqlAgPreferredPrimary     = $PreferredPrimary
            SqlAgTargetInstance       = $instances[$w.Target].name
            SqlAgPartnerInstance      = $instances[$w.Partner].name
            SqlAgWave                 = [string]$w.Wave
        }
        properties = @{
            maintenanceScope    = 'InGuestPatch'
            visibility          = 'Custom'
            extensionProperties = @{ InGuestPatchMode = 'User' }
            maintenanceWindow   = @{
                startDateTime = $w.Start.ToString('yyyy-MM-dd HH:mm')
                duration      = $WindowDuration
                timeZone      = $TimeZone
                recurEvery    = $RecurEvery
            }
            installPatches      = @{
                rebootSetting     = $RebootSetting
                windowsParameters = @{
                    classificationsToInclude = @($Classifications)
                    kbNumbersToExclude       = @($ExcludeKbs)
                }
            }
        }
    }
    $w | Add-Member -NotePropertyName ConfigId -NotePropertyValue $mc.id -Force
    Write-Ok "$($w.ConfigName): $($w.Target) at $($w.Start.ToString('HH:mm')) ($RecurEvery)"
}

# ---------------------------------------------------------------- role assignments
Write-Section 'Managed identity role assignments'
function Set-RoleAssignment([string]$Role, [string]$Scope) {
    $existing = Invoke-Az @('role', 'assignment', 'list', '--assignee', $principalId, '--role', $Role, '--scope', $Scope) -Json
    if (@($existing | Where-Object { $_ }).Count -gt 0) { Write-Ok "$Role on $(($Scope -split '/')[-1]) (exists)"; return }
    $ok = Wait-Until -Description "role assignment '$Role'" -TimeoutMinutes 5 -IntervalSeconds 15 -Condition {
        Invoke-Az @('role', 'assignment', 'create', '--assignee-object-id', $principalId, '--assignee-principal-type',
            'ServicePrincipal', '--role', $Role, '--scope', $Scope) -Json -AllowFailure
    }
    if (-not $ok) { throw "Could not assign '$Role' on $Scope. You need Owner or User Access Administrator." }
    Write-Ok "$Role on $(($Scope -split '/')[-1])"
}
# Contributor on the Arc SQL instance: getDetailView and failover actions on its availability groups
foreach ($node in $FirstNode, $SecondNode) { Set-RoleAssignment 'Contributor' $instances[$node].id }
# Earlier versions ran T-SQL through Arc Run Command; that role on the machines is no longer needed.
foreach ($node in $FirstNode, $SecondNode) {
    $old = Invoke-Az @('role', 'assignment', 'list', '--assignee', $principalId, '--role', 'Azure Connected Machine Resource Administrator', '--scope', $machines[$node].id) -Json
    foreach ($ra in @($old | Where-Object { $_ })) {
        Invoke-Az @('role', 'assignment', 'delete', '--ids', $ra.id) | Out-Null
        Write-Ok "Removed Azure Connected Machine Resource Administrator on $node (no longer needed)"
    }
}
# Contributor on the configuration: read its tags and cancel its runs (applyUpdates/write)
foreach ($w in $waves) { Set-RoleAssignment 'Contributor' $w.ConfigId }

# ---------------------------------------------------------------- Event Grid + webhooks, then assignments
# The machines are assigned to the schedules last, only after every pre/post handler is wired up.
# If rewiring fails midway, the assignments are removed so no wave runs without its pre-event handler.
$rewiring = $false
try {
    Write-Section 'Event Grid subscriptions and webhooks'
    foreach ($w in $waves) {
        $w | Add-Member -NotePropertyName TopicName -NotePropertyValue "st-$($w.ConfigName)" -Force
        $topic = Invoke-Az @('eventgrid', 'system-topic', 'show', '-g', $PatchingResourceGroup, '-n', $w.TopicName) -Json -AllowFailure
        if (-not $topic) {
            Invoke-Az @('eventgrid', 'system-topic', 'create', '-g', $PatchingResourceGroup, '-n', $w.TopicName, '-l', $Location,
                '--topic-type', 'Microsoft.Maintenance.MaintenanceConfigurations', '--source', $w.ConfigId) | Out-Null
        }
        Write-Ok "System topic $($w.TopicName)"
    }

    foreach ($rbName in $runbooks.Keys) {
        $rb = $runbooks[$rbName]
        $whPath = "$aaPath/webhooks/$($rb.Webhook)"
        $webhook = Invoke-Arm -Path "${whPath}?api-version=$webhookApi" -AllowNotFound
        $stamp = if ($webhook) { Get-WebhookStamp $webhook } else { '' }
        $expiry = if ($webhook) { ConvertTo-UtcDateTime $webhook.properties.expiryTime } else { $null }

        # Each subscription is labelled with the creation time of the webhook it points at, so a
        # subscription left on an old (deleted) webhook URL by an interrupted run is detected.
        $inSync = $webhook -and $stamp -and $expiry -and $expiry -gt [datetime]::UtcNow.AddDays(30) -and -not $RotateWebhooks
        foreach ($w in $waves) {
            if (-not $inSync) { break }
            $sub = Invoke-Az @('eventgrid', 'system-topic', 'event-subscription', 'show', '-g', $PatchingResourceGroup,
                '--system-topic-name', $w.TopicName, '-n', $rb.Subscription) -Json -AllowFailure
            if (-not $sub -or $sub.provisioningState -ne 'Succeeded' -or @($sub.labels) -notcontains "sqlag-webhook-$stamp") { $inSync = $false }
        }
        if ($inSync) {
            Write-Ok "Webhook $($rb.Webhook) and its subscriptions are in place (expires $($expiry.ToString('yyyy-MM-dd'))); use -RotateWebhooks to replace"
            continue
        }

        # A webhook URL can only be read when it is created, so (re)create the webhook and point all subscriptions at it.
        $rewiring = $true
        if ($webhook) {
            Invoke-Arm -Method DELETE -Path "${whPath}?api-version=$webhookApi" -AllowNotFound | Out-Null
            $gone = Wait-Until -Description "webhook $($rb.Webhook) deletion" -TimeoutMinutes 2 -IntervalSeconds 5 -Condition {
                -not (Invoke-Arm -Path "${whPath}?api-version=$webhookApi" -AllowNotFound)
            }
            if (-not $gone) { throw "Webhook $($rb.Webhook) was not deleted." }
        }
        $uri = Invoke-Arm -Method POST -Path "$aaPath/webhooks/generateUri?api-version=$webhookApi"
        $created = Invoke-Arm -Method PUT -Path "${whPath}?api-version=$webhookApi" -Body @{
            name       = $rb.Webhook
            properties = @{
                isEnabled  = $true
                uri        = $uri
                expiryTime = [datetime]::UtcNow.AddDays($WebhookExpiryDays).ToString('o')
                runbook    = @{ name = $rbName }
            }
        }
        $stamp = Get-WebhookStamp $created
        if (-not $stamp) { $stamp = Get-WebhookStamp (Invoke-Arm -Path "${whPath}?api-version=$webhookApi") }
        if (-not $stamp) { throw "Could not read the creation time of webhook $($rb.Webhook)." }
        Write-Ok "Webhook $($rb.Webhook) -> $rbName (expires in $WebhookExpiryDays days)"

        foreach ($w in $waves) {
            $subArgs = @('-g', $PatchingResourceGroup, '--system-topic-name', $w.TopicName, '-n', $rb.Subscription,
                '--endpoint-type', 'webhook', '--endpoint', $uri, '--labels', "sqlag-webhook-$stamp")
            $exists = Invoke-Az @('eventgrid', 'system-topic', 'event-subscription', 'show', '-g', $PatchingResourceGroup,
                '--system-topic-name', $w.TopicName, '-n', $rb.Subscription) -Json -AllowFailure
            if ($exists) {
                $sub = Invoke-Az (@('eventgrid', 'system-topic', 'event-subscription', 'update') + $subArgs) -Json
            }
            else {
                $sub = Invoke-Az (@('eventgrid', 'system-topic', 'event-subscription', 'create') + $subArgs +
                    @('--included-event-types', $rb.EventType, '--max-delivery-attempts', '10', '--event-ttl', '30')) -Json
            }
            if ($sub.provisioningState -ne 'Succeeded') { throw "Event subscription $($w.TopicName)/$($rb.Subscription) is '$($sub.provisioningState)'." }
            Write-Ok "$($w.TopicName)/$($rb.Subscription) ($($rb.EventType))"
        }
    }

    Write-Section 'Assigning the nodes to their waves'
    foreach ($w in $waves) {
        $assignPath = "$($machines[$w.Target].id)/providers/Microsoft.Maintenance/configurationAssignments/$($w.ConfigName)?api-version=$($script:MaintenanceApi)"
        Invoke-Arm -Method PUT -Path $assignPath -Body @{
            location   = $machines[$w.Target].location
            properties = @{ maintenanceConfigurationId = $w.ConfigId }
        } | Out-Null
        Write-Ok "$($w.Target) assigned to $($w.ConfigName)"
    }
    $rewiring = $false
}
catch {
    if ($rewiring) {
        Write-Warn 'Webhook rewiring failed; removing the schedule assignments so no node is patched without its pre-event handler.'
        foreach ($w in $waves) {
            try {
                Invoke-Arm -Method DELETE -Path "$($machines[$w.Target].id)/providers/Microsoft.Maintenance/configurationAssignments/$($w.ConfigName)?api-version=$($script:MaintenanceApi)" -AllowNotFound | Out-Null
                Write-Warn "Removed $($w.Target) from $($w.ConfigName). Fix the error and rerun this script."
            }
            catch { Write-Warn "Could not remove $($w.Target) from $($w.ConfigName): $($_.Exception.Message)" }
        }
    }
    throw
}

# ---------------------------------------------------------------- summary
Write-Section 'Done'
foreach ($w in $waves) {
    Write-Info ("Wave {0}: {1} {2} {3}-{4} {5}" -f $w.Wave, $w.Target, $RecurEvery, $w.Start.ToString('HH:mm'), $w.Start.Add($duration).ToString('HH:mm'), $TimeZone)
}
Write-Info "Runbook jobs : Automation account '$AutomationAccountName' > Jobs"
Write-Info 'Patch history: Azure Update Manager > History (or each Arc machine > Updates)'
Write-Info "Webhooks expire in $WebhookExpiryDays days. Rerun this script with -RotateWebhooks before then;"
Write-Info 'if the pre-event cannot start its runbook, Update Manager still patches the node without failing over.'