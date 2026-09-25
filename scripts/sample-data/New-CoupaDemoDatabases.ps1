<#
.SYNOPSIS
    Creates the Coupa demo databases (CoupaProcurement, CoupaInvoicing, CoupaExpenses)
    and adds them to the Always On availability group.

.DESCRIPTION
    1. Connects to the AG primary (through the listener by default) with SQL authentication.
    2. Optionally (-Recreate) removes the demo databases from the AG and drops them everywhere.
    3. Runs CoupaDemo.sql (idempotent schema + seed data).
    4. Grants the AG CREATE ANY DATABASE on each secondary, takes a full backup to NUL
       (satisfies the AG prerequisite; not a real backup) and adds each database to the AG
       using automatic seeding, then waits until every replica is SYNCHRONIZED.

    Defaults come from the azd environment (AZURE_SQL_ADMIN_LOGIN / AZURE_SQL_ADMIN_PASSWORD,
    AZURE_LISTENER_IP1, AZURE_SQL2_PRIVATE_IP). Run from a VPN-connected workstation.

.EXAMPLE
    .\scripts\sample-data\New-CoupaDemoDatabases.ps1

.EXAMPLE
    .\scripts\sample-data\New-CoupaDemoDatabases.ps1 -Recreate
#>
[CmdletBinding()]
param(
    [string]$Server,
    [string[]]$SecondaryServers,
    [string]$SqlLogin,
    [string]$SqlPassword,
    [string]$AvailabilityGroup = 'ag-sql-ha',
    [switch]$SkipAvailabilityGroup,
    [switch]$Recreate,
    [int]$SeedingTimeoutMinutes = 15
)

$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$sqlFile = Join-Path $PSScriptRoot 'CoupaDemo.sql'
$databases = 'CoupaProcurement', 'CoupaInvoicing', 'CoupaExpenses'

. (Join-Path $repoRoot 'scripts\arc\ArcEvalCommon.ps1')
$azdEnv = Get-AzdEnvironmentValues -RepoRoot $repoRoot
if (-not $SqlLogin) { $SqlLogin = $azdEnv['AZURE_SQL_ADMIN_LOGIN'] }
if (-not $SqlPassword) { $SqlPassword = $azdEnv['AZURE_SQL_ADMIN_PASSWORD'] }
if (-not $Server) {
    $listenerIp = if ($azdEnv['AZURE_LISTENER_IP1']) { $azdEnv['AZURE_LISTENER_IP1'] } else { '10.0.10.11' }
    $Server = "$listenerIp,14333"
}
if (-not $SecondaryServers) {
    $sql2 = if ($azdEnv['AZURE_SQL2_PRIVATE_IP']) { $azdEnv['AZURE_SQL2_PRIVATE_IP'] } else { '10.0.11.4' }
    $SecondaryServers = @("$sql2,1433")
}
if (-not $SqlLogin -or -not $SqlPassword) { throw 'Provide -SqlLogin/-SqlPassword or set AZURE_SQL_ADMIN_LOGIN/AZURE_SQL_ADMIN_PASSWORD in the azd environment.' }

function New-ConnectionString([string]$DataSource) {
    $quotedPassword = '"' + $SqlPassword.Replace('"', '""') + '"'
    "Server=$DataSource;Database=master;User ID=$SqlLogin;Password=$quotedPassword;Encrypt=True;TrustServerCertificate=True;Connect Timeout=20;MultiSubnetFailover=True;Application Name=CoupaDemoLoader"
}

function Invoke-Sql {
    param([string]$DataSource, [string]$Query, [switch]$Scalar, [switch]$Rows)
    $conn = New-Object System.Data.SqlClient.SqlConnection (New-ConnectionString $DataSource)
    $conn.add_InfoMessage({ param($s, $e) Write-Host "    $($e.Message)" -ForegroundColor DarkGray })
    $conn.Open()
    try {
        $result = $null
        # Split on GO batch separators, like sqlcmd/SSMS.
        foreach ($batch in [regex]::Split($Query, '^\s*GO\s*$', 'Multiline, IgnoreCase')) {
            if ([string]::IsNullOrWhiteSpace($batch)) { continue }
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = $batch
            $cmd.CommandTimeout = 900
            if ($Scalar) { $result = $cmd.ExecuteScalar() }
            elseif ($Rows) {
                $table = New-Object System.Data.DataTable
                $table.Load($cmd.ExecuteReader())
                $result = $table
            }
            else { [void]$cmd.ExecuteNonQuery() }
        }
        return $result
    }
    finally { $conn.Close() }
}

Write-Host "`n==> Connecting to $Server as $SqlLogin" -ForegroundColor Cyan
$primaryName = Invoke-Sql $Server 'SELECT @@SERVERNAME' -Scalar
Write-Host "  Connected to $primaryName" -ForegroundColor Green

if (-not $SkipAvailabilityGroup) {
    $role = Invoke-Sql $Server @"
SELECT rs.role_desc FROM sys.dm_hadr_availability_replica_states rs
JOIN sys.availability_groups ag ON ag.group_id = rs.group_id
WHERE rs.is_local = 1 AND ag.name = N'$AvailabilityGroup'
"@ -Scalar
    if ($role -ne 'PRIMARY') { throw "$primaryName is not the PRIMARY replica of '$AvailabilityGroup' (role: $role)." }
}

$dbList = ($databases | ForEach-Object { "N'$_'" }) -join ', '

if ($Recreate) {
    Write-Host "`n==> Dropping existing demo databases" -ForegroundColor Cyan
    foreach ($db in $databases) {
        if (-not $SkipAvailabilityGroup) {
            Invoke-Sql $Server @"
IF EXISTS (SELECT 1 FROM sys.availability_databases_cluster adc JOIN sys.availability_groups ag ON ag.group_id = adc.group_id
           WHERE ag.name = N'$AvailabilityGroup' AND adc.database_name = N'$db')
    ALTER AVAILABILITY GROUP [$AvailabilityGroup] REMOVE DATABASE [$db];
"@
            foreach ($secondary in $SecondaryServers) {
                # After REMOVE DATABASE the secondary copy goes to RESTORING and can be briefly held by
                # the redo thread or agent sessions (Arc/Defender), so kill sessions and retry.
                Invoke-Sql $secondary @"
DECLARE @attempt int = 0, @kill nvarchar(max);
WHILE DB_ID(N'$db') IS NOT NULL AND @attempt < 12
BEGIN
    SET @attempt += 1;
    SET @kill = N'';
    SELECT @kill += N'KILL ' + CAST(session_id AS nvarchar(10)) + N';'
    FROM sys.dm_exec_sessions WHERE database_id = DB_ID(N'$db') AND session_id <> @@SPID AND is_user_process = 1;
    EXEC (@kill);
    BEGIN TRY
        DROP DATABASE [$db];
    END TRY
    BEGIN CATCH
        IF @attempt = 12 THROW;
        WAITFOR DELAY '00:00:05';
    END CATCH
END
"@
            }
        }
        Invoke-Sql $Server @"
IF DB_ID(N'$db') IS NOT NULL
BEGIN
    ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$db];
END
"@
        Write-Host "  Dropped $db" -ForegroundColor Gray
    }
}

Write-Host "`n==> Creating schema and seed data ($(Split-Path $sqlFile -Leaf))" -ForegroundColor Cyan
Invoke-Sql $Server (Get-Content $sqlFile -Raw)
Write-Host '  Schema and data ready' -ForegroundColor Green

if (-not $SkipAvailabilityGroup) {
    Write-Host "`n==> Adding databases to availability group '$AvailabilityGroup'" -ForegroundColor Cyan
    foreach ($secondary in $SecondaryServers) {
        Invoke-Sql $secondary "ALTER AVAILABILITY GROUP [$AvailabilityGroup] GRANT CREATE ANY DATABASE;"
        Write-Host "  Granted CREATE ANY DATABASE on $secondary" -ForegroundColor Gray
    }
    foreach ($db in $databases) {
        $inAg = Invoke-Sql $Server "SELECT COUNT(*) FROM sys.availability_databases_cluster WHERE database_name = N'$db'" -Scalar
        if ($inAg -gt 0) { Write-Host "  $db is already in the AG" -ForegroundColor Gray; continue }
        Invoke-Sql $Server @"
BACKUP DATABASE [$db] TO DISK = N'NUL' WITH NO_COMPRESSION;
ALTER AVAILABILITY GROUP [$AvailabilityGroup] ADD DATABASE [$db];
"@
        Write-Host "  Added $db (automatic seeding)" -ForegroundColor Gray
    }

    $replicaCount = Invoke-Sql $Server "SELECT COUNT(*) FROM sys.availability_replicas ar JOIN sys.availability_groups ag ON ag.group_id = ar.group_id WHERE ag.name = N'$AvailabilityGroup'" -Scalar
    $expected = $replicaCount * $databases.Count
    $deadline = (Get-Date).AddMinutes($SeedingTimeoutMinutes)
    do {
        $synced = Invoke-Sql $Server @"
SELECT COUNT(*) FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_databases_cluster adc ON adc.group_database_id = drs.group_database_id
JOIN sys.availability_groups ag ON ag.group_id = drs.group_id
WHERE ag.name = N'$AvailabilityGroup' AND adc.database_name IN ($dbList)
  AND drs.synchronization_state_desc = 'SYNCHRONIZED'
"@ -Scalar
        if ($synced -ge $expected) { break }
        Write-Host "  Waiting for seeding/synchronization ($synced/$expected replicas synchronized)..." -ForegroundColor Gray
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    if ($synced -ge $expected) { Write-Host "  All $expected database replicas SYNCHRONIZED" -ForegroundColor Green }
    else { Write-Warning "Only $synced/$expected database replicas are SYNCHRONIZED after $SeedingTimeoutMinutes minutes." }
}

Write-Host "`n==> Row counts" -ForegroundColor Cyan
$counts = Invoke-Sql $Server @"
SELECT 'CoupaProcurement' AS [Database], t.name AS [Table], SUM(p.rows) AS [Rows]
FROM CoupaProcurement.sys.tables t JOIN CoupaProcurement.sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
GROUP BY t.name
UNION ALL
SELECT 'CoupaInvoicing', t.name, SUM(p.rows)
FROM CoupaInvoicing.sys.tables t JOIN CoupaInvoicing.sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
GROUP BY t.name
UNION ALL
SELECT 'CoupaExpenses', t.name, SUM(p.rows)
FROM CoupaExpenses.sys.tables t JOIN CoupaExpenses.sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
GROUP BY t.name
ORDER BY 1, 2
"@ -Rows
$counts | Format-Table -AutoSize | Out-String | Write-Host
