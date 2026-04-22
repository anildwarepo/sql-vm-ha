// Phase 1: Network + Domain Controllers
// SQL VMs and Jumpbox are deployed in Phase 2 (postprovision hook)

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

// --- Configuration ---

var vnetName = 'vnet-sql-ha'
var vnetAddressPrefix = '10.38.0.0/16'
var dcPrivateIp = '10.38.0.4'

var subnets = [
  { name: 'DC-Subnet', addressPrefix: '10.38.0.0/24' }
  { name: 'SQL-Subnet-1', addressPrefix: '10.38.1.0/24' }
  { name: 'SQL-Subnet-2', addressPrefix: '10.38.2.0/24' }
  { name: 'Jumpbox-Subnet', addressPrefix: '10.38.3.0/24' }
]

var dcVmSize = 'Standard_D2s_v6'

// --- Module 1: Network (VNet + NSGs) ---

module network 'modules/network.bicep' = {
  params: {
    location: location
    vnetName: vnetName
    vnetAddressPrefix: vnetAddressPrefix
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
    vnetName: vnetName
    vnetAddressPrefix: vnetAddressPrefix
    dcSubnetId: network.outputs.subnetIds[0]
    dcVmName: 'DC-VM-1'
    dcPrivateIp: dcPrivateIp
    dcZone: '1'
    subnetsConfig: [
      { name: subnets[0].name, addressPrefix: subnets[0].addressPrefix, nsgId: network.outputs.nsgDcId }
      { name: subnets[1].name, addressPrefix: subnets[1].addressPrefix, nsgId: network.outputs.nsgSql1Id }
      { name: subnets[2].name, addressPrefix: subnets[2].addressPrefix, nsgId: network.outputs.nsgSql2Id }
    ]
    plainSubnets: [
      { name: subnets[3].name, addressPrefix: subnets[3].addressPrefix }
    ]
  }
}

// --- Outputs (consumed by Phase 2) ---

output vnetId string = network.outputs.vnetId
output vnetName string = network.outputs.vnetName
output dcVmName string = domainControllers.outputs.dcVmName
output dcPrivateIp string = dcPrivateIp
output subnetIds string[] = network.outputs.subnetIds
output nsgDcId string = network.outputs.nsgDcId
output nsgSql1Id string = network.outputs.nsgSql1Id
output nsgSql2Id string = network.outputs.nsgSql2Id
