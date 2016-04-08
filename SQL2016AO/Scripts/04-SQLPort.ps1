param (
    [Parameter(Mandatory)]
    [String] $Port,
    
    [ValidateSet('12','13')]
    [String] $SQLVersion = '13'
)

if (Test-Path "${PSScriptRoot}\${PSUICulture}") {
    Import-LocalizedData -BindingVariable LocalizedData -filename SQLPort.psd1 -BaseDirectory "${PSScriptRoot}\${PSUICulture}"
} else {
    #fallback to en-US
    Import-LocalizedData -BindingVariable LocalizedData -filename SQLPort.psd1 -BaseDirectory "${PSScriptRoot}\en-US"
}

$NameSpace = ('root\Microsoft\SqlServer\ComputerManagement{0}' -f $SQLVersion)

Get-CimInstance -Namespace $NameSpace -ClassName ServerNetworkProtocolProperty `
    -Filter "ProtocolName='Tcp' and IPAddressName='IPAll'" | ForEach-Object -Process {
        if ($_.PropertyName -eq 'TcpDynamicPorts') {
            $Result = $_ | Invoke-CimMethod -MethodName SetStringValue -Arguments @{StrValue = '0'}
            if ($Result.ReturnValue -ne 0) {
                throw ($LocalizedData.TcpDynamicPorts -f 'Failed')
            } else {
                Write-Output -InputObject ($LocalizedData.TcpDynamicPorts -f 'Success')
            }
        }
        if ($_.PropertyName -eq 'TcpPort') {
            $Result = $_ | Invoke-CimMethod -MethodName SetStringValue -Arguments @{StrValue = $Port}
            if ($Result.ReturnValue -ne 0) {
                throw ($LocalizedData.TcpPort -f 'Failed',$Port)
            } else {
                Write-Output -InputObject ($LocalizedData.TcpPort -f 'Success',$Port)
            }
        }
    }

Get-CimInstance -Namespace $NameSpace -ClassName SqlService | 
    Sort-Object -Property SQLServiceType |
        ForEach-Object -Process {
            if ($_.SQLServiceType -eq 1 -or $_.SQLServiceType -eq 2) {
                #SQLServiceType 2 agent
                #SQLServiceType 1 sqlserver
                Write-Output -InputObject ($LocalizedData.ServiceRestart -f $_.DisplayName)
                if ($_.State -eq 4 -and $_.SQLServiceType -eq 1) {
                    #stopping sqlserver.exe also stops agent
                    #State 4 Running
                    #State 1 Stopped
                    $Result = $_ | Invoke-CimMethod -MethodName StopService
                    if ($Result.ReturnValue -ne 0) {
                        throw ($LocalizedData.ServiceControlStatus -f 'Failed','Stopping', $_.DisplayName)
                    } else {
                        Write-Output -InputObject ($LocalizedData.ServiceControlStatus -f 'Success','Stopping', $_.DisplayName)
                    }
                }
                $Result = $_ | Invoke-CimMethod -MethodName StartService
                if ($Result.ReturnValue -ne 0) {
                        throw ($LocalizedData.ServiceControlStatus -f 'Failed','Starting', $_.DisplayName)
                } else {
                    Write-Output -InputObject ($LocalizedData.ServiceControlStatus -f 'Success','Starting', $_.DisplayName)
                }
            }
        }
