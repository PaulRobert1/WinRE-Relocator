param([string]$ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Move-WinRE-ExtendC.ps1'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$definitions = @($ast.FindAll({param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Get-StagingSpacePlan'
}, $true))
if ($definitions.Count -ne 1) { throw 'FAIL: Expected one production Get-StagingSpacePlan helper; implementation is missing.' }
# Execute only the pure helper, never the script body.
. ([scriptblock]::Create($definitions[0].Extent.Text))
$passed = 0; $failed = 0
function Check([string]$Name, [scriptblock]$Action) {
    try { & $Action; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert $threw 'Unsafe or invalid capacity combination was accepted'
}

Check '700 MiB on C accepts 400 MiB WIM with backups on D' {
    $plan = Get-StagingSpacePlan -WimBytes 400MB -RecoveryPartitionBytes 523MB -CFreeBytes 700MB -BackupFreeBytes 2GB
    Assert ($plan.RequiredCBytes -eq 656MB) 'C requirement must be WIM plus 256 MiB'
    Assert ($plan.RequiredBackupBytes -eq 1302MB) 'Backup requirement must be twice the old partition plus 256 MiB'
}
Check 'Exact C and backup thresholds accepted' {
    $plan = Get-StagingSpacePlan -WimBytes 400MB -RecoveryPartitionBytes 523MB -CFreeBytes 656MB -BackupFreeBytes 1302MB
    Assert ($plan.RequiredCBytes -eq 656MB -and $plan.RequiredBackupBytes -eq 1302MB) 'Exact thresholds miscomputed'
}
Check 'C one byte below threshold rejected' {
    Assert-Throws { Get-StagingSpacePlan -WimBytes 400MB -RecoveryPartitionBytes 523MB -CFreeBytes (656MB - 1) -BackupFreeBytes 2GB }
}
Check 'Backup one byte below threshold rejected' {
    Assert-Throws { Get-StagingSpacePlan -WimBytes 400MB -RecoveryPartitionBytes 523MB -CFreeBytes 700MB -BackupFreeBytes (1302MB - 1) }
}
Check 'Zero WIM rejected' {
    Assert-Throws { Get-StagingSpacePlan -WimBytes 0 -RecoveryPartitionBytes 523MB -CFreeBytes 2GB -BackupFreeBytes 2GB }
}
Check 'WIM larger than source partition rejected' {
    Assert-Throws { Get-StagingSpacePlan -WimBytes (523MB + 1) -RecoveryPartitionBytes 523MB -CFreeBytes 2GB -BackupFreeBytes 2GB }
}
Check 'WIM exactly source partition size accepted with sufficient space' {
    $plan = Get-StagingSpacePlan -WimBytes 523MB -RecoveryPartitionBytes 523MB -CFreeBytes 779MB -BackupFreeBytes 1302MB
    Assert ($plan.RequiredCBytes -eq 779MB) 'Equal-sized WIM incorrectly rejected or calculated'
}
Check 'Negative WIM rejected' {
    Assert-Throws { Get-StagingSpacePlan -WimBytes -1 -RecoveryPartitionBytes 523MB -CFreeBytes 2GB -BackupFreeBytes 2GB }
}
Check 'Zero recovery partition rejected' {
    Assert-Throws { Get-StagingSpacePlan -WimBytes 400MB -RecoveryPartitionBytes 0 -CFreeBytes 2GB -BackupFreeBytes 2GB }
}
Check 'Negative free C space rejected' {
    Assert-Throws { Get-StagingSpacePlan -WimBytes 400MB -RecoveryPartitionBytes 523MB -CFreeBytes -1 -BackupFreeBytes 2GB }
}
Check 'Negative free backup space rejected' {
    Assert-Throws { Get-StagingSpacePlan -WimBytes 400MB -RecoveryPartitionBytes 523MB -CFreeBytes 700MB -BackupFreeBytes -1 }
}
Write-Host "RESULT: $passed passed; $failed failed."
Write-Host 'Scope: actual pure capacity helper only; no Windows disk, file migration, or WinRE operations performed.'
if ($failed) { exit 1 }
