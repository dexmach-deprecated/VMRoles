param (
    [Parameter(Mandatory)]
    [String] $DomainAccount,

    [String] $LocalGroup = 'Administrators'
)

$Domain = $DomainAccount.Split(':')[0].Split('\')[0]
$User = $DomainAccount.Split(':')[0].Split('\')[1]
Write-Output -InputObject "Adding User $Domain\$User to $LocalGroup"
try {
    ([ADSI]"WinNT://./$LocalGroup,group").Add("WinNT://$Domain/$User")
    Write-Output -InputObject "Success adding User $Domain\$User to $LocalGroup"
    exit 0
} catch {
    Write-Error -Message $_.exception.message -ErrorAction Continue
    throw "Failed adding User $Domain\$User to $LocalGroup"
}