// Phase 2: Jumpbox + SQL VMs (domain-joined, standalone IaaS Agent)
// WSFC cluster, AG, and listener are configured by postprovision script

@description('Azure region')
param location string = resourceGroup().location

@description('Admin username')
param adminUsername string

@secure()
@description('Admin password')
param adminPassword string

@description('Active Directory domain FQDN')
param domainFqdn string = 'contoso.local'

@description('AD domain NetBIOS name')
param domainNetBiosName string = 'CONTOSO'

@description('OU path for domain join')
param ouPath string = ''

param sqlImageOffer string = 'sql2022-ws2022'

@allowed(['Enterprise', 'Developer', 'Standard'])
param sqlImageSku string = 'Enterprise'

@description('Your public IP for jump box RDP access')
param allowedSourceIp string

@description('DC private IP address from Phase 1')
param dcPrivateIp string

@description('Subnet IDs from Phase 1 [DC, SQL-1, SQL-2, Jumpbox]')
param subnetIds string[]

// --- Configuration ---

var sqlVmSize = 'Standard_D4s_v6'

var sqlVms = [
  { name: 'SQL-VM-1', zone: '1', subnetIndex: 0, privateIpAddress: '10.38.1.4', clusterIp: '10.38.1.10', listenerIp: '10.38.1.11' }
  { name: 'SQL-VM-2', zone: '2', subnetIndex: 1, privateIpAddress: '10.38.2.4', clusterIp: '10.38.2.10', listenerIp: '10.38.2.11' }
]

// --- Jumpbox ---

module jumpbox 'modules/jumpbox.bicep' = {
  params: {
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    subnetId: subnetIds[3]
    allowedSourceIp: allowedSourceIp
  }
}

// --- SQL VMs (standalone – WSFC/AG configured post-deploy) ---

module sqlServers 'modules/sql-vm.bicep' = {
  params: {
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    domainFqdn: domainFqdn
    domainNetBiosName: domainNetBiosName
    dcPrivateIp: dcPrivateIp
    ouPath: ouPath
    vmSize: sqlVmSize
    sqlImageOffer: sqlImageOffer
    sqlImageSku: sqlImageSku
    sqlSubnetIds: [subnetIds[1], subnetIds[2]]
    sqlVms: sqlVms
  }
}

// --- Outputs ---

output jumpboxPublicIp string = jumpbox.outputs.jumpboxPublicIp
output sqlVmNames string[] = sqlServers.outputs.sqlVmNames
