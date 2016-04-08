param (
    [Parameter(Mandatory)]
    [String] $ClusterName,

    [String] $ClusterIP,

    [ValidateSet('NVGRE','VLANStatic','VLANDHCP')]
    [String] $Mode
)

if ($Mode -eq 'NVGRE' -and $ClusterIP -eq [String]::Empty) {
    throw 'When using NVGRE mode, a ClusterIP has to be specified manually'
}

$null = Install-WindowsFeature Failover-Clustering -IncludeManagementTools
$Domain = (Get-CimInstance -ClassName Win32_ComputerSystem).Domain
$null = Enable-WSManCredSSP -Role Client -DelegateComputer localhost, *.$Domain -Force -ErrorAction SilentlyContinue
$null = Enable-WSManCredSSP -Role Server -Force -ErrorAction SilentlyContinue
$null = Set-Item -Path WSMan:\localhost\Client\TrustedHosts -Value *.$Domain -Confirm:$false -Force

if (Test-Path -Path c:\VMRole\First) {
    $NewClusterArg = @{
        Name = $ClusterName
        NoStorage = $true
        Force = $true
        ErrorAction = 'Stop'
    }

    if ($Mode -eq 'VLANStatic') {
        #Capture IP from second NIC and use that for $ClusterIP
        $ClusterIPNIC = (Get-NetAdapter | Sort-Object -Property InterfaceIndex)[1]
        $SecondNicIP = ($ClusterIPNIC | Get-NetIPAddress).IPAddress
        $ClusterIPNIC | Get-NetIPAddress | Remove-NetIPAddress -Confirm:$false
        $ClusterIPNIC | Disable-NetAdapter -Confirm:$false
        $NewClusterArg.Add('StaticAddress',$SecondNicIP)
    }
    if ($Mode -eq 'NVGRE') {
        $NewClusterArg.Add('StaticAddress',$ClusterIP)
    }

    $Cluster = New-Cluster @NewClusterArg
} else {
    while (-not ($Cluster = Get-Cluster -Name $ClusterName -Domain $Domain)) {
        Start-Sleep -Seconds 5
    }
    while (($Cluster | Get-ClusterGroup -Name 'Cluster Group').State -ne 'Online') {
        Start-Sleep -Seconds 5
    }
    $Cluster | Add-ClusterNode -NoStorage
}
Get-StorageSubsystem |Where-Object -FilterScript {$_.AutomaticClusteringEnabled} | Set-StorageSubSystem -AutomaticClusteringEnabled $false