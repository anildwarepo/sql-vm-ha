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

// --- Configuration ---

var vnetName = 'vnet-sql-ha'
var vnetAddressPrefix = '10.38.0.0/16'

var subnets = [
  { name: 'DC-Subnet', addressPrefix: '10.38.0.0/24' }
  { name: 'SQL-Subnet-1', addressPrefix: '10.38.1.0/24' }
  { name: 'SQL-Subnet-2', addressPrefix: '10.38.2.0/24' }
]

var dcVmSize = 'Standard_D2s_v6'
var sqlVmSize = 'Standard_D4s_v6'

var dcVms = [
  { name: 'DC-VM-1', zone: '1', privateIpAddress: '10.38.0.4' }
  { name: 'DC-VM-2', zone: '2', privateIpAddress: '10.38.0.5' }
]

var sqlVms = [
  { name: 'SQL-VM-1', zone: '1', subnetIndex: 0, privateIpAddress: '10.38.1.4', clusterIp: '10.38.1.10', listenerIp: '10.38.1.11' }
  { name: 'SQL-VM-2', zone: '2', subnetIndex: 1, privateIpAddress: '10.38.2.4', clusterIp: '10.38.2.10', listenerIp: '10.38.2.11' }
]

// --- Module 1: Network (VNet + NSGs) ---

module network 'modules/network.bicep' = {
  params: {
    location: location
    vnetName: vnetName
    vnetAddressPrefix: vnetAddressPrefix
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
    vnetName: vnetName
    vnetAddressPrefix: vnetAddressPrefix
    dcSubnetId: network.outputs.subnetIds[0]
    dcVms: dcVms
    subnetsConfig: [
      { name: subnets[0].name, addressPrefix: subnets[0].addressPrefix, nsgId: network.outputs.nsgDcId }
      { name: subnets[1].name, addressPrefix: subnets[1].addressPrefix, nsgId: network.outputs.nsgSql1Id }
      { name: subnets[2].name, addressPrefix: subnets[2].addressPrefix, nsgId: network.outputs.nsgSql2Id }
    ]
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
