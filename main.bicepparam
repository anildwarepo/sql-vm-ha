using 'main.bicep'

param adminUsername = 'azureadmin'
param adminPassword = readEnvironmentVariable('ADMIN_PASSWORD')

param domainFqdn = 'contoso.local'
param domainNetBiosName = 'CONTOSO'
param ouPath = ''

param sqlServiceAccount = 'sqlservice@contoso.local'
param sqlServiceAccountPassword = readEnvironmentVariable('SQL_SERVICE_PASSWORD')

param clusterOperatorAccount = 'clusteradmin@contoso.local'
param clusterOperatorAccountPassword = readEnvironmentVariable('CLUSTER_OPERATOR_PASSWORD')

param clusterBootstrapAccount = 'clusteradmin@contoso.local'
param clusterBootstrapAccountPassword = readEnvironmentVariable('CLUSTER_BOOTSTRAP_PASSWORD')

param sqlImageOffer = 'sql2022-ws2022'
param sqlImageSku = 'Enterprise'

param existingVnetName = 'vnet-westus'
param existingVnetResourceGroupName = 'vnet'
param vpnClientAddressPrefix = '10.255.0.0/27'
param dcSubnetPrefix = '10.0.9.0/24'
param sql1SubnetPrefix = '10.0.10.0/24'
param sql2SubnetPrefix = '10.0.11.0/24'
param dcPrivateIps = [
  '10.0.9.4'
  '10.0.9.5'
]
param sqlPrivateIps = [
  '10.0.10.4'
  '10.0.11.4'
]
param clusterIps = [
  '10.0.10.10'
  '10.0.11.10'
]
param listenerIps = [
  '10.0.10.11'
  '10.0.11.11'
]
