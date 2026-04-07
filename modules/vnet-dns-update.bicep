// Module to update VNet DNS servers after AD DS is installed
param vnetName string
param location string
param vnetAddressPrefix string
param dnsServers string[]

type subnetEntry = {
  name: string
  addressPrefix: string
  nsgId: string
}

param subnetsConfig subnetEntry[]

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [vnetAddressPrefix]
    }
    dhcpOptions: {
      dnsServers: dnsServers
    }
    subnets: [
      for subnet in subnetsConfig: {
        name: subnet.name
        properties: {
          addressPrefix: subnet.addressPrefix
          networkSecurityGroup: { id: subnet.nsgId }
        }
      }
    ]
  }
}
