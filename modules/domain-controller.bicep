// Module: Domain Controllers - VMs, AD Forest creation, Replica DC, VNet DNS update
param location string
param adminUsername string

@secure()
param adminPassword string

param domainFqdn string
param domainNetBiosName string
param vmSize string

param vnetName string
param vnetAddressPrefix string
param dcSubnetId string

type nsgRef = {
  name: string
  addressPrefix: string
  nsgId: string
}

param subnetsConfig nsgRef[]

type dcVmConfig = {
  name: string
  zone: string
  privateIpAddress: string
}

param dcVms dcVmConfig[]

// ─── Domain Controller NICs ───

resource dcNics 'Microsoft.Network/networkInterfaces@2024-05-01' = [
  for (vm, i) in dcVms: {
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
              id: dcSubnetId
            }
          }
        }
      ]
    }
  }
]

// ─── Domain Controller VMs ───

resource dcVmResources 'Microsoft.Compute/virtualMachines@2024-07-01' = [
  for (vm, i) in dcVms: {
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
          publisher: 'MicrosoftWindowsServer'
          offer: 'WindowsServer'
          sku: '2022-datacenter-azure-edition'
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
            diskSizeGB: 32
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
            id: dcNics[i].id
          }
        ]
      }
    }
  }
]

// ─── Custom Script: Promote DC-VM-1 as primary domain controller + DNS ───

resource cseCreateForest 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: dcVmResources[0]
  name: 'CreateADForest'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {}
    protectedSettings: {
      commandToExecute: 'powershell -ExecutionPolicy Unrestricted -Command "$pass = ConvertTo-SecureString -String \'${adminPassword}\' -AsPlainText -Force; Get-Disk | Where-Object PartitionStyle -eq \'RAW\' | Initialize-Disk -PartitionStyle GPT -PassThru | New-Partition -AssignDriveLetter -UseMaximumSize | Format-Volume -FileSystem NTFS -NewFileSystemLabel \'ADData\' -Confirm:$false; Install-WindowsFeature AD-Domain-Services,DNS -IncludeManagementTools; Import-Module ADDSDeployment; Install-ADDSForest -DomainName \'${domainFqdn}\' -DomainNetbiosName \'${domainNetBiosName}\' -SafeModeAdministratorPassword $pass -DatabasePath \'F:\\NTDS\' -LogPath \'F:\\NTDS\' -SysvolPath \'F:\\SYSVOL\' -InstallDns -Force -NoRebootOnCompletion; Add-DnsServerForwarder -IPAddress 168.63.129.16; Restart-Computer -Force"' 
    }
  }
}

module vnetDnsUpdate 'vnet-dns-update.bicep' = {
  params: {
    vnetName: vnetName
    location: location
    vnetAddressPrefix: vnetAddressPrefix
    dnsServers: [for vm in dcVms: vm.privateIpAddress]
    subnetsConfig: subnetsConfig
  }
  dependsOn: [cseCreateForest]
}

// ─── Custom Script: Promote DC-VM-2 as replica domain controller ───

resource cseReplicaDc 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: dcVmResources[1]
  name: 'ConfigureReplicaDC'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {}
    protectedSettings: {
      commandToExecute: 'powershell -ExecutionPolicy Unrestricted -Command "$pass = ConvertTo-SecureString -String \'${adminPassword}\' -AsPlainText -Force; $cred = New-Object System.Management.Automation.PSCredential(\'${domainNetBiosName}\\${adminUsername}\', $pass); Get-Disk | Where-Object PartitionStyle -eq \'RAW\' | Initialize-Disk -PartitionStyle GPT -PassThru | New-Partition -AssignDriveLetter -UseMaximumSize | Format-Volume -FileSystem NTFS -NewFileSystemLabel \'ADData\' -Confirm:$false; Install-WindowsFeature AD-Domain-Services,DNS -IncludeManagementTools; Import-Module ADDSDeployment; $maxRetries=30; for($i=0;$i -lt $maxRetries;$i++){try{Install-ADDSDomainController -DomainName \'${domainFqdn}\' -Credential $cred -SafeModeAdministratorPassword $pass -DatabasePath \'F:\\NTDS\' -LogPath \'F:\\NTDS\' -SysvolPath \'F:\\SYSVOL\' -InstallDns -Force -NoRebootOnCompletion; break}catch{Start-Sleep 60}}; Restart-Computer -Force"'
    }
  }
  dependsOn: [vnetDnsUpdate]
}

output dcVmIds string[] = [for (vm, i) in dcVms: dcVmResources[i].id]
output dcVmNames string[] = [for (vm, i) in dcVms: dcVmResources[i].name]
