// Phase 1: Network + Domain Controllers
// SQL VMs are deployed in Phase 2 (postprovision hook)

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Admin username for all VMs')
param adminUsername string

@secure()
@description('Admin password for all VMs')
param adminPassword string

@description('Active Directory domain FQDN')
param domainFqdn string = 'contoso.local'

@description('AD domain NetBIOS name')
param domainNetBiosName string = 'CONTOSO'

@description('Name of the existing virtual network')
param existingVnetName string = 'vnet-westus'

@description('Resource group containing the existing virtual network')
param existingVnetResourceGroupName string = 'vnet'

@description('Point-to-site VPN client address prefix')
param vpnClientAddressPrefix string = '10.255.0.0/27'

@description('Dedicated domain controller subnet prefix')
param dcSubnetPrefix string = '10.0.9.0/24'

@description('Dedicated SQL replica 1 subnet prefix')
param sql1SubnetPrefix string = '10.0.10.0/24'

@description('Dedicated SQL replica 2 subnet prefix')
param sql2SubnetPrefix string = '10.0.11.0/24'

@description('Static private IP address for the domain controller')
param dcPrivateIp string = '10.0.9.4'

@description('Static private IP address for SQL-VM-1')
param sql1PrivateIp string = '10.0.10.4'

@description('Static private IP address for SQL-VM-2')
param sql2PrivateIp string = '10.0.11.4'

@description('WSFC IP address in SQL subnet 1')
param clusterIp1 string = '10.0.10.10'

@description('WSFC IP address in SQL subnet 2')
param clusterIp2 string = '10.0.11.10'

@description('AG listener IP address in SQL subnet 1')
param listenerIp1 string = '10.0.10.11'

@description('AG listener IP address in SQL subnet 2')
param listenerIp2 string = '10.0.11.11'

// --- Configuration ---

var subnets = [
  { name: 'sql-ha-dc', addressPrefix: dcSubnetPrefix }
  { name: 'sql-ha-sql-1', addressPrefix: sql1SubnetPrefix }
  { name: 'sql-ha-sql-2', addressPrefix: sql2SubnetPrefix }
]

var dcVmSize = 'Standard_D2s_v6'

// --- Module 1: Network (VNet + NSGs) ---

module network 'modules/network.bicep' = {
  scope: resourceGroup(existingVnetResourceGroupName)
  params: {
    location: location
    vnetName: existingVnetName
    vpnClientAddressPrefix: vpnClientAddressPrefix
    subnets: subnets
  }
}

// --- Module 2: Domain Controllers + AD Forest + DNS ---

module domainControllers 'modules/domain-controller.bicep' = {
  params: {
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    domainFqdn: domainFqdn
    domainNetBiosName: domainNetBiosName
    vmSize: dcVmSize
    dcSubnetId: network.outputs.subnetIds[0]
    dcVmName: 'DC-VM-1'
    dcPrivateIp: dcPrivateIp
  }
}

// --- Outputs (consumed by Phase 2) ---

output vnetId string = network.outputs.vnetId
output vnetName string = network.outputs.vnetName
output dcVmName string = domainControllers.outputs.dcVmName
output dcPrivateIp string = dcPrivateIp
output subnetIds string[] = network.outputs.subnetIds
output sqlPrivateIps string[] = [sql1PrivateIp, sql2PrivateIp]
output clusterIps string[] = [clusterIp1, clusterIp2]
output listenerIps string[] = [listenerIp1, listenerIp2]
output vpnClientAddressPrefix string = vpnClientAddressPrefix
output nsgDcId string = network.outputs.nsgDcId
output nsgSql1Id string = network.outputs.nsgSql1Id
output nsgSql2Id string = network.outputs.nsgSql2Id
