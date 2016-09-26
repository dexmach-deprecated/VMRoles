#Add FirmwareType class to check if system is BIOS or UEFI based
Add-Type -Language CSharp -TypeDefinition @'
    using System;
    using System.Runtime.InteropServices;

    public class FirmwareType
    {
        [DllImport("kernel32.dll")]
        static extern bool GetFirmwareType(ref uint FirmwareType);

        public static uint GetFirmwareType()
        {
            uint firmwaretype = 0;
            if (GetFirmwareType(ref firmwaretype))
                return firmwaretype;
            else
                return 0;   // API call failed, just return 'unknown'
        }
    }
'@

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
    #if BIOS (1) or UEFI (2)
    if ([FirmwareType]::GetFirmwareType() -eq 1) {
        $SQLDisks | ForEach-Object -Process {
            $_ | Set-Disk -IsOffline $false
            $_ | Set-Disk -IsReadOnly $false
            $_ | Set-Disk -PartitionStyle GPT
        }
        $null = $SQLDisks[0] | 
            New-Partition -UseMaximumSize -AssignDriveLetter | 
                Format-Volume -NewFileSystemLabel 'SQLData' -FileSystem NTFS -Confirm:$false
                
        $null = $SQLDisks[1] | 
            New-Partition -UseMaximumSize -AssignDriveLetter | 
                Format-Volume -NewFileSystemLabel 'SQLLog' -FileSystem NTFS -Confirm:$false
    } else {
        $null = $SQLDisks[0] | 
            Initialize-Disk -PartitionStyle GPT -PassThru | 
                New-Partition -UseMaximumSize -AssignDriveLetter | 
                    Format-Volume -NewFileSystemLabel 'SQLData' -FileSystem NTFS -Confirm:$false

        $null = $SQLDisks[1] | 
            Initialize-Disk -PartitionStyle GPT -PassThru | 
                New-Partition -UseMaximumSize -AssignDriveLetter | 
                    Format-Volume -NewFileSystemLabel 'SQLLog' -FileSystem NTFS -Confirm:$false
    }
    Write-Output -InputObject ($LocalizedData.InitState -f 'succeeded')
} catch {
    throw ($LocalizedData.InitState -f 'failed')
}
