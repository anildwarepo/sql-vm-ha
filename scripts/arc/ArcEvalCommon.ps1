# Shared helpers for the Azure Arc evaluation scripts. Dot-source this file.

function Get-AzdEnvironmentValues {
    param([string]$RepoRoot, [string]$EnvironmentName)

    $values = @{}
    $azureDir = Join-Path $RepoRoot '.azure'
    if (-not $EnvironmentName) {
        $configPath = Join-Path $azureDir 'config.json'
        if (Test-Path $configPath) {
            $EnvironmentName = (Get-Content $configPath -Raw | ConvertFrom-Json).defaultEnvironment
        }
    }
    if (-not $EnvironmentName) { return $values }

    $envFile = Join-Path $azureDir "$EnvironmentName\.env"
    if (-not (Test-Path $envFile)) { return $values }

    foreach ($line in Get-Content $envFile) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            $values[$Matches[1]] = $Matches[2].Trim().Trim('"')
        }
    }
    return $values
}

function Invoke-Az {
    # Runs az with an argument array, throws on failure, returns stdout (parsed JSON when -Json).
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$Json,
        [switch]$AllowFailure
    )
    $ErrorActionPreference = 'Continue'
    $output = & az @Arguments --only-show-errors 2>&1
    $exitCode = $LASTEXITCODE
    $stdout = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    $stderr = @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"
    if ($exitCode -ne 0) {
        if ($AllowFailure) { return $null }
        throw "az $($Arguments[0..2] -join ' ') failed (exit $exitCode): $stderr"
    }
    if ($Json) {
        if ([string]::IsNullOrWhiteSpace($stdout)) { return $null }
        return $stdout | ConvertFrom-Json
    }
    return $stdout
}

function Write-Section([string]$Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Info([string]$Message) { Write-Host "  $Message" -ForegroundColor Gray }
function Write-Warn([string]$Message) { Write-Host "  [WARN] $Message" -ForegroundColor Yellow }

function Wait-Until {
    param(
        [Parameter(Mandatory)][scriptblock]$Condition,
        [Parameter(Mandatory)][string]$Description,
        [int]$TimeoutMinutes = 20,
        [int]$IntervalSeconds = 20
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        $result = & $Condition
        if ($result) { return $result }
        Write-Info "Waiting for $Description..."
        Start-Sleep -Seconds $IntervalSeconds
    }
    return $null
}

function New-VmScheduledTaskWrapper {
    # Builds a PowerShell script that stages a payload script (+ optional JSON config) in
    # C:\ArcEval, locks the folder down to SYSTEM/Administrators, and starts it as a
    # one-time SYSTEM scheduled task so it keeps running after the launching agent is stopped.
    param(
        [Parameter(Mandatory)][string]$PayloadPath,
        [Parameter(Mandatory)][string]$TaskName,
        [hashtable]$Config,
        [string]$WorkDir = 'C:\ArcEval'
    )
    $payloadName = Split-Path $PayloadPath -Leaf
    $payloadB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($PayloadPath))
    $configB64 = ''
    if ($Config) {
        $configB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Config | ConvertTo-Json -Compress)))
    }

    return @"
`$ErrorActionPreference = 'Stop'
`$dir = '$WorkDir'
New-Item -ItemType Directory -Path `$dir -Force | Out-Null
& icacls.exe `$dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
Remove-Item (Join-Path `$dir '*.status') -Force -ErrorAction SilentlyContinue
`$payload = Join-Path `$dir '$payloadName'
[IO.File]::WriteAllBytes(`$payload, [Convert]::FromBase64String('$payloadB64'))
`$arguments = "-NoProfile -ExecutionPolicy Bypass -File ```"`$payload```""
if ('$configB64') {
    `$configPath = Join-Path `$dir '$TaskName.json'
    [IO.File]::WriteAllBytes(`$configPath, [Convert]::FromBase64String('$configB64'))
    `$arguments += " -ConfigPath ```"`$configPath```""
}
Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false -ErrorAction SilentlyContinue
`$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument `$arguments
`$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
`$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName '$TaskName' -Action `$action -Principal `$principal -Settings `$settings -Force | Out-Null
Start-ScheduledTask -TaskName '$TaskName'
Write-Output 'ARC_EVAL_TASK_STARTED'
"@
}
