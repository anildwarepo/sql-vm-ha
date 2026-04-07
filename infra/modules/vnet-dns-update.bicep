// Module to update VNet DNS servers after AD DS is installed
// Uses existing VNet and only patches the dhcpOptions to avoid redeploying subnets
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

// Additional subnets without NSGs (e.g., jumpbox)
type plainSubnetEntry = {
  name: string
  addressPrefix: string
}

param plainSubnets plainSubnetEntry[] = []

var nsgSubnetList = [for subnet in subnetsConfig: {
  name: subnet.name
  properties: {
    addressPrefix: subnet.addressPrefix
    networkSecurityGroup: { id: subnet.nsgId }
  }
}]

var plainSubnetList = [for subnet in plainSubnets: {
  name: subnet.name
  properties: {
    addressPrefix: subnet.addressPrefix
  }
}]

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
    subnets: concat(nsgSubnetList, plainSubnetList)
  }
}
