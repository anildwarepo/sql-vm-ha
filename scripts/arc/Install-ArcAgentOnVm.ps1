<#
.SYNOPSIS
    Runs INSIDE an Azure VM. Makes the VM look like a non-Azure (e.g. AWS) server and
    onboards it to Azure Arc-enabled servers + SQL Server enabled by Azure Arc.

.DESCRIPTION
    EVALUATION / TESTING ONLY. Implements the documented workaround:
    https://learn.microsoft.com/azure/azure-arc/servers/plan-evaluate-on-azure-virtual-machine

      1. Sets MSFT_ARC_TEST=true (machine scope + Arc agent services).
      2. Downloads and installs the Azure Connected Machine agent (MSI).
      3. Blocks the Azure IMDS endpoints (169.254.169.254 / 169.254.169.253).
      4. Disables and stops the Azure VM guest agent (WindowsAzureGuestAgent).
      5. Runs 'azcmagent connect'.

    After step 4, Azure VM extensions and Azure VM Run Command no longer work on this VM.
    Remove VM extensions (SQL IaaS Agent, Defender, etc.) BEFORE running this script.

    Normally launched by Enable-SqlArcEvaluation.ps1 as a one-time SYSTEM scheduled task
    with -ConfigPath. It can also be run manually from an elevated PowerShell over RDP.

.EXAMPLE
    # Manual run over RDP (get a token on your workstation with:
    #   az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv)
    .\Install-ArcAgentOnVm.ps1 -TenantId <tenant> -SubscriptionId <sub> -ResourceGroup rg-sql-arc `
        -Location westus -AccessToken <token> -Tags 'EmulatedCloud=AWS,ArcSQLServerExtensionDeployment=Disabled'
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$TenantId,
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$Location,
    [string]$ResourceName = $env:COMPUTERNAME,
    [string]$AccessToken,
    [string]$ServicePrincipalId,
    [string]$ServicePrincipalSecret,
    [string]$Tags = '',
    [string]$CorrelationId,
    [int]$InitialDelaySeconds = 0,
    [string]$WorkDir = 'C:\ArcEval'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
$logPath = Join-Path $WorkDir 'arc-onboard.log'
$statusPath = Join-Path $WorkDir 'arc-onboard.status'
Start-Transcript -Path $logPath -Append | Out-Null

function Write-Step([string]$msg) { Write-Output ("[{0:u}] {1}" -f (Get-Date), $msg) }

try {
    Set-Content -Path $statusPath -Value 'Running'

    if ($ConfigPath) {
        if (-not (Test-Path $ConfigPath)) { throw "Config file not found: $ConfigPath" }
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        # Secrets live only in memory from here on.
        Remove-Item $ConfigPath -Force
        foreach ($p in 'TenantId','SubscriptionId','ResourceGroup','Location','ResourceName','AccessToken',
                       'ServicePrincipalId','ServicePrincipalSecret','Tags','CorrelationId','InitialDelaySeconds') {
            if ($null -ne $cfg.$p -and "$($cfg.$p)" -ne '') { Set-Variable -Name $p -Value $cfg.$p }
        }
    }

    foreach ($required in 'TenantId','SubscriptionId','ResourceGroup','Location') {
        if (-not (Get-Variable -Name $required -ValueOnly)) { throw "Missing required value: $required" }
    }
    if (-not $AccessToken -and -not ($ServicePrincipalId -and $ServicePrincipalSecret)) {
        throw 'Provide -AccessToken or -ServicePrincipalId/-ServicePrincipalSecret.'
    }

    if ($InitialDelaySeconds -gt 0) {
        # Gives the Azure Run Command that launched this task time to report back
        # before the guest agent is stopped.
        Write-Step "Waiting $InitialDelaySeconds seconds before starting"
        Start-Sleep -Seconds $InitialDelaySeconds
    }

    # 1. Override the "Arc is not supported on Azure VMs" check.
    Write-Step 'Setting MSFT_ARC_TEST=true (machine scope)'
    [Environment]::SetEnvironmentVariable('MSFT_ARC_TEST', 'true', [EnvironmentVariableTarget]::Machine)
    $env:MSFT_ARC_TEST = 'true'

    # 2. Install the Connected Machine agent.
    $azcmagent = Join-Path $env:ProgramFiles 'AzureConnectedMachineAgent\azcmagent.exe'
    if (Test-Path $azcmagent) {
        Write-Step 'Azure Connected Machine agent already installed'
    } else {
        $msi = Join-Path $WorkDir 'AzureConnectedMachineAgent.msi'
        Write-Step 'Downloading Azure Connected Machine agent from https://aka.ms/AzureConnectedMachineAgent'
        Invoke-WebRequest -Uri 'https://aka.ms/AzureConnectedMachineAgent' -OutFile $msi -UseBasicParsing
        $sig = Get-AuthenticodeSignature $msi
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
            throw "Agent MSI signature check failed: $($sig.Status) $($sig.SignerCertificate.Subject)"
        }
        Write-Step 'Installing agent MSI'
        $msiLog = Join-Path $WorkDir 'azcmagent-msi.log'
        $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$msi`"", '/qn', '/l*v', "`"$msiLog`"") -Wait -PassThru
        if ($p.ExitCode -notin 0, 3010) { throw "Agent MSI install failed with exit code $($p.ExitCode). See $msiLog" }
        if (-not (Test-Path $azcmagent)) { throw "azcmagent.exe not found after install" }
    }

    # SCM hands services the environment captured at boot, so give the Arc services the flag directly.
    foreach ($svc in 'himds', 'GCArcService', 'ExtensionService', 'arcproxy') {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
        if (Test-Path $key) {
            New-ItemProperty -Path $key -Name Environment -PropertyType MultiString -Value @('MSFT_ARC_TEST=true') -Force | Out-Null
            if ((Get-Service $svc).Status -eq 'Running') { Restart-Service $svc -Force }
        }
    }

    # 3. Block Azure IMDS so only the Arc IMDS (localhost:40342) is used.
    foreach ($imds in @(@{ Name = 'BlockAzureIMDS'; Ip = '169.254.169.254' },
                        @{ Name = 'BlockAzureLocalIMDS'; Ip = '169.254.169.253' })) {
        if (-not (Get-NetFirewallRule -Name $imds.Name -ErrorAction SilentlyContinue)) {
            Write-Step "Blocking outbound access to $($imds.Ip)"
            New-NetFirewallRule -Name $imds.Name -DisplayName "Block access to Azure IMDS ($($imds.Ip))" `
                -Enabled True -Profile Any -Direction Outbound -Action Block -RemoteAddress $imds.Ip | Out-Null
        }
    }

    # 4. Disable the Azure VM guest agent (stops VM extensions + Azure Run Command).
    if (Get-Service WindowsAzureGuestAgent -ErrorAction SilentlyContinue) {
        Write-Step 'Disabling and stopping WindowsAzureGuestAgent'
        Set-Service WindowsAzureGuestAgent -StartupType Disabled
        Stop-Service WindowsAzureGuestAgent -Force
        # The Run Command that staged this script (and its embedded token) is cached here.
        Get-ChildItem 'C:\Packages\Plugins\Microsoft.CPlat.Core.RunCommandWindows\*\Downloads' -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item (Join-Path $_.FullName '*') -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # 5. Connect to Azure Arc.
    $status = $null
    try { $status = (& $azcmagent show -j 2>$null) -join "`n" | ConvertFrom-Json } catch { }
    if ($status -and $status.status -eq 'Connected') {
        Write-Step "Already connected as $($status.resourceName) in $($status.resourceGroup)"
    } else {
        $connectArgs = @(
            'connect',
            '--subscription-id', $SubscriptionId,
            '--tenant-id', $TenantId,
            '--resource-group', $ResourceGroup,
            '--location', $Location,
            '--resource-name', $ResourceName,
            '--cloud', 'AzureCloud'
        )
        if ($Tags) { $connectArgs += @('--tags', $Tags) }
        if ($CorrelationId) { $connectArgs += @('--correlation-id', $CorrelationId) }
        if ($ServicePrincipalId) {
            $connectArgs += @('--service-principal-id', $ServicePrincipalId, '--service-principal-secret', $ServicePrincipalSecret)
        } else {
            $connectArgs += @('--access-token', $AccessToken)
        }

        Write-Step "Running azcmagent connect (resource '$ResourceName' in '$ResourceGroup', $Location)"
        & $azcmagent @connectArgs
        if ($LASTEXITCODE -ne 0) { throw "azcmagent connect failed with exit code $LASTEXITCODE" }
    }

    & $azcmagent show
    Set-Content -Path $statusPath -Value 'Succeeded'
    Write-Step 'Azure Arc onboarding completed'
}
catch {
    Set-Content -Path $statusPath -Value "Failed: $($_.Exception.Message)"
    Write-Output "ERROR: $($_.Exception.Message)"
    throw
}
finally {
    $AccessToken = $null; $ServicePrincipalSecret = $null
    if ($ConfigPath -and (Test-Path $ConfigPath)) { Remove-Item $ConfigPath -Force -ErrorAction SilentlyContinue }
    Unregister-ScheduledTask -TaskName 'ArcEvalOnboard' -Confirm:$false -ErrorAction SilentlyContinue
    Stop-Transcript | Out-Null
}
