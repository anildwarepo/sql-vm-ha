// Module: Dedicated SQL HA subnets and NSGs in an existing virtual network
param location string
param vnetName string
param vpnClientAddressPrefix string

type subnetConfig = {
  name: string
  addressPrefix: string
}

param subnets subnetConfig[]

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource nsgDc 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-sql-ha-dc'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowRdpFromVpn'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: vpnClientAddressPrefix
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowSqlHaSubnetsInbound'
        properties: {
          priority: 1200
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefixes: [
            subnets[0].addressPrefix
            subnets[1].addressPrefix
            subnets[2].addressPrefix
          ]
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowAdFromVpn'
        properties: {
          priority: 1100
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRanges: [
            '53'
            '88'
            '135'
            '389'
            '445'
            '464'
            '636'
            '3268'
            '3269'
            '49152-65535'
          ]
          sourceAddressPrefix: vpnClientAddressPrefix
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource nsgSql1 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-sql-ha-sql-1'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowRdpFromVpn'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: vpnClientAddressPrefix
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowSqlListenerFromVpn'
        properties: {
          priority: 1010
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '14333'
          sourceAddressPrefix: vpnClientAddressPrefix
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowSqlFromSqlHaSubnets'
        properties: {
          priority: 1100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRanges: [
            '1433'
            '14333'
          ]
          sourceAddressPrefixes: [
            subnets[0].addressPrefix
            subnets[1].addressPrefix
            subnets[2].addressPrefix
          ]
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowHadrFromSqlHaSubnets'
        properties: {
          priority: 1110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '5022'
          sourceAddressPrefixes: [
            subnets[1].addressPrefix
            subnets[2].addressPrefix
          ]
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowWsfcFromSqlHaSubnets'
        properties: {
          priority: 1120
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefixes: [
            subnets[0].addressPrefix
            subnets[1].addressPrefix
            subnets[2].addressPrefix
          ]
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource nsgSql2 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-sql-ha-sql-2'
  location: location
  properties: {
    securityRules: nsgSql1.properties.securityRules
  }
}

@batchSize(1)
resource subnetsResources 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = [
  for (subnet, i) in subnets: {
    parent: vnet
    name: subnet.name
    properties: {
      addressPrefix: subnet.addressPrefix
      networkSecurityGroup: {
        id: i == 0 ? nsgDc.id : (i == 1 ? nsgSql1.id : nsgSql2.id)
      }
    }
  }
]

output vnetId string = vnet.id
output vnetName string = vnet.name
output subnetIds string[] = [for (subnet, i) in subnets: subnetsResources[i].id]
output nsgDcId string = nsgDc.id
output nsgSql1Id string = nsgSql1.id
output nsgSql2Id string = nsgSql2.id
