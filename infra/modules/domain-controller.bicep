// Module: Single Domain Controller - VM, AD Forest creation, VNet DNS update
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
param dcPrivateIp string
param dcVmName string
param dcZone string

type nsgRef = {
  name: string
  addressPrefix: string
  nsgId: string
}

param subnetsConfig nsgRef[]

type plainSubnetEntry = {
  name: string
  addressPrefix: string
}

param plainSubnets plainSubnetEntry[] = []

// --- DC NIC ---

resource dcNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-${toLower(dcVmName)}'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: dcPrivateIp
          subnet: {
            id: dcSubnetId
          }
        }
      }
    ]
  }
}

// --- DC VM ---

resource dcVm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: dcVmName
  location: location
  zones: [dcZone]
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: dcVmName
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
          id: dcNic.id
        }
      ]
    }
  }
}

// --- Custom Script: Create AD Forest + DNS + Forwarder ---

var createForestScript = 'powershell -ExecutionPolicy Unrestricted -Command "$p = ConvertTo-SecureString \'${adminPassword}\' -AsPlainText -Force; Get-Disk | Where PartitionStyle -eq RAW | Initialize-Disk -PartitionStyle GPT -PassThru | New-Partition -DriveLetter F -UseMaximumSize | Format-Volume -FileSystem NTFS -NewFileLabel ADData -Confirm:0; Install-WindowsFeature AD-Domain-Services,DNS -IncludeManagementTools; Set-Content -Path C:\\Windows\\addforwarder.ps1 -Value \'Add-DnsServerForwarder -IPAddress 168.63.129.16 -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName AddDnsForwarder -Confirm:0\'; $a = New-ScheduledTaskAction -Execute powershell.exe -Argument \'-File C:\\Windows\\addforwarder.ps1\'; $t = New-ScheduledTaskTrigger -AtStartup; Register-ScheduledTask -TaskName AddDnsForwarder -Action $a -Trigger $t -User SYSTEM -RunLevel Highest; Install-ADDSForest -DomainName \'${domainFqdn}\' -DomainNetbiosName \'${domainNetBiosName}\' -SafeModeAdministratorPassword $p -DatabasePath F:\\NTDS -LogPath F:\\NTDS -SysvolPath F:\\SYSVOL -InstallDns -Force"'

resource cseCreateForest 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: dcVm
  name: 'CreateADForest'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    settings: {}
    protectedSettings: {
      commandToExecute: createForestScript
    }
  }
}

// --- Update VNet DNS to point to DC ---

module vnetDnsUpdate 'vnet-dns-update.bicep' = {
  params: {
    vnetName: vnetName
    location: location
    vnetAddressPrefix: vnetAddressPrefix
    dnsServers: [dcPrivateIp]
    subnetsConfig: subnetsConfig
    plainSubnets: plainSubnets
  }
  dependsOn: [cseCreateForest]
}

output dcVmId string = dcVm.id
output dcVmName string = dcVm.name
