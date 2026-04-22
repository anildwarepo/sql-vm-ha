// Module: SQL Server VMs, domain join, SQL IaaS Agent (standalone)
param location string
param adminUsername string

@secure()
param adminPassword string

param domainFqdn string
param domainNetBiosName string
param dcPrivateIp string
param ouPath string
param vmSize string
param sqlImageOffer string

@allowed(['Enterprise', 'Developer', 'Standard'])
param sqlImageSku string

// Networking
param sqlSubnetIds string[]

type sqlVmConfig = {
  name: string
  zone: string
  subnetIndex: int
  privateIpAddress: string
  clusterIp: string
  listenerIp: string
}

param sqlVms sqlVmConfig[]

var domainJoinUser = '${domainNetBiosName}\\${adminUsername}'
var domainJoinBaseSettings = {
  Name: domainFqdn
  User: domainJoinUser
  Restart: 'true'
  Options: 3
}
var domainJoinSettings = empty(ouPath)
  ? domainJoinBaseSettings
  : union(domainJoinBaseSettings, {
      OUPath: ouPath
    })
var sqlVmImageSku = '${toLower(sqlImageSku)}-gen2'

// ─── SQL VM NICs ───

resource sqlNics 'Microsoft.Network/networkInterfaces@2024-05-01' = [
  for (vm, i) in sqlVms: {
    name: 'nic-${toLower(vm.name)}'
    location: location
    properties: {
      dnsSettings: {
        dnsServers: [
          dcPrivateIp
          '168.63.129.16'
        ]
      }
      ipConfigurations: [
        {
          name: 'ipconfig1'
          properties: {
            privateIPAllocationMethod: 'Static'
            privateIPAddress: vm.privateIpAddress
            subnet: {
              id: sqlSubnetIds[vm.subnetIndex]
            }
          }
        }
      ]
    }
  }
]

// ─── SQL Server VMs ───

resource sqlVmResources 'Microsoft.Compute/virtualMachines@2024-07-01' = [
  for (vm, i) in sqlVms: {
    name: vm.name
    location: location
    zones: [vm.zone]
    properties: {
      hardwareProfile: {
        vmSize: vmSize
      }
      osProfile: {
        computerName: vm.name
        adminUsername: adminUsername
        adminPassword: adminPassword
      }
      storageProfile: {
        imageReference: {
          publisher: 'MicrosoftSQLServer'
          offer: sqlImageOffer
          sku: sqlVmImageSku
          version: 'latest'
        }
        osDisk: {
          createOption: 'FromImage'
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
        dataDisks: [
          {
            lun: 0
            createOption: 'Empty'
            diskSizeGB: 256
            managedDisk: {
              storageAccountType: 'Premium_LRS'
            }
            caching: 'ReadOnly'
          }
          {
            lun: 1
            createOption: 'Empty'
            diskSizeGB: 128
            managedDisk: {
              storageAccountType: 'Premium_LRS'
            }
            caching: 'None'
          }
        ]
      }
      networkProfile: {
        networkInterfaces: [
          {
            id: sqlNics[i].id
          }
        ]
      }
    }
  }
]

// ─── Domain Join (JsonADDomainExtension) ───

resource domainJoin 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = [
  for (vm, i) in sqlVms: {
    parent: sqlVmResources[i]
    name: 'JoinDomainNative'
    location: location
    properties: {
      publisher: 'Microsoft.Compute'
      type: 'JsonADDomainExtension'
      typeHandlerVersion: '1.3'
      autoUpgradeMinorVersion: true
      settings: domainJoinSettings
      protectedSettings: {
        Password: adminPassword
      }
    }
  }
]

// SQL IaaS Agent is registered via postprovision script (after WSFC/AG setup)

output sqlVmIds string[] = [for (vm, i) in sqlVms: sqlVmResources[i].id]
output sqlVmNames string[] = [for (vm, i) in sqlVms: sqlVmResources[i].name]
