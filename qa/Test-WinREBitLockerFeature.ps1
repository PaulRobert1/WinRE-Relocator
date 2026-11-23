param([string]$ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Move-WinRE-ExtendC.ps1'))
$ErrorActionPreference = 'Stop'
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($ScriptPath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$defs=@($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-VolumeEncryptionState'},$true))
if($defs.Count -ne 1){throw 'Missing unique encryption helper'}
. ([scriptblock]::Create($defs[0].Extent.Text))
$script:featureState='Available'
$script:providerMode='missing'
$script:AllowUninstalledBitLocker=$false
$script:featureCalls=0
function Get-WindowsFeature {
    param([string]$Name)
    $script:featureCalls++
    if($Name -ne 'BitLocker'){throw 'Unexpected feature query'}
    [pscustomobject]@{InstallState=$script:featureState}
}
function Get-CimInstance {
    param([string]$Namespace,[string]$ClassName)
    if($Namespace -ne 'root/CIMV2/Security/MicrosoftVolumeEncryption'){throw 'Unexpected namespace'}
    if($script:providerMode -eq 'missing') { throw ([Microsoft.Management.Infrastructure.CimException]::new('Invalid namespace')) }
    if($script:providerMode -eq 'failure'){throw ([Microsoft.Management.Infrastructure.CimException]::new('Access denied'))}
    [pscustomobject]@{DeviceID='\\?\Volume{11111111-1111-1111-1111-111111111111}\'}
}
function Test-Path {param([string]$LiteralPath) return $false}
function Invoke-BitLockerMethod {
    param($Volume,[string]$Method,[hashtable]$Arguments=@{})
    if($Method -eq 'GetConversionStatus'){return [pscustomobject]@{ReturnValue=0;ConversionStatus=0}}
    if($Method -eq 'GetProtectionStatus'){return [pscustomobject]@{ReturnValue=0;ProtectionStatus=0}}
    throw 'Unexpected method'
}
$passed=0;$failed=0
function Check([string]$Name,[scriptblock]$Action){
    try{& $Action;$script:passed++;Write-Host "PASS $Name"}
    catch{$script:failed++;Write-Host "FAIL $Name : $($_.Exception.Message)"}
}
function Throws([scriptblock]$Action){
    $caught=$null;try{& $Action|Out-Null}catch{$caught=$_}
    if($null -eq $caught){throw 'Expected a fail-closed exception'}
}
$volume='\\?\Volume{11111111-1111-1111-1111-111111111111}\'
Check 'Missing provider requires explicit operator opt-in' {
    $script:featureState='Available';$script:providerMode='missing';$script:AllowUninstalledBitLocker=$false
    Throws {Get-VolumeEncryptionState $volume -RequireReported}
}
Check 'Absent feature and opted-in missing provider returns no active protection' {
    $script:featureState='Available';$script:providerMode='missing';$script:AllowUninstalledBitLocker=$true
    $r=Get-VolumeEncryptionState $volume -RequireReported
    if(-not $r.AssumedUnencrypted -or $r.ProtectionStatus -ne 0 -or $r.Reported){throw 'Unexpected fallback state'}
}
Check 'Installed feature with missing provider always refuses fallback' {
    $script:featureState='Installed';$script:providerMode='missing';$script:AllowUninstalledBitLocker=$true
    Throws {Get-VolumeEncryptionState $volume -RequireReported}
}
Check 'Removed feature refuses fallback' {
    $script:featureState='Removed';$script:providerMode='missing';$script:AllowUninstalledBitLocker=$true
    Throws {Get-VolumeEncryptionState $volume -RequireReported}
}
Check 'Provider access denied does not permit fallback' {
    $script:featureState='Available';$script:providerMode='failure';$script:AllowUninstalledBitLocker=$true
    Throws {Get-VolumeEncryptionState $volume -RequireReported}
}
Check 'Provider exists despite feature absent refuses fallback' {
    $script:featureState='Available';$script:providerMode='exists';$script:AllowUninstalledBitLocker=$true
    Throws {Get-VolumeEncryptionState $volume -RequireReported}
}
Check 'Installed feature uses reported volume status' {
    $script:featureState='Installed';$script:providerMode='exists';$script:AllowUninstalledBitLocker=$false
    $r=Get-VolumeEncryptionState $volume -RequireReported
    if(-not $r.Reported -or $r.AssumedUnencrypted){throw 'Provider status ignored'}
}
Write-Host "RESULT: $passed passed; $failed failed."
Write-Host 'Scope: mocked feature/CIM responses only. No real encryption, partition, or WinRE operations.'
if($failed){exit 1}
