if (Test-Path "${PSScriptRoot}\${PSUICulture}") {
    Import-LocalizedData -BindingVariable LocalizedData -filename Disk.psd1 -BaseDirectory "${PSScriptRoot}\${PSUICulture}"
} else {
    #fallback to en-US
    Import-LocalizedData -BindingVariable LocalizedData -filename Disk.psd1 -BaseDirectory "${PSScriptRoot}\en-US"
}


$SQLDisks = Get-Disk | Where-Object -FilterScript {$_.OperationalStatus -eq 'Offline'} | Sort-Object -Property Size -Descending
if (($SQLDisks | Measure-Object).Count -lt 2) {
    throw $LocalizedData.DiskNotPresent
}

try {
    $SQLDataDisk = $SQLDisks[0] | 
                        Initialize-Disk -PartitionStyle GPT -PassThru | 
                        New-Partition -UseMaximumSize -AssignDriveLetter | 
                        Format-Volume -NewFileSystemLabel 'SQLData' -FileSystem NTFS -Confirm:$false

    $SQLLogDisk = $SQLDisks[1] | 
                        Initialize-Disk -PartitionStyle GPT -PassThru | 
                        New-Partition -UseMaximumSize -AssignDriveLetter | 
                        Format-Volume -NewFileSystemLabel 'SQLLog' -FileSystem NTFS -Confirm:$false

    Write-Output -InputObject ($LocalizedData.InitState -f 'succeeded')
} catch {
    throw ($LocalizedData.InitState -f 'failed')
}
