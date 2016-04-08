param (
    [string] $GatewayUser,
    [string] $SelfSignedCert,
    [string] $CertPath,
    [string] $CertPathUserName,
    [string] $CertPathPassword,
    [string] $PFXPin,
    [string] $Domain
)

if (Test-Path "${PSScriptRoot}\${PSUICulture}") {
    Import-LocalizedData -BindingVariable LocalizedData -filename Deploy.psd1 -BaseDirectory "${PSScriptRoot}\${PSUICulture}"
} else {
    #fallback to en-US
    Import-LocalizedData -BindingVariable LocalizedData -filename Deploy.psd1 -BaseDirectory "${PSScriptRoot}\en-US"
}

Import-Module $PSScriptRoot\RdsGw

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

if (-not $SelfSignedCert.ToBoolean($_)) {
    if ($CertPathUserName -ne 'Anonymous') {
        $CertPathUserNameCred = New-Object -TypeName pscredential `
            -ArgumentList $CertPathUserName, (ConvertTo-SecureString -String $CertPathPassword -AsPlainText -Force)
    } else {
        $CertPathUserNameCred = $null
    }
}

$InstallFeatures = Install-WindowsFeature -Name RDS-Gateway -IncludeManagementTools
if ($InstallFeatures.Success -eq $true) {
    Write-Output ($LocalizedData.FeatureInstall -f 'Success')
} else {
    throw ($LocalizedData.FeatureInstall -f 'Failed')
}

#Create group and user
try {
    $Computer = [ADSI]"WinNT://$Env:COMPUTERNAME,Computer"
    
    if ($Domain) {
        $DomainGroup = $true
        if ($GatewayUser.ToCharArray() -contains '@') {
            $GatewayUser = $GatewayUser.Split('@')[0]
        } elseif ($GatewayUser.ToCharArray() -contains '\') {
            $GatewayUser = $GatewayUser.Split('\')[1]
        }
        Write-Output -InputObject ($LocalizedData.DomainUserOrGroup -f $GatewayUser)
    } else {
        $DomainGroup = $false
        Write-Output -InputObject ($LocalizedData.WorkgroupUser -f $GatewayUser.Split(':')[0])
        #Create the user account
        $NewUser = $Computer.Create("User", $GatewayUser.Split(':')[0])
        $NewUser.SetPassword($GatewayUser.Split(':')[1])
        $NewUser.SetInfo()
        $NewUser.FullName = $GatewayUser.Split(':')[0]
        $NewUser.SetInfo()
        $NewUser.UserFlags = 65536 # ADS_UF_DONT_EXPIRE_PASSWD
        $NewUser.SetInfo()
    }
    
    #create local RDGW group
    $RDGWGroup = $Computer.Create('Group',"RDS Gateway Users")
    $RDGWGroup.SetInfo()
    
    #add member to local RDGW group
    if ($DomainGroup) {
        $Searcher = New-Object -TypeName System.DirectoryServices.DirectorySearcher -ArgumentList @(
            [adsi]"",
            ('(&(cn={0})(|(objectCategory=person)(objectCategory=group)))' -f $GatewayUser),
            @('distinguishedname','samaccountname')
        )
        $SearchResult = $Searcher.FindAll()
        if ($SearchResult.Count -eq 1) {
            $RDGWGroup.psbase.Invoke("Add",('WinNT://{0}/{1}' -f $Domain, $SearchResult[0].Properties.samaccountname[0]))
        } else {
            throw ($LocalizedData.NoADResult -f $SearchResult.Count)
        }
    } else {
        $RDGWGroup.psbase.Invoke("Add",$NewUser.path)
    }
    Write-Output -InputObject ($LocalizedData.AddUserGroupToRDGWUsers -f 'Success', $GatewayUser.Split(':')[0])
} catch {
    throw ($LocalizedData.AddUserGroupToRDGWUsers -f 'Failed', $GatewayUser.Split(':')[0])
}

#Create RAP and CAP Policy
try {
    $null = New-RdsGwCap -Name 'RD CAP' -UserGroupNames "$env:COMPUTERNAME\RDS Gateway Users"
    Write-Output -InputObject ($LocalizedData.CreateCAP -f 'Success')
} catch {
    throw ($LocalizedData.CreateCAP -f 'Failed')
}
try {
    $null = New-RdsGwRap -Name 'RD RAP' -UserGroupNames "$env:COMPUTERNAME\RDS Gateway Users"
    Write-Output -InputObject ($LocalizedData.CreateRAP -f 'Success')
} catch {
    throw ($LocalizedData.CreateRAP -f 'Failed')
}

if ($SelfSignedCert.ToBoolean($_)) {
    Write-Output -InputObject ($LocalizedData.CertType -f 'SelfSigned')
    $null = New-RdsGwSelfSignedCertificate -SubjectName $env:COMPUTERNAME
    Write-Output -InputObject $LocalizedData.SSLBind
} else {
    Write-Output -InputObject ($LocalizedData.CertType -f 'PFX Imported')
    if (-not (Test-Path C:\VMRole\Files)) {
        $null = New-Item -Path C:\VMRole\Files -Force -ItemType Directory
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

    #import certificate
    if (Test-Path -Path 'C:\VMRole\Files\Certificate.pfx') {
        try {
            $certcoll = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
            $certcoll.Import('C:\VMRole\Files\Certificate.pfx', $PFXPin,[System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet)
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
            $MyCert = $certcoll[-1]
            Write-Output -InputObject ($LocalizedData.PFXImport -f 'Success')
        } catch {
            throw ($LocalizedData.PFXImport -f 'Failed')
        }
        $null = Get-Item -Path "Cert:\LocalMachine\My\$($MyCert.Thumbprint)" | Set-RdsGwCertificate
        Write-Output -InputObject $LocalizedData.SSLBind
    } else {
        throw ($LocalizedData.PFXDownload -f 'Failed')
    }
}

$null = Enable-RdsGwServer
#log output configuration
Write-Output -InputObject $LocalizedData.Configured
Get-RdsGwServerConfiguration