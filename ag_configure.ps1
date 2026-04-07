<#
.SYNOPSIS
    Post-deployment script to add a database to the AlwaysOn Availability Group.

.DESCRIPTION
    Run this AFTER the Bicep deployment completes. The Bicep template already handles:
    - WSFC cluster creation (via SQL VM Group)
    - Cloud witness configuration
    - Always On enablement (via SQL IaaS Agent)
    - Mirroring endpoints
    - AG and listener creation (via AG Listener resource)

    This script handles what Bicep cannot automate:
    - Opening Windows Firewall ports (5022 for AG, 1433 for SQL)
    - Creating a sample database on the primary
    - Backing up and restoring the database to the secondary
    - Joining the database to the AG on the secondary

.NOTES
    Run from an admin PowerShell session on SQL-VM-1 (primary replica),
    or from a jump box with WinRM connectivity to both SQL VMs.
#>

# ─── Variables (must match Bicep deployment) ───
$Node1            = "SQL-VM-1"
$Node2            = "SQL-VM-2"
$Nodes            = @($Node1, $Node2)

# Default instances from SQL Marketplace image
$SqlInstance1     = $Node1
$SqlInstance2     = $Node2

$AGName           = "ag-sql-ha"
$DatabaseName     = "SampleDB"

# UNC share for backup transfer (create on primary's data disk)
$BackupShare      = "\\$Node1\SQLBackup"
$BackupLocalPath  = "F:\SQLBackup"

# ─── Step 1: Open firewall ports on both SQL VMs ───
Write-Host "==> Opening firewall ports on SQL VMs..." -ForegroundColor Cyan
Invoke-Command -ComputerName $Nodes -ScriptBlock {
    New-NetFirewallRule -Name "ALLOW_SQL_1433" -DisplayName "Allow SQL Server 1433" `
        -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow -ErrorAction SilentlyContinue
    New-NetFirewallRule -Name "ALLOW_HADR_5022" -DisplayName "Allow AG Endpoint 5022" `
        -Direction Inbound -Protocol TCP -LocalPort 5022 -Action Allow -ErrorAction SilentlyContinue
}

# ─── Step 2: Create a backup share on the primary ───
Write-Host "==> Creating backup share on $Node1..." -ForegroundColor Cyan
Invoke-Command -ComputerName $Node1 -ScriptBlock {
    param($path)
    if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path -Force }
    if (-not (Get-SmbShare -Name "SQLBackup" -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name "SQLBackup" -Path $path -FullAccess "Everyone"
    }
} -ArgumentList $BackupLocalPath

# ─── Step 3: Create a sample database on the primary ───
Write-Host "==> Creating database '$DatabaseName' on $SqlInstance1..." -ForegroundColor Cyan
Invoke-Sqlcmd -ServerInstance $SqlInstance1 -Query @"
IF DB_ID('$DatabaseName') IS NULL
BEGIN
    CREATE DATABASE [$DatabaseName];
    ALTER DATABASE [$DatabaseName] SET RECOVERY FULL;
END
"@

# ─── Step 4: Full backup + log backup on primary ───
Write-Host "==> Backing up '$DatabaseName'..." -ForegroundColor Cyan
Invoke-Sqlcmd -ServerInstance $SqlInstance1 -Query @"
BACKUP DATABASE [$DatabaseName] TO DISK = '$BackupLocalPath\$DatabaseName.bak'
    WITH FORMAT, INIT, COMPRESSION;
BACKUP LOG [$DatabaseName] TO DISK = '$BackupLocalPath\${DatabaseName}_log.trn'
    WITH FORMAT, INIT, COMPRESSION;
"@

# ─── Step 5: Restore database on secondary WITH NORECOVERY ───
Write-Host "==> Restoring '$DatabaseName' on $SqlInstance2 (NORECOVERY)..." -ForegroundColor Cyan
Invoke-Sqlcmd -ServerInstance $SqlInstance2 -Query @"
RESTORE DATABASE [$DatabaseName] FROM DISK = '$BackupShare\$DatabaseName.bak'
    WITH NORECOVERY, REPLACE;
RESTORE LOG [$DatabaseName] FROM DISK = '$BackupShare\${DatabaseName}_log.trn'
    WITH NORECOVERY;
"@

# ─── Step 6: Add database to AG on primary ───
Write-Host "==> Adding '$DatabaseName' to AG '$AGName' on primary..." -ForegroundColor Cyan
Invoke-Sqlcmd -ServerInstance $SqlInstance1 -Query @"
ALTER AVAILABILITY GROUP [$AGName] ADD DATABASE [$DatabaseName];
"@

# ─── Step 7: Join database to AG on secondary ───
Write-Host "==> Joining '$DatabaseName' to AG '$AGName' on secondary..." -ForegroundColor Cyan
Invoke-Sqlcmd -ServerInstance $SqlInstance2 -Query @"
ALTER DATABASE [$DatabaseName] SET HADR AVAILABILITY GROUP = [$AGName];
"@

# ─── Step 8: Validate ───
Write-Host "`n==> Validation:" -ForegroundColor Green

Write-Host "`nAG Replica Status:" -ForegroundColor Cyan
Invoke-Sqlcmd -ServerInstance $SqlInstance1 -Query @"
SELECT r.replica_server_name, r.availability_mode_desc, r.failover_mode_desc,
       rs.role_desc, rs.synchronization_health_desc
FROM sys.availability_replicas r
JOIN sys.dm_hadr_availability_replica_states rs ON r.replica_id = rs.replica_id
WHERE r.group_id = (SELECT group_id FROM sys.availability_groups WHERE name = '$AGName');
"@ | Format-Table -AutoSize

Write-Host "AG Database Status:" -ForegroundColor Cyan
Invoke-Sqlcmd -ServerInstance $SqlInstance1 -Query @"
SELECT d.name AS database_name, drs.synchronization_state_desc, drs.synchronization_health_desc
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.databases d ON drs.database_id = d.database_id
WHERE drs.is_local = 1;
"@ | Format-Table -AutoSize

Write-Host "==> Done. Database '$DatabaseName' is now part of AG '$AGName'." -ForegroundColor Green