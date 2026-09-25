<#
.SYNOPSIS
    Runs INSIDE the VM. Reverts Install-ArcAgentOnVm.ps1: disconnects and uninstalls the Azure
    Connected Machine agent, removes the IMDS block and MSFT_ARC_TEST, and re-enables the
    Azure VM guest agent.

.DESCRIPTION
    Normally launched by Disable-SqlArcEvaluation.ps1 via Arc Run Command as a one-time SYSTEM
    scheduled task. Can also be run manually from an elevated PowerShell over RDP.
    Delete the Arc machine resource in Azure afterwards if you run this manually.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [int]$InitialDelaySeconds = 0,
    [string]$WorkDir = 'C:\ArcEval'
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
$statusPath = Join-Path $WorkDir 'arc-offboard.status'
Start-Transcript -Path (Join-Path $WorkDir 'arc-offboard.log') -Append | Out-Null

function Write-Step([string]$msg) { Write-Output ("[{0:u}] {1}" -f (Get-Date), $msg) }

try {
    Set-Content -Path $statusPath -Value 'Running'
    if ($ConfigPath -and (Test-Path $ConfigPath)) {
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        if ($cfg.InitialDelaySeconds) { $InitialDelaySeconds = [int]$cfg.InitialDelaySeconds }
        Remove-Item $ConfigPath -Force
    }
    if ($InitialDelaySeconds -gt 0) {
        Write-Step "Waiting $InitialDelaySeconds seconds before starting"
        Start-Sleep -Seconds $InitialDelaySeconds
    }

    $azcmagent = Join-Path $env:ProgramFiles 'AzureConnectedMachineAgent\azcmagent.exe'
    if (Test-Path $azcmagent) {
        Write-Step 'Disconnecting Azure Connected Machine agent (local only)'
        & $azcmagent disconnect --force-local-only
        if ($LASTEXITCODE -ne 0) { Write-Step "azcmagent disconnect returned $LASTEXITCODE (continuing)" }
    }

    $uninstallKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $products = Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq 'Azure Connected Machine Agent' -and $_.PSChildName -match '^\{.+\}$' }
    foreach ($product in $products) {
        Write-Step "Uninstalling $($product.DisplayName) $($product.DisplayVersion)"
        $p = Start-Process msiexec.exe -ArgumentList @('/x', $product.PSChildName, '/qn', '/l*v',
            "`"$(Join-Path $WorkDir 'azcmagent-uninstall.log')`"") -Wait -PassThru
        if ($p.ExitCode -notin 0, 3010) { throw "Agent uninstall failed with exit code $($p.ExitCode)" }
    }

    foreach ($rule in 'BlockAzureIMDS', 'BlockAzureLocalIMDS') {
        if (Get-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue) {
            Write-Step "Removing firewall rule $rule"
            Remove-NetFirewallRule -Name $rule
        }
    }

    Write-Step 'Removing MSFT_ARC_TEST'
    [Environment]::SetEnvironmentVariable('MSFT_ARC_TEST', $null, [EnvironmentVariableTarget]::Machine)

    if (Get-Service WindowsAzureGuestAgent -ErrorAction SilentlyContinue) {
        Write-Step 'Re-enabling and starting WindowsAzureGuestAgent'
        Set-Service WindowsAzureGuestAgent -StartupType Automatic
        Start-Service WindowsAzureGuestAgent
    }

    Set-Content -Path $statusPath -Value 'Succeeded'
    Write-Step 'Azure Arc evaluation changes reverted'
}
catch {
    Set-Content -Path $statusPath -Value "Failed: $($_.Exception.Message)"
    Write-Output "ERROR: $($_.Exception.Message)"
    # Never leave the VM without its Azure guest agent.
    Set-Service WindowsAzureGuestAgent -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service WindowsAzureGuestAgent -ErrorAction SilentlyContinue
    throw
}
finally {
    Unregister-ScheduledTask -TaskName 'ArcEvalOffboard' -Confirm:$false -ErrorAction SilentlyContinue
    Stop-Transcript | Out-Null
}
