param([string]$ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Move-WinRE-ExtendC.ps1'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$missing = @()
foreach ($name in @('Get-RecoverySize', 'Get-CGrowthTarget')) {
    $definitions = @($ast.FindAll({param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true))
    if ($definitions.Count -ne 1) { $missing += $name; continue }
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}
if ($missing.Count) { throw ('FAIL: Production helper implementation missing: ' + ($missing -join ', ')) }
$passed = 0; $failed = 0
function Check([string]$Name, [scriptblock]$Action) {
    try { & $Action; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert $threw 'Invalid capacity or shrink/no-growth case accepted'
}
function Os([long]$Offset = 101MB, [long]$Size = 79GB) { [pscustomobject]@{Offset = $Offset; Size = $Size} }

Check 'Small recovery payload uses the 1 GiB minimum and UInt64 result' {
    $result = Get-RecoverySize -WimBytes 400MB -OtherBytes 10MB
    Assert ($result -eq 1GB -and $result -is [uint64]) 'Minimum or return type incorrect'
}
Check 'Large recovery payload reserves image, other files and 350 MiB' {
    Assert ((Get-RecoverySize -WimBytes 900MB -OtherBytes 100MB) -eq 1350MB) 'Payload headroom incorrect'
}
Check 'Recovery allocation rounds fractional MiB up' {
    Assert ((Get-RecoverySize -WimBytes (900MB + 1) -OtherBytes 0) -eq 1251MB) 'Recovery allocation rounded down'
}
Check 'Explicit recovery minimum honored' {
    Assert ((Get-RecoverySize -WimBytes 400MB -OtherBytes 0 -MinimumSizeMB 2048) -eq 2GB) 'Explicit minimum ignored'
}
Check 'Zero WIM rejected' { Assert-Throws { Get-RecoverySize -WimBytes 0 -OtherBytes 0 } }
Check 'Negative WIM rejected' { Assert-Throws { Get-RecoverySize -WimBytes -1 -OtherBytes 0 } }
Check 'Negative other payload rejected' { Assert-Throws { Get-RecoverySize -WimBytes 400MB -OtherBytes -1 } }
Check 'Sub-GiB minimum rejected' { Assert-Throws { Get-RecoverySize -WimBytes 400MB -OtherBytes 0 -MinimumSizeMB 1023 } }

Check 'Supported size beyond the growth limit is capped rather than rejected' {
    $os = Os
    $limit = 99GB - 1MB
    $result = Get-CGrowthTarget -OsPartition $os -SupportedSizeMax 100GB -CGrowthLimit $limit
    Assert ($result -is [uint64] -and $result -eq ($limit - $os.Offset)) 'Target not capped to the recovery boundary'
}
Check 'Smaller supported size honored' {
    $os = Os
    $result = Get-CGrowthTarget -OsPartition $os -SupportedSizeMax 80GB -CGrowthLimit (100GB - 1MB)
    Assert ($result -eq 80GB) 'Target exceeds supported maximum'
}
Check 'Fractional supported size rounds absolute end down to MiB' {
    $os = Os
    $result = Get-CGrowthTarget -OsPartition $os -SupportedSizeMax (79GB + 10MB + 512KB) -CGrowthLimit (100GB - 1MB)
    Assert ($result -eq (79GB + 10MB)) 'Supported end rounded up or relative size misaligned'
}
Check 'Unaligned OS start still yields an aligned absolute end' {
    $os = Os (101MB + 512KB)
    $result = Get-CGrowthTarget -OsPartition $os -SupportedSizeMax (79GB + 10MB) -CGrowthLimit (100GB - 1MB)
    Assert ($result -eq (79GB + 9MB + 512KB)) 'Unaligned OS start handled incorrectly'
    Assert ((($os.Offset + $result) % 1MB) -eq 0) 'Absolute C end is not MiB aligned'
}
Check 'Unaligned growth limit is rounded down before selecting the target' {
    $os = Os
    $result = Get-CGrowthTarget -OsPartition $os -SupportedSizeMax 100GB -CGrowthLimit (99GB + 512KB)
    Assert (($os.Offset + $result) -eq 99GB) 'Target crosses the rounded safe boundary'
}
Check 'Exactly 1 MiB growth accepted' {
    $os = Os
    Assert ((Get-CGrowthTarget -OsPartition $os -SupportedSizeMax (79GB + 1MB) -CGrowthLimit (100GB - 1MB)) -eq (79GB + 1MB)) 'Minimum growth rejected'
}
Check 'Supported maximum smaller than current C rejected' {
    $os = Os
    Assert-Throws { Get-CGrowthTarget -OsPartition $os -SupportedSizeMax (79GB - 1MB) -CGrowthLimit (100GB - 1MB) }
}
Check 'Zero growth rejected' {
    $os = Os
    Assert-Throws { Get-CGrowthTarget -OsPartition $os -SupportedSizeMax 79GB -CGrowthLimit (100GB - 1MB) }
}
Check 'Sub-MiB growth after rounding rejected' {
    $os = Os
    Assert-Throws { Get-CGrowthTarget -OsPartition $os -SupportedSizeMax (79GB + 512KB) -CGrowthLimit (100GB - 1MB) }
}
Check 'Growth limit behind current C end rejected' {
    $os = Os
    Assert-Throws { Get-CGrowthTarget -OsPartition $os -SupportedSizeMax 100GB -CGrowthLimit ($os.Offset + 78GB) }
}
Check 'Growth limit before C start rejected without unsigned wraparound' {
    $os = Os
    Assert-Throws { Get-CGrowthTarget -OsPartition $os -SupportedSizeMax 100GB -CGrowthLimit 1MB }
}
Write-Host "RESULT: $passed passed; $failed failed."
Write-Host 'Scope: production pure sizing helpers only; no Windows operations performed.'
if ($failed) { exit 1 }
