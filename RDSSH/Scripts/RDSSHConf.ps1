param (
    [String] $ExternalFQDN,
    [string] $SelfSignedCert,
    [string] $CertPath,
    [string] $CertPathUserName,
    [string] $CertPathPassword,
    [string] $PFXPin
)

if (Test-Path "${PSScriptRoot}\${PSUICulture}") {
    Import-LocalizedData -BindingVariable LocalizedData -filename RDSSHConf.psd1 -BaseDirectory "${PSScriptRoot}\${PSUICulture}"
} else {
    #fallback to en-US
    Import-LocalizedData -BindingVariable LocalizedData -filename RDSSHConf.psd1 -BaseDirectory "${PSScriptRoot}\en-US"
}

$Domain = (Get-CimInstance -ClassName Win32_ComputerSystem).Domain
if (-not (Test-Path C:\VMRole\Files)) {
    $null = New-Item -Path C:\VMRole\Files -Force -ItemType Directory
}
function IgnoreSSL {
    $Provider = New-Object -TypeName Microsoft.CSharp.CSharpCodeProvider
    $null = $Provider.CreateCompiler()
    $Params = New-Object -TypeName System.CodeDom.Compiler.CompilerParameters
    $Params.GenerateExecutable = $False
    $Params.GenerateInMemory = $True
    $Params.IncludeDebugInformation = $False
    $Params.ReferencedAssemblies.Add('System.DLL') > $null
    $TASource=@'
        namespace Local.ToolkitExtensions.Net.CertificatePolicy
        {
            public class TrustAll : System.Net.ICertificatePolicy
            {
                public TrustAll() {}
                public bool CheckValidationResult(System.Net.ServicePoint sp,System.Security.Cryptography.X509Certificates.X509Certificate cert, System.Net.WebRequest req, int problem)
                {
                    return true;
                }
            }
        }
'@ 
    $TAResults=$Provider.CompileAssemblyFromSource($Params,$TASource)
    $TAAssembly=$TAResults.CompiledAssembly
    ## We create an instance of TrustAll and attach it to the ServicePointManager
    $TrustAll = $TAAssembly.CreateInstance('Local.ToolkitExtensions.Net.CertificatePolicy.TrustAll')
    [System.Net.ServicePointManager]::CertificatePolicy = $TrustAll
}

IgnoreSSL

function ImportPFX {
    param (
        $Path,
        $Pin
    )
    
    $certcoll = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
    $certcoll.Import($Path, $Pin,[System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet)
    if ($certcoll.count -gt 1) {
        $rootstore = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Store -ArgumentList "\\$env:COMPUTERNAME\Root", 'LocalMachine'
        $rootstore.Open('ReadWrite')
        $rootstore.Add($certcoll[0])

        $mystore = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Store -ArgumentList "\\$env:COMPUTERNAME\My", 'LocalMachine'
        $mystore.Open('ReadWrite')
        $mystore.Add($certcoll[-1])
        $mystore.Close()

        if ($certcoll.count -gt 2) {
            $certcoll[1..-2] | %{
                $intstore = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Store -ArgumentList "\\$env:COMPUTERNAME\CertificateAuthority", 'LocalMachine'
                $intstore.Open('ReadWrite')
                $intstore.Add($_)
                $intstore.Close()
            }
        }
    } else {
        $rootstore = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Store -ArgumentList "\\$env:COMPUTERNAME\Root", 'LocalMachine'
        $rootstore.Open('ReadWrite')
        $rootstore.Add($certcoll[0])

        $mystore = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Store -ArgumentList "\\$env:COMPUTERNAME\My", 'LocalMachine'
        $mystore.Open('ReadWrite')
        $mystore.Add($certcoll[0])
        $mystore.Close()
    }
}

try {
    if (-not $SelfSignedCert.ToBoolean($_)) {
        Write-Output -InputObject ($LocalizedData.CertType -f 'PFX Imported')
        if ($CertPathUserName -ne 'Anonymous') {
            $CertPathUserNameCred = New-Object -TypeName pscredential `
                -ArgumentList $CertPathUserName, (ConvertTo-SecureString -String $CertPathPassword -AsPlainText -Force)
        } else {
            $CertPathUserNameCred = $null
        }
        
        if ([uri]::IsWellFormedUriString($CertPath, [UriKind]::Absolute)) {
            Write-Output -InputObject ($LocalizedData.URI -f $CertPath, 'valid')
            $WebArgs = @{
                Uri = $CertPath
                UseBasicParsing = $true
                OutFile = 'C:\VMRole\Files\Certificate.pfx'
            }
            if ($CertPathUserNameCred) {
                Write-Output -InputObject ($LocalizedData.URICred -f "with credential $CertPathUserName")
                $WebArgs.Add('Credential', $CertPathUserNameCred)
            } else {
                Write-Output -InputObject ($LocalizedData.URICred -f "anonymously")
            }
            try {
                $null = Invoke-WebRequest @WebArgs -ErrorAction Stop
                Write-Output -InputObject ($LocalizedData.PFXDownload -f 'Success')
            } catch {
                throw ($LocalizedData.PFXDownload -f 'Failed')
            }
        } else {
            throw ($LocalizedData.URI -f $CertPath, 'invalid')
        }
    } else {
        Write-Output -InputObject ($LocalizedData.CertType -f 'SelfSigned')
        $wildcardsplit = $ExternalFQDN.Split('.')
        if ($wildcardsplit.Count -le 2) {
            throw ($LocalizedData.ErrorWildCardGen -f $ExternalFQDN)
        } else {
            $wildcard = '*.' + $wildcardsplit[1..$wildcardsplit.Count] -join '.'
            Write-Output -InputObject ($LocalizedData.WildCardGen -f $ExternalFQDN,$wildcard)
        }
        $Cert = New-SelfSignedCertificate -DnsName $ExternalFQDN,$wildcard -CertStoreLocation Cert:\LocalMachine\My
        $null = $Cert | Export-PfxCertificate -ChainOption BuildChain -Force -FilePath 'C:\VMRole\Files\Certificate.pfx' -Password (ConvertTo-SecureString -String '1234' -AsPlainText -Force)
        $null = Remove-Item $cert.PSPath -Force
        $PFXPin = '1234'
    }
    
    if (Test-Path -Path 'C:\VMRole\Files\Certificate.pfx') {
        try {
            ImportPFX -Path 'C:\VMRole\Files\Certificate.pfx' -Pin $PFXPin
            Write-Output -InputObject ($LocalizedData.PFXImport -f 'Success')
        } catch {
            throw ($LocalizedData.PFXImport -f 'Failed')
        }
    } else {
        throw ($LocalizedData.PFXDownload -f 'Failed')
    }
    
    $PFXPass = ConvertTo-SecureString -String $PFXPin -AsPlainText -Force

    New-RDSessionDeployment -ConnectionBroker "$env:COMPUTERNAME.$domain" -SessionHost "$env:COMPUTERNAME.$domain" -WebAccessServer "$env:COMPUTERNAME.$domain" -ErrorAction Stop
    New-RDSessionCollection -CollectionName WAPCollection -SessionHost "$env:COMPUTERNAME.$domain" -ConnectionBroker "$env:COMPUTERNAME.$domain" -ErrorAction Stop
    Set-RDLicenseConfiguration -Mode PerUser -ConnectionBroker "$env:COMPUTERNAME.$domain" -LicenseServer "$env:COMPUTERNAME.$domain" -Force -ErrorAction Stop
    Add-RDServer -Server "$env:COMPUTERNAME.$domain" -Role RDS-LICENSING -ConnectionBroker "$env:COMPUTERNAME.$domain" -ErrorAction Stop
    Add-RDServer -Server "$env:COMPUTERNAME.$domain" -Role RDS-GATEWAY -ConnectionBroker "$env:COMPUTERNAME.$domain" -GatewayExternalFqdn $ExternalFQDN -ErrorAction Stop
    New-RDRemoteApp -CollectionName WAPCollection `
                    -ShowInWebAccess $true `
                    -DisplayName 'Remote Desktop Connection' `
                    -Alias mstsc `
                    -FilePath 'C:\Windows\System32\mstsc.exe' `
                    -CommandLineSetting DoNotAllow
                            
    New-RDRemoteApp -CollectionName WAPCollection `
                    -ShowInWebAccess $true `
                    -DisplayName 'Windows PowerShell' `
                    -Alias powershell `
                    -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
                    -CommandLineSetting DoNotAllow
                            
    $RDCertArgs = @{
        ConnectionBroker = "$env:COMPUTERNAME.$domain"
        Password = $PFXPass
        Force = $true
        ImportPath = 'C:\VMRole\Files\Certificate.pfx'
    }

    Set-RDCertificate @RDCertArgs -Role RDGateway
    Set-RDCertificate @RDCertArgs -Role RDWebAccess
    Set-RDCertificate @RDCertArgs -Role RDRedirector
    Set-RDCertificate @RDCertArgs -Role RDPublishing
    Write-Output -InputObject ($LocalizedData.Deployment -f 'Success')
    exit 0
} catch {
    Write-Error -Message $_.exception.message -ErrorAction Continue
    throw ($LocalizedData.Deployment -f 'Failed')
}