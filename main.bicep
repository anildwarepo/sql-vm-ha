// SQL Server AlwaysOn Availability Group - Multi-Subnet HA Deployment
// Orchestrates: network, domain-controller, and sql-vm modules

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

@description('OU path for WSFC cluster objects')
param ouPath string = ''

@description('SQL service account (UPN format: user@domain)')
param sqlServiceAccount string = 'sqlservice@contoso.local'

@secure()
@description('SQL service account password')
param sqlServiceAccountPassword string

@description('Cluster operator account (UPN format: user@domain)')
param clusterOperatorAccount string = 'clusteradmin@contoso.local'

@secure()
@description('Cluster operator account password')
param clusterOperatorAccountPassword string

@description('Cluster bootstrap account (UPN format: user@domain)')
param clusterBootstrapAccount string = 'clusteradmin@contoso.local'

@secure()
@description('Cluster bootstrap account password')
param clusterBootstrapAccountPassword string

@description('SQL Server image offer')
param sqlImageOffer string = 'sql2022-ws2022'

@description('SQL Server image SKU')
@allowed(['Enterprise', 'Developer', 'Standard'])
param sqlImageSku string = 'Enterprise'

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

@description('Static private IP addresses for the domain controllers')
param dcPrivateIps string[] = [
  '10.0.9.4'
  '10.0.9.5'
]

@description('Static private IP addresses for the SQL VMs')
param sqlPrivateIps string[] = [
  '10.0.10.4'
  '10.0.11.4'
]

@description('WSFC IP addresses for SQL subnet 1 and SQL subnet 2')
param clusterIps string[] = [
  '10.0.10.10'
  '10.0.11.10'
]

@description('AG listener IP addresses for SQL subnet 1 and SQL subnet 2')
param listenerIps string[] = [
  '10.0.10.11'
  '10.0.11.11'
]

// --- Configuration ---

var subnets = [
  { name: 'sql-ha-dc', addressPrefix: dcSubnetPrefix }
  { name: 'sql-ha-sql-1', addressPrefix: sql1SubnetPrefix }
  { name: 'sql-ha-sql-2', addressPrefix: sql2SubnetPrefix }
]

var dcVmSize = 'Standard_D2s_v6'
var sqlVmSize = 'Standard_D4s_v6'

var dcVms = [
  { name: 'DC-VM-1', privateIpAddress: dcPrivateIps[0] }
  { name: 'DC-VM-2', privateIpAddress: dcPrivateIps[1] }
]

var sqlVms = [
  { name: 'SQL-VM-1', subnetIndex: 0, privateIpAddress: sqlPrivateIps[0], clusterIp: clusterIps[0], listenerIp: listenerIps[0] }
  { name: 'SQL-VM-2', subnetIndex: 1, privateIpAddress: sqlPrivateIps[1], clusterIp: clusterIps[1], listenerIp: listenerIps[1] }
]

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

// --- Module 2: Domain Controllers + AD Forest ---

module domainControllers 'modules/domain-controller.bicep' = {
  params: {
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    domainFqdn: domainFqdn
    domainNetBiosName: domainNetBiosName
    vmSize: dcVmSize
    dcSubnetId: network.outputs.subnetIds[0]
    dcVms: dcVms
  }
}

// --- Module 3: SQL VMs + WSFC + AG ---

module sqlServers 'modules/sql-vm.bicep' = {
  params: {
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    domainFqdn: domainFqdn
    domainNetBiosName: domainNetBiosName
    ouPath: ouPath
    vmSize: sqlVmSize
    sqlImageOffer: sqlImageOffer
    sqlImageSku: sqlImageSku
    sqlServiceAccount: sqlServiceAccount
    sqlServiceAccountPassword: sqlServiceAccountPassword
    clusterOperatorAccount: clusterOperatorAccount
    clusterOperatorAccountPassword: clusterOperatorAccountPassword
    clusterBootstrapAccount: clusterBootstrapAccount
    clusterBootstrapAccountPassword: clusterBootstrapAccountPassword
    sqlSubnetIds: [network.outputs.subnetIds[1], network.outputs.subnetIds[2]]
    dcPrivateIp: dcPrivateIps[0]
    sqlVms: sqlVms
  }
  dependsOn: [domainControllers]
}

// --- Outputs ---

output vnetId string = network.outputs.vnetId
output dcVmNames string[] = domainControllers.outputs.dcVmNames
output sqlVmNames string[] = sqlServers.outputs.sqlVmNames
output sqlVmGroupName string = sqlServers.outputs.sqlVmGroupName
output agListenerName string = sqlServers.outputs.agListenerName
