param (
    [Parameter(Mandatory)]
    [ValidateLength(1,12)]
    [String] $ClusterName,

    [String] $AOIpaddress,

    [Parameter(Mandatory)]
    [String] $InstanceName,

    [Parameter(Mandatory)]
    [String] $Installuser,

    [ValidateSet('NVGRE','VLANStatic','VLANDHCP')]
    [String] $Mode,

    [ValidateSet('13','12')]
    [String] $SQLVersion = '13'
)
$Namespace = "root\Microsoft\SqlServer\ComputerManagement$SQLVersion"
$Listener = $ClusterName + '-AO' #ClusterName must be -le 12
$AG = 'AG01'
if ($InstanceName -eq 'MSSQLSERVER') {
    $ServerInstance = '.'
    $InstanceName = 'DEFAULT'
    $ReplicaName = $env:COMPUTERNAME
} else {
    $ServerInstance = "$env:COMPUTERNAME\$InstanceName"
    $ReplicaName = "$env:COMPUTERNAME\$InstanceName"
}
$SQLPath = "$env:COMPUTERNAME\$InstanceName"
$Domain = (Get-CimInstance -ClassName Win32_ComputerSystem).Domain
$SVCAcct = (Get-CimInstance -Namespace $Namespace -ClassName SqlService -Filter 'sqlservicetype=1').StartName
Import-Module -Name sqlps -DisableNameChecking
$ErrorActionPreference = 'Stop'
@(
    'EXEC sp_addsrvrolemember ''{0}'', ''sysadmin''' -f $Installuser.Split(':')[0]
    'IF NOT EXISTS (SELECT name FROM master.sys.server_principals WHERE name = ''NT AUTHORITY\SYSTEM'') BEGIN CREATE LOGIN [NT AUTHORITY\SYSTEM] FROM WINDOWS END'
    'GRANT ALTER ANY AVAILABILITY GROUP TO [NT AUTHORITY\SYSTEM] AS SA'
    'GRANT CONNECT SQL TO [NT AUTHORITY\SYSTEM] AS SA'
    'GRANT VIEW SERVER STATE TO [NT AUTHORITY\SYSTEM] AS SA'
    'IF NOT EXISTS (SELECT name FROM master.sys.server_principals WHERE name = ''{0}'') BEGIN CREATE LOGIN [{0}] FROM WINDOWS END' -f $SVCAcct
) | ForEach-Object -Process {Invoke-Sqlcmd -ServerInstance $ServerInstance -Query $_}

Enable-SqlAlwaysOn -Path SQLSERVER:\SQL\$SQLPath -Force -NoServiceRestart

#restart sql
Get-CimInstance -Namespace $Namespace -ClassName SqlService | 
    Sort-Object -Property SQLServiceType |
        ForEach-Object -Process {
            if ($_.SQLServiceType -eq 1 -or $_.SQLServiceType -eq 2) {
                #SQLServiceType 2 agent
                #SQLServiceType 1 sqlserver
                "Restarting service: $($_.DisplayName)"
                if ($_.State -eq 4 -and $_.SQLServiceType -eq 1) {
                    #stopping sqlserver.exe also stops agent
                    #State 4 Running
                    #State 1 Stopped
                    $Result = $_ | Invoke-CimMethod -MethodName StopService
                    if ($Result.ReturnValue -ne 0) {
                        throw 'Failed Stopping Service'
                    }
                }
                $Result = $_ | Invoke-CimMethod -MethodName StartService
                if ($Result.ReturnValue -ne 0) {
                        throw 'Failed Starting Service'
                }
            }
        }

$endpoint = New-SqlHadrEndpoint 'Hadr_endpoint' -Port 5022 -Path "SQLSERVER:\SQL\$SQLPath"
$null = Set-SqlHadrEndpoint -InputObject $endpoint -State 'Started'
Invoke-Sqlcmd -Query ('GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [{0}]' -f $SVCAcct) -ServerInstance $ServerInstance

if (Test-Path -Path c:\VMRole\First) {
    #Create Listener Computer Object
    $ListenerSearcher = New-Object -TypeName System.DirectoryServices.DirectorySearcher -ArgumentList @(
        [adsi]"LDAP://$Domain"
        "(&(objectCategory=computer)(objectClass=computer)(cn=$Listener))"
    )

    if (-not $ListenerSearcher.FindOne()) {
        #Create Computer Account
        $OUSearcher =  New-Object -TypeName System.DirectoryServices.DirectorySearcher -ArgumentList @(
            [adsi]"LDAP://$Domain"
            "(&(objectCategory=computer)(objectClass=computer)(cn=$env:COMPUTERNAME))"
        )
        $OU = ($OUSearcher.FindOne().Path.Split(',') | Select-Object -Skip 1) -join ','
        $NewComp = New-Object System.DirectoryServices.DirectoryEntry  -ArgumentList @(
            "LDAP://$OU"
            #UserName
            #password
        )
        $objComputer = $NewComp.Create('computer', "CN=$Listener")
        [void] $objComputer.Put('sAMAccountName',"$Listener$") 
        [void] $objComputer.Put('userAccountControl', 4130) 
        [void] $objComputer.SetInfo()

        $Object = New-Object -TypeName System.DirectoryServices.DirectoryEntry -ArgumentList @(
            "LDAP://$($objComputer.distinguishedName)"
            #UserName
            #password
        )
        $Ace = New-Object -TypeName System.DirectoryServices.ActiveDirectoryAccessRule -ArgumentList @(
            [System.Security.Principal.NTAccount]("$Domain\$ClusterName$")
            [System.DirectoryServices.ActiveDirectoryRights]::GenericAll
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        [void] $Object.psbase.ObjectSecurity.AddAccessRule($Ace)
        [void] $Object.psbase.CommitChanges()
    }  

    #CreateDB
    Invoke-Sqlcmd -Query 'CREATE database EnableAO' -ServerInstance $ServerInstance

    #Backup DB
    $Drive = (Get-Volume -FileSystemLabel SQLData).DriveLetter
    $ShareDir = New-Item -Path "$Drive`:\" -ItemType directory -Name AGInitShare
    $ShareACL = $ShareDir | Get-ACL
    $Ace = New-Object -TypeName Security.AccessControl.FileSystemAccessRule -ArgumentList $SVCAcct, 'FullControl', 'ContainerInherit,ObjectInherit', 'NONE', 'Allow'
    $ShareACL.AddAccessRule($ace)
    $ShareDir | Set-Acl -AclObject $ShareACL

    #add file perm for SQLDBE account
    Backup-SqlDatabase -Database EnableAO -BackupContainer "$Drive`:\AGInitShare" -ServerInstance $ServerInstance
    Backup-SqlDatabase -BackupAction Log -Database EnableAO -BackupContainer "$Drive`:\AGInitShare" -ServerInstance $ServerInstance

    #Create AG
    $primaryReplica = New-SqlAvailabilityReplica `
        -Name $ReplicaName `
        -EndpointURL "TCP://$env:COMPUTERNAME.$Domain`:5022" `
        -AvailabilityMode 'SynchronousCommit' `
        -FailoverMode 'Automatic' `
        -Version $SQLVersion `
        -AsTemplate `
        -ConnectionModeInSecondaryRole AllowAllConnections

    $Null = New-SqlAvailabilityGroup `
        -Name $AG `
        -Path "SQLSERVER:\SQL\$SQLPath" `
        -AvailabilityReplica @($primaryReplica) `
        -Database 'EnableAO'
    
    $Subnet = (Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True').IPSubnet[0]
    if ($Mode -eq 'NVGRE') {
        $Listener = New-SqlAvailabilityGroupListener -Path "SQLSERVER:\SQL\$SQLPath\AvailabilityGroups\$AG" -Name $Listener -Verbose -StaticIp $AOIpaddress/$Subnet
    } elseif ($Mode -eq 'VLANDHCP') {
        $AOIpaddress = (Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True').IPAddress[0]
        $Listener = New-SqlAvailabilityGroupListener -Path "SQLSERVER:\SQL\$SQLPath\AvailabilityGroups\$AG" -Name $Listener -Verbose -DhcpSubnet $AOIpaddress/$Subnet
    } else {
        #In VLAN Static mode, node 2 will create the listener as it's secondary NIC IP will be used.
    }
    $Share = New-SmbShare -Path $Drive`:\AGInitShare -FullAccess Administrators,System,$SVCAcct -Name AGInitShare
} else {
    $PrimComputer = (Get-CimInstance -ComputerName $ClusterName -ClassName win32_computersystem).Name
    Set-Location -Path C:\
    while (-not (Test-Path -LiteralPath \\$PrimComputer.$Domain\AGInitShare)) {
        Start-Sleep -Seconds 5
    }
    $DBBak = Get-ChildItem -Path "\\$PrimComputer.$Domain\AGInitShare\*.bak"
    $DBLog = Get-ChildItem -Path "\\$PrimComputer.$Domain\AGInitShare\*.log"
    $LogDriveLetter = (Get-Volume -FileSystemLabel SQLLog).DriveLetter
    $DataPath = (Get-ciminstance -ClassName SqlServiceAdvancedProperty -namespace $Namespace -Filter "PropertyName = 'DATAPATH'").PropertyStrValue + '\DATA'
    $RelocateData = New-Object -TypeName Microsoft.SqlServer.Management.Smo.RelocateFile `
                               -ArgumentList 'EnableAO', "$DataPath\EnableAO.mdf"
    $RelocateLog = New-Object -TypeName Microsoft.SqlServer.Management.Smo.RelocateFile `
                              -ArgumentList 'EnableAO_Log', ('{0}:\Log\EnableAO_Log.ldf' -f $LogDriveLetter)

    Restore-SqlDatabase `
        -Database 'EnableAO' `
        -BackupFile $DBBak.FullName `
        -ServerInstance $ServerInstance `
        -NoRecovery -RelocateFile @($RelocateData,$RelocateLog)

    Restore-SqlDatabase `
        -Database 'EnableAO' `
        -BackupFile $DBLog.FullName `
        -ServerInstance $ServerInstance  `
        -RestoreAction Log `
        -NoRecovery -RelocateFile @($RelocateData,$RelocateLog)

    $agPath = "SQLSERVER:\Sql\$PrimComputer.$Domain\$InstanceName\AvailabilityGroups\$AG"

    $SecondaryReplica = New-SqlAvailabilityReplica `
        -Name $ReplicaName `
        -EndpointURL "TCP://$env:COMPUTERNAME.$Domain`:5022" `
        -AvailabilityMode 'SynchronousCommit' `
        -FailoverMode 'Automatic' `
        -Path $agPath `
        -ConnectionModeInSecondaryRole AllowAllConnections
        
    Join-SqlAvailabilityGroup -InputObject $ServerInstance -Name $AG
    Add-SqlAvailabilityDatabase -Path "SQLSERVER:\SQL\$SQLPath\AvailabilityGroups\$AG" -Database 'EnableAO'
    if ($Mode -eq 'VLANStatic') {
        #hijack NIC ip here
        $ClusterIPNIC = (Get-NetAdapter | Sort-Object -Property InterfaceIndex)[1]
        $AOIpaddress = ($ClusterIPNIC | Get-NetIPAddress).IPAddress
        $ClusterIPNIC | Get-NetIPAddress | Remove-NetIPAddress -Confirm:$false
        $ClusterIPNIC | Disable-NetAdapter -Confirm:$false
        $Subnet = (Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True').IPSubnet[0]
        $Listener = New-SqlAvailabilityGroupListener -Path $agPath -Name $Listener -Verbose -StaticIp $AOIpaddress/$Subnet
    } else {
        #handled on first node
    }
}