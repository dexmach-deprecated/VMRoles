param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [String] $InstanceName,

    [String] $ProductKey,

    [Parameter(Mandatory)]
    [ValidateSet('SQL','Windows')]
    [String] $SecurityMode = 'Windows',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [String] $SAPassword,

    [Parameter(Mandatory)]
    [ValidateSet('true','false')]
    [String] $TCPEnabled = 'true',

    [Parameter(Mandatory)]
    [ValidateSet('true','false')]
    [String] $NamedPipesEnabled = 'true',

    [Parameter(Mandatory)]
    [String] $SQLDBESVCAccount,

    [Parameter(Mandatory)]
    [String] $SQLAGTSVCAccount,
    
    [ValidateSet('12','13')]
    [String] $SQLVersion = '13'
)

if (Test-Path "${PSScriptRoot}\${PSUICulture}") {
    Import-LocalizedData -BindingVariable LocalizedData -filename SQL2016.psd1 -BaseDirectory "${PSScriptRoot}\${PSUICulture}"
} else {
    #fallback to en-US
    Import-LocalizedData -BindingVariable LocalizedData -filename SQL2016.psd1 -BaseDirectory "${PSScriptRoot}\en-US"
}

$DataVolume = (Get-Volume -FileSystemLabel 'SQLData').DriveLetter
$LogVolume = (Get-Volume -FileSystemLabel 'SQLLog').DriveLetter
$ArgumentList = '/ACTION=CompleteImage /INSTANCEID=MSSQLSERVER /INSTANCENAME={0} /IACCEPTSQLSERVERLICENSETERMS /Q /SQLSYSADMINACCOUNTS="BUILTIN\Administrators" /BROWSERSVCSTARTUPTYPE=Automatic /AGTSVCSTARTUPTYPE=Automatic' -f $InstanceName
$ArgumentList = $ArgumentList + (' /INSTALLSQLDATADIR="{0}:\Microsoft SQL Server" /SQLUSERDBLOGDIR="{1}:\Log" /SQLTEMPDBLOGDIR="{1}:\Log"' -f $DataVolume,$LogVolume)
$ArgumentList += (' /AGTSVCACCOUNT={0}' -f $SQLAGTSVCAccount.Split(':')[0])
$ArgumentList += (' /SQLSVCACCOUNT={0}' -f $SQLDBESVCAccount.Split(':')[0])

if ($TCPEnabled.ToBoolean($_)) {
    Write-Output -InputObject $LocalizedData.TCPEnabled
    $ArgumentList = $ArgumentList + ' /TCPENABLED=1'
} else {
    Write-Output -InputObject $LocalizedData.TCPDisabled
    $ArgumentList = $ArgumentList + ' /TCPENABLED=0'
}

if ($NamedPipesEnabled.ToBoolean($_)) {
    Write-Output -InputObject $LocalizedData.NPEnabled
    $ArgumentList = $ArgumentList + ' /NPENABLED=1'
} else {
    Write-Output -InputObject $LocalizedData.NPDisabled
    $ArgumentList = $ArgumentList + ' /NPENABLED=0'
}
 
if ($ProductKey.Length -eq 25 -or $ProductKey.Length -eq 29) {
    Write-Output -InputObject $LocalizedData.KeyProvided
    $ArgumentList = $ArgumentList + " /PID=$($ProductKey.Replace('-',''))"
} else {
    Write-Output -InputObject $LocalizedData.KeyNotProvided
}

if ($SecurityMode -eq 'SQL') {
    Write-Output -InputObject $LocalizedData.SQLAuthMode
    $ArgumentList = $ArgumentList + (' /SECURITYMODE=SQL')
} else {
    Write-Output -InputObject $LocalizedData.WinAuthMode
}

if (($null -eq $SAPassword) -or ($SAPassword -eq [string]::Empty)) {
    throw $LocalizedData.SAMissing
} else {
    $ArgumentList = $ArgumentList + (' /SAPWD=')
}

Write-Output -InputObject ($LocalizedData.InstallArg -f $ArgumentList)

$ArgumentList = $ArgumentList + $SAPassword
$ArgumentList += (' /AGTSVCPASSWORD={0}' -f $SQLAGTSVCAccount.Split(':')[1])
$ArgumentList += (' /SQLSVCPASSWORD={0}' -f $SQLDBESVCAccount.Split(':')[1])

$SetupProcess = Start-Process -FilePath ('C:\Program Files\Microsoft SQL Server\{0}0\Setup Bootstrap\*\setup.exe' -f $SQLVersion) -ArgumentList $ArgumentList -PassThru
$SetupProcess | Wait-Process
if ($SetupProcess.ExitCode -ne '0') {
    throw ($LocalizedData.InstallFailed -f $InstanceName)
} else {
    Write-Output -InputObject ($LocalizedData.InstallSuccess -f $InstanceName)
}
