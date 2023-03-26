function Copy-VCenterVM {
    <#
        .SYNOPSIS
            this function clones a vm to a different vCenter

        .DESCRIPTION
            this function clones a vm to a different vCenter

            it is possible to change settings during the clone

        .PARAMETER SourceVCenterFQDN
            the fqdn of the source vCenter

            this string parameter is mandatory

        .PARAMETER SourceVCenterCredential
            the credentials needed to connect to the source vCenter

            this credential parameter is mandatory

        .PARAMETER SourceVMName
            the name of the source vm

            this string parameter is mandatory

        .PARAMETER DestinationVCenterFQDN
            the fqdn of the destination vCenter

            this string parameter is mandatory

        .PARAMETER DestinationVCenterCredential
            the credentials needed to connect to the destination vCenter

            this credential parameter is mandatory

        .PARAMETER DestinationVMName
            the name of the new vm in the destination vCenter

            this string parameter is not mandatory. if this parameter isn't used, the function will use the name of the source vm

        .PARAMETER DataStoreName
            the name of the destination datastore

            this string parameter is mandatory

        .PARAMETER ResourcePoolName
            the name of the ResourcePool in the destination vCenter

            this string parameter is not mandatory, but one of this parameters must be used: ResourcePoolName, ClusterName, HostName

        .PARAMETER ClusterName
            the name of the Cluster in the destination vCenter

            this string parameter is not mandatory, but one of this parameters must be used: ResourcePoolName, ClusterName, HostName

        .PARAMETER HostName
            the name of the Host in the destination vCenter

            this string parameter is not mandatory, but one of this parameters must be used: ResourcePoolName, ClusterName, HostName

        .PARAMETER FolderName
            the name of the Folder for the inventory location in the destination vCenter

            this string parameter is mandatory

        .PARAMETER PowerOn
            this parameter defines if the new vm is powered on after the clone is finished

            this boolean parameter is not mandatory, if not defined the vm will stay powered off

        .PARAMETER useUpperCaseUuid
            in some circumstances, this parameter is needed to connect from the source vCenter to the destination vCenter

            i'm currently not sure, when and why it is needed --> try and error

        .PARAMETER wait
            if this switch parameter is set, the function will wait till the cm is cloned

        .PARAMETER ReplaceNetwork
            whith this parameter can you define how networks will be replaced.

            this parameter is defined as hashtable and is not mandatory

            if it is not set, the network adapter will be assigned to the network with the same name on the target vcenter

        .EXAMPLE
            $CloneParams = @{
                SourceVCenterFQDN            = 'oldvcenter.domain.local'
                SourceVCenterCredential      = $Credentials
                SourceVMName                 = 'testvm'
                DestinationVCenterFQDN       = 'newvCenter.domain.local'
                DestinationVCenterCredential = $Credentials
                DataStoreName                = 'DatastoreName'
                ResourcePoolName             = 'ResourcePoolName'
                FolderName                   = 'FolderName'
                Wait                         = $null
                ReplaceNetwork               = @{
                    'VLAN005' = 'VLAN1005'
                    'VLAN006' = 'VLAN1006'
                    'VLAN007' = 'VLAN1007'
                }
                # -useUpperCaseUuid
            }
            Copy-VCenterVM @CloneParams

        .NOTES
            Author: Josh Burkard (www.burkard.it)
            Created: 24/03/2023

            Requirements:
                - PowerCLI
                - function Get-VCenterCertificate (stays in the same GIT Repository)


    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory=$true)]
        [string]
        $SourceVCenterFQDN
        ,
        [Parameter(Mandatory=$true)]
        [System.Management.Automation.PSCredential]
        $SourceVCenterCredential
        ,
        [Parameter(Mandatory=$true)]
        [string]
        $SourceVMName
        ,
        [Parameter(Mandatory=$true)]
        [string]
        $DestinationVCenterFQDN
        ,
        [Parameter(Mandatory=$true)]
        [System.Management.Automation.PSCredential]
        $DestinationVCenterCredential
        ,
        [Parameter(Mandatory=$false)]
        [string]
        $DestinationVMName
        ,
        [Parameter(Mandatory=$true)]
        $DataStoreName
        ,
        [Parameter(Mandatory=$false)]
        $ResourcePoolName
        ,
        [Parameter(Mandatory=$false)]
        $ClusterName
        ,
        [Parameter(Mandatory=$false)]
        $HostName
        ,
        [Parameter(Mandatory=$true)]
        $FolderName
        ,
        [Parameter(Mandatory=$false)]
        [boolean]$PowerOn = $false
        ,
        [switch]
        $useUpperCaseUuid
        ,
        [switch]$Wait
        ,
        [Parameter(Mandatory=$false)]
        [hashtable]$ReplaceNetwork
    )
    if ( ( -not [boolean]$ResourcePoolName ) -and ( -not [boolean]$ClusterName ) -and ( -not [boolean]$HostName ) ) {
        throw "parameter ResourcePoolName or ClusterName or HostName is required"
    }

    if ( -not [boolean]$DestinationVMName ) {
        $DestinationVMName = $SourceVMName
    }
    $SourceVCenterSession = Connect-VIServer -Server $SourceVCenterFQDN -Credential $SourceVCenterCredential
    $DestinationVCenterSession = Connect-VIServer -Server $DestinationVCenterFQDN -Credential $DestinationVCenterCredential

    $destVCCertificate = Get-VCenterCertificate -URI "https://${DestinationVCenterFQDN}"
    $destVCThumbprint = $destVCCertificate.Thumbprint

    # Source VM to clone from
    $vm = Get-VM -Server $SourceVCenterSession -Name $SourceVMName
    $vm_view = Get-View $vm -Property Config.Hardware.Device

    # Dest Datastore to clone VM to
    $datastore_view = Get-Datastore -Server $DestinationVCenterSession -Name $DataStoreName

    # Dest VM Folder to clone VM to
    $folder_view = Get-Folder -Server $DestinationVCenterSession -Name $FolderName

    if ( [boolean]$ResourcePoolName ) {
        $rp_view = Get-ResourcePool -Server $DestinationVCenterSession -Name $ResourcePoolName
        $resource = $rp_view.ExtensionData.MoRef
        $ClusterName = Get-ClusterFromResourcePool $rp_view
    }
    if ( [boolean]$ClusterName ) {
        $Cluster = Get-Cluster -Server $DestinationVCenterSession -Name $ClusterName
    }
    if ( [boolean]$Cluster ) {
        $vmhost = $Cluster | Get-VMHost | Select-Object -First 1
    }
    else {
        $vmhost = Get-VMHost -Server $DestinationVCenterSession -Name $HostName
    }

    $vmhost_view = (Get-VMHost -Server $DestinationVCenterSession -Name $vmhost)

    #region get current network adapter
        # Find all Etherenet Devices for given VM which
        # we will need to change its network at the destination
        $vmNetworkAdapters = @()
        $NetworkAdapters = Get-NetworkAdapter -Server $SourceVCenterSession -VM $vm
        $devices = $vm_view.Config.Hardware.Device
        foreach ( $device in $devices ) {
            if ( $device -is [VMware.Vim.VirtualEthernetCard] ) {

                $NetworkAdapter = ( $NetworkAdapters | Where-Object { $_.Name -eq $device.DeviceInfo.Label } )
                $vmNetworkAdapters += [PSCustomObject]@{
                    device = $device
                    NetworkAdapter = $NetworkAdapter
                    NetworkName = $NetworkAdapter.NetworkName
                }

            }
        }
    #endregion get current network adapter

    #region create Clone Spec
        $spec = New-Object VMware.Vim.VirtualMachineCloneSpec
        $spec.PowerOn = $PowerOn
        $spec.Template = $false
        $locationSpec = New-Object VMware.Vim.VirtualMachineRelocateSpec

        $locationSpec.datastore = $datastore_view.Id
        $locationSpec.host = $vmhost_view.Id
        $locationSpec.pool = $resource
        $locationSpec.Folder = $folder_view.Id

        # Service Locator for the destination vCenter Server
        # regardless if its within same SSO Domain or not
        $service = New-Object VMware.Vim.ServiceLocator
        $credential = New-Object VMware.Vim.ServiceLocatorNamePassword
        $credential.username = $DestinationVCenterCredential.UserName
        $credential.password = $DestinationVCenterCredential.GetNetworkCredential().Password
        $service.credential = $credential

        # For some xVC-vMotion, VC's InstanceUUID must be in all caps
        # Haven't figured out why, but this flag would allow user to toggle (default=false)
        if ( [boolean]$useUpperCaseUuid ) {
            $service.instanceUuid = ($DestinationVCenterSession.InstanceUuid).ToUpper()
        } else {
            $service.instanceUuid = $DestinationVCenterSession.InstanceUuid
        }
        $service.sslThumbprint = $destVCThumbprint
        $service.url = "https://${DestinationVCenterFQDN}"
        $locationSpec.service = $service


        #region Create VM spec depending if destination networking
            # is using Distributed Virtual Switch (VDS) or
            # is using Virtual Standard Switch (VSS)

            foreach ($vmNetworkAdapter in $vmNetworkAdapters) {

                # Extract Distributed Portgroup required info
                if ( $ReplaceNetwork ) {
                    $NetworkName = $ReplaceNetwork."$( $vmNetworkAdapter.NetworkName )"
                }
                else {
                    $NetworkName = $vmNetworkAdapter.NetworkName
                }
                $dvpg = Get-VDPortgroup -Server $DestinationVCenterSession -Name $NetworkName -ErrorAction SilentlyContinue

                if ( [boolean]$dvpg ) {
                    $vds_uuid = (Get-View $dvpg.ExtensionData.Config.DistributedVirtualSwitch).Uuid
                    $dvpg_key = $dvpg.ExtensionData.Config.key

                    # Device Change spec for VSS portgroup
                    $dev = New-Object VMware.Vim.VirtualDeviceConfigSpec
                    $dev.Operation = "edit"
                    $dev.Device = $vmNetworkAdapter.device
                    $dev.device.Backing = New-Object VMware.Vim.VirtualEthernetCardDistributedVirtualPortBackingInfo
                    $dev.device.backing.port = New-Object VMware.Vim.DistributedVirtualSwitchPortConnection
                    $dev.device.backing.port.switchUuid = $vds_uuid
                    $dev.device.backing.port.portgroupKey = $dvpg_key
                    $locationSpec.DeviceChange += $dev
                }
                else {
                    # Device Change spec for VSS portgroup
                    $dev = New-Object VMware.Vim.VirtualDeviceConfigSpec
                    $dev.Operation = "edit"
                    $dev.Device = $vmNetworkAdapter.device
                    $dev.device.backing = New-Object VMware.Vim.VirtualEthernetCardNetworkBackingInfo
                    $dev.device.backing.deviceName = $vmNetworkAdapter.NetworkName
                    $locationSpec.DeviceChange += $dev
                }
            }
        #endregion Create VM spec depending if destination networking

        $spec.Location = $locationSpec
    #endregion create Clone Spec

    #region create clone task
        $task = $vm_view.CloneVM_Task($folder_view.Id, $DestinationVMName, $spec )
        $task1 = Get-Task -Server $SourceVCenterSession -Id ("Task-$($task.value)")
    #endregion create clone task

    #region wait for finish

        if ( [boolean]$Wait ) {
            Write-Verbose "Task started"
            do {
                Write-Progress -Activity "migrate vm $SourceVMName" -Status "$( $task1.PercentComplete ) %" -PercentComplete $task1.PercentComplete
                Start-Sleep -Seconds 5
                $task1 = Get-Task -Server $SourceVCenterSession -Id ("Task-$($task.value)")

            } while (
                $task1.State -in @( 'Queued', 'Running', 'Unknown' )
            )
            Write-Progress -Activity "migrate vm $SourceVMName" -Status "completed" -Completed

            Write-Verbose "Task ended"

        }
    #endregion wait for finish

    return $task1
}