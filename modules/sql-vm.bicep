// Module: SQL Server VMs, domain join, SQL IaaS Agent, WSFC Group, AG Listener
param location string
param adminUsername string

@secure()
param adminPassword string

param domainFqdn string
param domainNetBiosName string
param ouPath string
param vmSize string
param sqlImageOffer string

@allowed(['Enterprise', 'Developer', 'Standard'])
param sqlImageSku string

// Service accounts (UPN format)
param sqlServiceAccount string
@secure()
param sqlServiceAccountPassword string
param clusterOperatorAccount string
@secure()
param clusterOperatorAccountPassword string
param clusterBootstrapAccount string
@secure()
param clusterBootstrapAccountPassword string

// Cloud witness
param cloudWitnessBlobEndpoint string
@secure()
param cloudWitnessPrimaryKey string

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

// ─── SQL VM NICs ───

resource sqlNics 'Microsoft.Network/networkInterfaces@2024-05-01' = [
  for (vm, i) in sqlVms: {
    name: 'nic-${toLower(vm.name)}'
    location: location
    properties: {
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
          sku: 'enterprise-gen2'
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

// ─── Domain Join (Custom Script with retry for DC availability) ───

resource domainJoin 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = [
  for (vm, i) in sqlVms: {
    parent: sqlVmResources[i]
    name: 'JoinDomain'
    location: location
    properties: {
      publisher: 'Microsoft.Compute'
      type: 'CustomScriptExtension'
      typeHandlerVersion: '1.10'
      autoUpgradeMinorVersion: true
      settings: {}
      protectedSettings: {
        commandToExecute: 'powershell -ExecutionPolicy Unrestricted -Command "$ErrorActionPreference=\'Continue\'; $domain=\'${domainFqdn}\'; $user=\'${domainNetBiosName}\\${adminUsername}\'; $pass=ConvertTo-SecureString \'${adminPassword}\' -AsPlainText -Force; $cred=New-Object PSCredential($user,$pass); $logFile=\'C:\\WindowsAzure\\Logs\\domainjoin.log\'; ipconfig /flushdns 2>&1 | Out-File $logFile -Append; ipconfig /registerdns 2>&1 | Out-File $logFile -Append; nslookup $domain 2>&1 | Out-File $logFile -Append; for($i=0;$i -lt 40;$i++){try{Write-Output \'Attempt $i - joining $domain\' | Out-File $logFile -Append; Add-Computer -DomainName $domain -Credential $cred -Force -ErrorAction Stop; Write-Output \'Join succeeded, restarting\' | Out-File $logFile -Append; Restart-Computer -Force; Start-Sleep 30; exit 0}catch{Write-Output \'Attempt $i failed: $_\' | Out-File $logFile -Append; ipconfig /flushdns 2>&1 | Out-File $logFile -Append; Start-Sleep 90}}; exit 1"'
      }
    }
  }
]

// ─── SQL VM Group (WSFC + AG) ───

resource sqlVmGroup 'Microsoft.SqlVirtualMachine/sqlVirtualMachineGroups@2023-10-01' = {
  name: 'sqlvmgroup-ag'
  location: location
  properties: {
    sqlImageOffer: sqlImageOffer
    sqlImageSku: sqlImageSku
    wsfcDomainProfile: {
      domainFqdn: domainFqdn
      ouPath: ouPath
      clusterBootstrapAccount: clusterBootstrapAccount
      clusterOperatorAccount: clusterOperatorAccount
      clusterSubnetType: 'MultiSubnet'
      sqlServiceAccount: sqlServiceAccount
      storageAccountUrl: cloudWitnessBlobEndpoint
      storageAccountPrimaryKey: cloudWitnessPrimaryKey
    }
  }
}

// ─── SQL IaaS Agent Extensions ───

resource sqlIaasAgent 'Microsoft.SqlVirtualMachine/sqlVirtualMachines@2023-10-01' = [
  for (vm, i) in sqlVms: {
    name: vm.name
    location: location
    properties: {
      virtualMachineResourceId: sqlVmResources[i].id
      sqlServerLicenseType: 'PAYG'
      sqlImageSku: sqlImageSku
      sqlVirtualMachineGroupResourceId: sqlVmGroup.id
      wsfcDomainCredentials: {
        clusterBootstrapAccountPassword: clusterBootstrapAccountPassword
        clusterOperatorAccountPassword: clusterOperatorAccountPassword
        sqlServiceAccountPassword: sqlServiceAccountPassword
      }
      wsfcStaticIp: vm.clusterIp
      storageConfigurationSettings: {
        diskConfigurationType: 'NEW'
        storageWorkloadType: 'OLTP'
        sqlDataSettings: {
          luns: [0]
          defaultFilePath: 'F:\\SQLData'
        }
        sqlLogSettings: {
          luns: [1]
          defaultFilePath: 'G:\\SQLLog'
        }
      }
    }
    dependsOn: [domainJoin]
  }
]

// ─── Availability Group Listener (multi-subnet) ───

resource agListener 'Microsoft.SqlVirtualMachine/sqlVirtualMachineGroups/availabilityGroupListeners@2023-10-01' = {
  parent: sqlVmGroup
  name: 'ag-listener'
  properties: {
    availabilityGroupName: 'ag-sql-ha'
    port: 1433
    availabilityGroupConfiguration: {
      replicas: [
        {
          sqlVirtualMachineInstanceId: sqlIaasAgent[0].id
          role: 'Primary'
          commit: 'Synchronous_Commit'
          failover: 'Automatic'
          readableSecondary: 'No'
        }
        {
          sqlVirtualMachineInstanceId: sqlIaasAgent[1].id
          role: 'Secondary'
          commit: 'Synchronous_Commit'
          failover: 'Automatic'
          readableSecondary: 'All'
        }
      ]
    }
    multiSubnetIpConfigurations: [
      for (vm, i) in sqlVms: {
        sqlVirtualMachineInstance: sqlIaasAgent[i].id
        privateIpAddress: {
          ipAddress: vm.listenerIp
          subnetResourceId: sqlSubnetIds[vm.subnetIndex]
        }
      }
    ]
  }
}

output sqlVmIds string[] = [for (vm, i) in sqlVms: sqlVmResources[i].id]
output sqlVmNames string[] = [for (vm, i) in sqlVms: sqlVmResources[i].name]
output sqlVmGroupName string = sqlVmGroup.name
output agListenerName string = agListener.name
