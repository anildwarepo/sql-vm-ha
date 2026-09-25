// Phase 2: SQL VMs (domain-joined, standalone IaaS Agent)
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

@description('DC private IP address from Phase 1')
param dcPrivateIp string

@description('Subnet IDs from Phase 1 [DC, SQL-1, SQL-2]')
param subnetIds string[]

@description('Static private IP addresses for SQL-VM-1 and SQL-VM-2')
param sqlPrivateIps string[]

@description('WSFC IP addresses for SQL subnet 1 and SQL subnet 2')
param clusterIps string[]

@description('AG listener IP addresses for SQL subnet 1 and SQL subnet 2')
param listenerIps string[]

// --- Configuration ---

var sqlVmSize = 'Standard_D4s_v6'
var sqlVms = [
  { name: 'SQL-VM-1', subnetIndex: 0, privateIpAddress: sqlPrivateIps[0], clusterIp: clusterIps[0], listenerIp: listenerIps[0] }
  { name: 'SQL-VM-2', subnetIndex: 1, privateIpAddress: sqlPrivateIps[1], clusterIp: clusterIps[1], listenerIp: listenerIps[1] }
]

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

output sqlVmNames string[] = sqlServers.outputs.sqlVmNames
