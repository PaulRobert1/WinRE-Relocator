<#
.SYNOPSIS
Runs only read-only helper tests and temporary-file fixtures, never the main operation.
.DESCRIPTION
The main script is parsed, checked for known post-5.1 syntax and encoding hazards,
then the explicitly listed test suites run in isolated PowerShell processes.
No disk partition, WinRE, BitLocker, boot, or reboot operations are executed.
#>
param([string]$ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Move-WinRE-ExtendC.ps1'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) {
    Write-Host ($parseErrors | Out-String)
    throw "Main script has $($parseErrors.Count) parser errors."
}
Write-Host 'PASS full main-script parse: 0 errors'

$compatibilityFailures = @()
$post51Nodes = @($ast.FindAll({param($node)
    $typeName = $node.GetType().Name
    if ($typeName -in @('TernaryExpressionAst', 'PipelineChainAst')) { return $true }
    if ($node.PSObject.Properties['NullConditional'] -and $node.NullConditional) { return $true }
    return $false
}, $true))
foreach ($node in $post51Nodes) {
    $compatibilityFailures += "Post-5.1 syntax $($node.GetType().Name) at line $($node.Extent.StartLineNumber)"
}
foreach ($token in $tokens) {
    if ([string]$token.Kind -in @('QuestionQuestion', 'QuestionQuestionEquals')) {
        $compatibilityFailures += "Post-5.1 operator $($token.Text) at line $($token.Extent.StartLineNumber)"
    }
}
# Static ::new is intentionally permitted: it is supported by Windows PowerShell 5.
$bytes = [IO.File]::ReadAllBytes($ScriptPath)
$hasUtf8Bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
$hasUtf16Bom = $bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))
if (-not $hasUtf8Bom -and -not $hasUtf16Bom -and @($bytes | Where-Object { $_ -gt 127 }).Count -gt 0) {
    $compatibilityFailures += 'Non-ASCII main source without a Unicode BOM is unsafe on legacy Windows PowerShell 5.1 code pages.'
}
if ($compatibilityFailures.Count) {
    foreach ($problem in $compatibilityFailures) { Write-Host "FAIL compatibility: $problem" }
} else { Write-Host 'PASS known PowerShell 5.1 syntax/encoding compatibility guards' }

$hostExecutable = Join-Path $PSHOME 'powershell.exe'
if ($PSVersionTable.PSEdition -eq 'Core') {
    $hostExecutable = Join-Path $PSHOME 'pwsh'
    if (Test-Path -LiteralPath (Join-Path $PSHOME 'pwsh.exe')) { $hostExecutable = Join-Path $PSHOME 'pwsh.exe' }
}
if (-not (Test-Path -LiteralPath $hostExecutable -PathType Leaf)) { throw 'Cannot find the current PowerShell host executable.' }
$testFiles = @(
    'Test-WinREHelpers.ps1',
    'Test-ReportedMBRLayout.ps1',
    'Test-WinREPlacement.ps1',
    'Test-WinREStagingSpace.ps1',
    'Test-WinRECapacityHelpers.ps1',
    'Test-WinREIdentityAndManifest.ps1',
    'Test-WinRENativeAndAttributes.ps1',
    'Test-WinREVolumeGuidPaths.ps1'
)
$results = @()
foreach ($testFile in $testFiles) {
    Write-Host "`nRunning $testFile"
    $testPath = Join-Path $PSScriptRoot $testFile
    $priorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $hostExecutable -NoLogo -NoProfile -NonInteractive -File $testPath -ScriptPath $ScriptPath 2>&1)
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $priorPreference }
    $lines = @($output | ForEach-Object { [string]$_ })
    foreach ($line in $lines) { Write-Host $line }
    $summary = [regex]::Match(($lines -join "`n"), '(?m)^RESULT:\s*(\d+) passed;\s*(\d+) failed(?:;\s*(\d+) skipped)?\.')
    $passed = 0; $failed = 0; $skipped = 0
    if ($summary.Success) {
        $passed = [int]$summary.Groups[1].Value
        $failed = [int]$summary.Groups[2].Value
        if ($summary.Groups[3].Success) { $skipped = [int]$summary.Groups[3].Value }
    } else {
        $failed = 1
        if ($exitCode -eq 0) { $exitCode = 1 }
        Write-Host 'FAIL suite did not report its expected test summary'
    }
    $results += [pscustomobject]@{ Suite = $testFile; Passed = $passed; Failed = $failed; Skipped = $skipped; ExitCode = $exitCode }
}
$results | Format-Table -AutoSize | Out-Host
$totalPassed = ($results | Measure-Object Passed -Sum).Sum
$totalFailed = ($results | Measure-Object Failed -Sum).Sum
$totalSkipped = ($results | Measure-Object Skipped -Sum).Sum
Write-Host "TOTAL: $totalPassed passed; $totalFailed failed; $totalSkipped skipped; $($compatibilityFailures.Count) compatibility failures."
Write-Host "Runtime: $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion). These results do not establish Windows storage integration or WinRE bootability."
if ($compatibilityFailures.Count -or @($results | Where-Object { $_.ExitCode -ne 0 -or $_.Failed -ne 0 }).Count) { exit 1 }
