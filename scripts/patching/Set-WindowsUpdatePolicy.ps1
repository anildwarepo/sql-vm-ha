<#
.SYNOPSIS
    Configures Windows Update on a SQL node for Azure Update Manager scheduled patching.
    Runs on the node (Arc Run Command, as SYSTEM). Windows PowerShell 5.1.

.DESCRIPTION
    - Registers the Microsoft Update service, so SQL Server cumulative updates and security updates
      are offered alongside Windows updates (the Group Policy equivalent is
      "Configure Automatic Updates" > "Install updates for other Microsoft products").
    - Sets automatic updates to "notify only" (AUOptions=2), so Windows never installs updates or
      reboots on its own; Azure Update Manager installs them in the maintenance window.

    The original values are saved under HKLM:\SOFTWARE\SqlAgPatching the first time; -Remove restores them.
#>
param([switch]$Remove)

$ErrorActionPreference = 'Stop'
$microsoftUpdateServiceId = '7971f918-a847-4430-9279-4a52d1efe18d'
$auKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$backupKey = 'HKLM:\SOFTWARE\SqlAgPatching\WindowsUpdateBackup'
$names = 'NoAutoUpdate', 'AUOptions', 'AllowMUUpdateService'
$manager = New-Object -ComObject Microsoft.Update.ServiceManager

function Test-MicrosoftUpdate {
    foreach ($svc in $manager.Services) {
        if ($svc.ServiceID -eq $microsoftUpdateServiceId -and $svc.IsRegisteredWithAU) { return $true }
    }
    return $false
}

if ($Remove) {
    if (Test-Path $backupKey) {
        $backup = Get-ItemProperty -Path $backupKey
        foreach ($name in $names) {
            if ($backup.PSObject.Properties.Name -contains $name) {
                if (-not (Test-Path $auKey)) { New-Item -Path $auKey -Force | Out-Null }
                Set-ItemProperty -Path $auKey -Name $name -Value $backup.$name -Type DWord
            }
            else {
                Remove-ItemProperty -Path $auKey -Name $name -ErrorAction SilentlyContinue
            }
        }
        if ($backup.MicrosoftUpdateWasRegistered -ne 1) {
            try { $manager.RemoveService($microsoftUpdateServiceId) } catch { Write-Output "RemoveService: $($_.Exception.Message)" }
        }
        Remove-Item -Path (Split-Path $backupKey) -Recurse -Force
    }
    else {
        Write-Output 'No backup found (policy was not applied by Enable-SqlAgPatching.ps1); nothing changed.'
    }
}
else {
    if (-not (Test-Path $backupKey)) {
        New-Item -Path $backupKey -Force | Out-Null
        $current = Get-ItemProperty -Path $auKey -ErrorAction SilentlyContinue
        foreach ($name in $names) {
            if ($current -and $current.PSObject.Properties.Name -contains $name) {
                Set-ItemProperty -Path $backupKey -Name $name -Value $current.$name -Type DWord
            }
        }
        Set-ItemProperty -Path $backupKey -Name MicrosoftUpdateWasRegistered -Value ([int](Test-MicrosoftUpdate)) -Type DWord
    }
    # New-Item -Force on an existing registry key would wipe its other values
    if (-not (Test-Path $auKey)) { New-Item -Path $auKey -Force | Out-Null }
    Set-ItemProperty -Path $auKey -Name NoAutoUpdate -Value 0 -Type DWord
    Set-ItemProperty -Path $auKey -Name AUOptions -Value 2 -Type DWord
    Set-ItemProperty -Path $auKey -Name AllowMUUpdateService -Value 1 -Type DWord
    # 7 = allow pending registration + allow online registration + register with Automatic Updates
    [void]$manager.AddService2($microsoftUpdateServiceId, 7, '')
}

$au = Get-ItemProperty -Path $auKey -ErrorAction SilentlyContinue
Write-Output ('WUPOLICY: {0} MicrosoftUpdateRegisteredWithAU={1} NoAutoUpdate={2} AUOptions={3} AllowMUUpdateService={4}' -f
    $env:COMPUTERNAME, (Test-MicrosoftUpdate), $au.NoAutoUpdate, $au.AUOptions, $au.AllowMUUpdateService)