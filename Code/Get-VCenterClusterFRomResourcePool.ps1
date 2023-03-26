function Get-VCenterClusterFromResourcePool {
    <#
        .SYNOPSIS
            This function get the parent Cluster from a Resource Pool

            The ResourcePool can be a child from another Resource Pool or direct from a cluster

        .PARAMETER ResourcePool
            defines the resource pool

        .EXAMPLE
            $ResourcePool = Get-ResourcePool -Name $ResourcePoolName
            $ClusterName = Get-VCenterClusterFromResourcePool -ResourcePool $ResourcePool
    #>
    [CmdletBinding()]
    Param (
        $ResourcePool
    )
    if ( $ResourcePool.Parent.GetType().Name -ne 'ClusterImpl' ) {
        Get-VCenterClusterFromResourcePool -ResourcePool $ResourcePool.Parent
    }
    else {
        $ResourcePool.Parent.Name
    }
}