// Module: Virtual Network + Network Security Groups
param location string
param vnetName string
param vnetAddressPrefix string

type subnetConfig = {
  name: string
  addressPrefix: string
}

param subnets subnetConfig[]

// ─── Network Security Groups ───

resource nsgDc 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-dc-subnet'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowRDP'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3389'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource nsgSql1 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-sql-subnet-1'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSQL'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '1433'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowHADR'
        properties: {
          priority: 1100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '5022'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource nsgSql2 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-sql-subnet-2'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSQL'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '1433'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowHADR'
        properties: {
          priority: 1100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '5022'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// ─── Virtual Network ───

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [vnetAddressPrefix]
    }
    subnets: [
      {
        name: subnets[0].name
        properties: {
          addressPrefix: subnets[0].addressPrefix
          networkSecurityGroup: { id: nsgDc.id }
        }
      }
      {
        name: subnets[1].name
        properties: {
          addressPrefix: subnets[1].addressPrefix
          networkSecurityGroup: { id: nsgSql1.id }
        }
      }
      {
        name: subnets[2].name
        properties: {
          addressPrefix: subnets[2].addressPrefix
          networkSecurityGroup: { id: nsgSql2.id }
        }
      }
      {
        name: subnets[3].name
        properties: {
          addressPrefix: subnets[3].addressPrefix
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output subnetIds string[] = [for (s, i) in subnets: vnet.properties.subnets[i].id]
output nsgDcId string = nsgDc.id
output nsgSql1Id string = nsgSql1.id
output nsgSql2Id string = nsgSql2.id
