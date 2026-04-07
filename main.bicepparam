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
