<#
.SYNOPSIS
    Validates the existing VNet and dedicated SQL HA network ranges before provisioning.
#>

[CmdletBinding()]
param(
    [string]$VnetName,
    [string]$VnetResourceGroupName,
    [string]$Location,
    [string]$DcSubnetPrefix,
    [string]$Sql1SubnetPrefix,
    [string]$Sql2SubnetPrefix,
    [string]$DcPrivateIp,
    [string]$Sql1PrivateIp,
    [string]$Sql2PrivateIp,
    [string]$ClusterIp1,
    [string]$ClusterIp2,
    [string]$ListenerIp1,
    [string]$ListenerIp2
)

$ErrorActionPreference = 'Stop'
$env:AZURE_CORE_ONLY_SHOW_ERRORS = 'true'

function Get-AzdEnvironmentValue {
    param([Parameter(Mandatory)][string]$Name)

    $ErrorActionPreference = 'Continue'
    $value = "$(azd env get-value $Name 2>$null)".Trim()
    $ErrorActionPreference = 'Stop'
    return $value
}

function ConvertTo-IpNumber {
    param([Parameter(Mandatory)][string]$IpAddress)

    $parsed = [System.Net.IPAddress]::Parse($IpAddress)
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "Only IPv4 addresses are supported: $IpAddress"
    }

    $bytes = $parsed.GetAddressBytes()
    [Array]::Reverse($bytes)
    return [BitConverter]::ToUInt32($bytes, 0)
}

function Get-CidrRange {
    param([Parameter(Mandatory)][string]$Cidr)

    $parts = $Cidr.Split('/')
    if ($parts.Count -ne 2) {
        throw "Invalid IPv4 CIDR: $Cidr"
    }

    $prefixLength = [int]$parts[1]
    if ($prefixLength -lt 0 -or $prefixLength -gt 32) {
        throw "Invalid IPv4 prefix length: $Cidr"
    }

    [uint64]$ip = ConvertTo-IpNumber $parts[0]
    [uint64]$hostRange = [math]::Pow(2, 32 - $prefixLength) - 1
    [uint64]$mask = [uint64]4294967295 - $hostRange
    [uint64]$network = $ip -band $mask
    [uint64]$broadcast = $network + $hostRange

    return [pscustomobject]@{
        Network = $network
        Broadcast = $broadcast
        PrefixLength = $prefixLength
    }
}

function Test-CidrContainsCidr {
    param(
        [Parameter(Mandatory)][string]$OuterCidr,
        [Parameter(Mandatory)][string]$InnerCidr
    )

    $outer = Get-CidrRange $OuterCidr
    $inner = Get-CidrRange $InnerCidr
    return $inner.Network -ge $outer.Network -and $inner.Broadcast -le $outer.Broadcast
}

function Test-CidrOverlap {
    param(
        [Parameter(Mandatory)][string]$FirstCidr,
        [Parameter(Mandatory)][string]$SecondCidr
    )

    $first = Get-CidrRange $FirstCidr
    $second = Get-CidrRange $SecondCidr
    return $first.Network -le $second.Broadcast -and $second.Network -le $first.Broadcast
}

function Assert-UsableSubnetIp {
    param(
        [Parameter(Mandatory)][string]$IpAddress,
        [Parameter(Mandatory)][string]$SubnetPrefix
    )

    $range = Get-CidrRange $SubnetPrefix
    [uint64]$ip = ConvertTo-IpNumber $IpAddress
    if ($ip -lt ($range.Network + 4) -or $ip -ge $range.Broadcast) {
        throw "IP address $IpAddress is not a usable Azure host address in $SubnetPrefix."
    }
}

if (-not $VnetName) { $VnetName = Get-AzdEnvironmentValue 'AZURE_EXISTING_VNET_NAME' }
if (-not $VnetResourceGroupName) { $VnetResourceGroupName = Get-AzdEnvironmentValue 'AZURE_EXISTING_VNET_RESOURCE_GROUP' }
if (-not $Location) { $Location = Get-AzdEnvironmentValue 'AZURE_LOCATION' }
if (-not $DcSubnetPrefix) { $DcSubnetPrefix = Get-AzdEnvironmentValue 'AZURE_DC_SUBNET_PREFIX' }
if (-not $Sql1SubnetPrefix) { $Sql1SubnetPrefix = Get-AzdEnvironmentValue 'AZURE_SQL1_SUBNET_PREFIX' }
if (-not $Sql2SubnetPrefix) { $Sql2SubnetPrefix = Get-AzdEnvironmentValue 'AZURE_SQL2_SUBNET_PREFIX' }
if (-not $DcPrivateIp) { $DcPrivateIp = Get-AzdEnvironmentValue 'AZURE_DC_PRIVATE_IP' }
if (-not $Sql1PrivateIp) { $Sql1PrivateIp = Get-AzdEnvironmentValue 'AZURE_SQL1_PRIVATE_IP' }
if (-not $Sql2PrivateIp) { $Sql2PrivateIp = Get-AzdEnvironmentValue 'AZURE_SQL2_PRIVATE_IP' }
if (-not $ClusterIp1) { $ClusterIp1 = Get-AzdEnvironmentValue 'AZURE_CLUSTER_IP1' }
if (-not $ClusterIp2) { $ClusterIp2 = Get-AzdEnvironmentValue 'AZURE_CLUSTER_IP2' }
if (-not $ListenerIp1) { $ListenerIp1 = Get-AzdEnvironmentValue 'AZURE_LISTENER_IP1' }
if (-not $ListenerIp2) { $ListenerIp2 = Get-AzdEnvironmentValue 'AZURE_LISTENER_IP2' }

$requiredValues = @{
    VnetName = $VnetName
    VnetResourceGroupName = $VnetResourceGroupName
    Location = $Location
    DcSubnetPrefix = $DcSubnetPrefix
    Sql1SubnetPrefix = $Sql1SubnetPrefix
    Sql2SubnetPrefix = $Sql2SubnetPrefix
    DcPrivateIp = $DcPrivateIp
    Sql1PrivateIp = $Sql1PrivateIp
    Sql2PrivateIp = $Sql2PrivateIp
    ClusterIp1 = $ClusterIp1
    ClusterIp2 = $ClusterIp2
    ListenerIp1 = $ListenerIp1
    ListenerIp2 = $ListenerIp2
}

$missingValues = @($requiredValues.GetEnumerator() | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Value) } | ForEach-Object Key)
if ($missingValues.Count -gt 0) {
    throw "Missing required network configuration: $($missingValues -join ', ')"
}

$vnet = az network vnet show --resource-group $VnetResourceGroupName --name $VnetName --output json 2>$null | ConvertFrom-Json
if (-not $vnet) {
    throw "Existing VNet '$VnetName' was not found in resource group '$VnetResourceGroupName'."
}
if ($vnet.location -ne $Location) {
    throw "VNet '$VnetName' is in '$($vnet.location)', but the deployment location is '$Location'."
}

$plannedSubnets = @(
    [pscustomobject]@{ Name = 'sql-ha-dc'; Prefix = $DcSubnetPrefix },
    [pscustomobject]@{ Name = 'sql-ha-sql-1'; Prefix = $Sql1SubnetPrefix },
    [pscustomobject]@{ Name = 'sql-ha-sql-2'; Prefix = $Sql2SubnetPrefix }
)

for ($i = 0; $i -lt $plannedSubnets.Count; $i++) {
    for ($j = $i + 1; $j -lt $plannedSubnets.Count; $j++) {
        if (Test-CidrOverlap -FirstCidr $plannedSubnets[$i].Prefix -SecondCidr $plannedSubnets[$j].Prefix) {
            throw "Planned subnets $($plannedSubnets[$i].Name) and $($plannedSubnets[$j].Name) overlap."
        }
    }
}

foreach ($plannedSubnet in $plannedSubnets) {
    $contained = @($vnet.addressSpace.addressPrefixes | Where-Object {
        Test-CidrContainsCidr -OuterCidr $_ -InnerCidr $plannedSubnet.Prefix
    }).Count -gt 0
    if (-not $contained) {
        throw "Subnet $($plannedSubnet.Name) prefix $($plannedSubnet.Prefix) is outside the VNet address spaces."
    }

    foreach ($existingSubnet in $vnet.subnets) {
        if ($existingSubnet.name -eq $plannedSubnet.Name) {
            if ($existingSubnet.addressPrefix -ne $plannedSubnet.Prefix) {
                throw "Existing subnet $($plannedSubnet.Name) uses $($existingSubnet.addressPrefix), not $($plannedSubnet.Prefix)."
            }
            continue
        }
        if (Test-CidrOverlap -FirstCidr $plannedSubnet.Prefix -SecondCidr $existingSubnet.addressPrefix) {
            throw "Subnet $($plannedSubnet.Name) prefix $($plannedSubnet.Prefix) overlaps existing subnet $($existingSubnet.name) ($($existingSubnet.addressPrefix))."
        }
    }
}

Assert-UsableSubnetIp -IpAddress $DcPrivateIp -SubnetPrefix $DcSubnetPrefix
foreach ($ip in @($Sql1PrivateIp, $ClusterIp1, $ListenerIp1)) {
    Assert-UsableSubnetIp -IpAddress $ip -SubnetPrefix $Sql1SubnetPrefix
}
foreach ($ip in @($Sql2PrivateIp, $ClusterIp2, $ListenerIp2)) {
    Assert-UsableSubnetIp -IpAddress $ip -SubnetPrefix $Sql2SubnetPrefix
}

$plannedIps = @($DcPrivateIp, $Sql1PrivateIp, $Sql2PrivateIp, $ClusterIp1, $ClusterIp2, $ListenerIp1, $ListenerIp2)
if (@($plannedIps | Sort-Object -Unique).Count -ne $plannedIps.Count) {
    throw 'Static private IP addresses must be unique.'
}

Write-Host "[OK] Existing VNet and SQL HA subnet configuration passed preflight validation." -ForegroundColor Green
