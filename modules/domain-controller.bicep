// Module: Domain Controllers - VMs, AD Forest creation, Replica DC, VNet DNS update
param location string
param adminUsername string

@secure()
param adminPassword string

param domainFqdn string
param domainNetBiosName string
param vmSize string

param dcSubnetId string

type dcVmConfig = {
  name: string
  privateIpAddress: string
}

param dcVms dcVmConfig[]

resource dcAvailabilitySet 'Microsoft.Compute/availabilitySets@2024-07-01' = {
  name: 'avset-sql-ha-dc'
  location: location
  sku: {
    name: 'Aligned'
  }
  properties: {
    platformFaultDomainCount: 2
    platformUpdateDomainCount: 5
  }
}

// ─── Domain Controller NICs ───

resource dcNics 'Microsoft.Network/networkInterfaces@2024-05-01' = [
  for (vm, i) in dcVms: {
    name: 'nic-${toLower(vm.name)}'
    location: location
    properties: {
      dnsSettings: {
        dnsServers: [
          dcVms[0].privateIpAddress
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
    properties: {
      availabilitySet: {
        id: dcAvailabilitySet.id
      }
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
  dependsOn: [cseCreateForest]
}

output dcVmIds string[] = [for (vm, i) in dcVms: dcVmResources[i].id]
output dcVmNames string[] = [for (vm, i) in dcVms: dcVmResources[i].name]
