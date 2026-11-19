param(
    [string]$ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Move-WinRE-ExtendC.ps1'),
    [switch]$LegacyBaseline
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$helperNames = @('Get-RecoveryManifest')
if (-not $LegacyBaseline) {
    $helperNames += @('Initialize-RecoveryFileAccess', 'Get-RecoveryFileItem', 'Get-RecoveryChildItem',
        'Get-RecoveryFileHash', 'Copy-RecoveryFile', 'New-RecoveryDirectory', 'Join-RecoveryPath',
        'Assert-RecoveryManifest', 'Copy-RecoveryPayload')
}
$missing = @()
foreach ($name in $helperNames) {
    $definitions = @($ast.FindAll({param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true))
    if ($definitions.Count -ne 1) { $missing += $name; continue }
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}
if ($missing.Count) { throw ('FAIL: Production helpers missing: ' + ($missing -join ', ')) }
if ($env:OS -ne 'Windows_NT') {
    Write-Host 'SKIP real volume-GUID fixture: Windows and its Storage provider are required.'
    Write-Host 'RESULT: 0 passed; 0 failed; 1 skipped.'
    exit 0
}
Import-Module Storage -ErrorAction Stop
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('WinRE-VolumeGuid-QA-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
$passed = 0; $failed = 0
try {
    $source = Join-Path $fixture 'source [literal]'
    $recovery = Join-Path $source 'Recovery\WindowsRE'
    [IO.Directory]::CreateDirectory($recovery) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $recovery 'empty\nested')) | Out-Null
    $wim = Join-Path $recovery 'Winre.wim'
    $payload = [Text.Encoding]::UTF8.GetBytes('Disposable GUID-path regression fixture; not a real recovery image.')
    [IO.File]::WriteAllBytes($wim, $payload)
    $expectedHash = (Get-FileHash -LiteralPath $wim -Algorithm SHA256).Hash
    $driveRoot = [IO.Path]::GetPathRoot($source)
    if ($driveRoot -notmatch '^[A-Za-z]:\\$') { throw 'The TEMP fixture must reside on a local drive-letter volume.' }
    $volumes = @(Get-Volume -DriveLetter ([char]$driveRoot[0]) -ErrorAction Stop)
    if ($volumes.Count -ne 1 -or [string]$volumes[0].Path -notmatch '^\\\\\?\\Volume\{[0-9A-Fa-f-]+\}\\$') {
        throw 'Could not resolve the TEMP drive to exactly one existing volume GUID path.'
    }
    # Construct the GUID fixture path without using the provider under test.
    $guidSource = ([string]$volumes[0].Path).TrimEnd('\') + '\' + $source.Substring($driveRoot.Length)
    Write-Host "Runtime: $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion); LegacyBaseline=$LegacyBaseline"
    Write-Host 'Fixture is an ordinary temporary directory accessed through the existing volume GUID. No volume access path is added.'
    try {
        $manifest = @(Get-RecoveryManifest -Root $guidSource -WithHash)
        $image = @($manifest | Where-Object { $_.RelativePath -eq 'Recovery\WindowsRE\Winre.wim' })
        if ($image.Count -ne 1 -or $image[0].Length -ne $payload.Length -or $image[0].Hash -ne $expectedHash) {
            throw 'GUID manifest did not reproduce the known ordinary-path WIM bytes and hash.'
        }
        if (@($manifest | Where-Object { $_.RelativePath -eq 'Recovery\WindowsRE\empty\nested' -and $_.IsDirectory }).Count -ne 1) {
            throw 'GUID manifest omitted the nested empty directory.'
        }
        $passed++
        Write-Host 'PASS real volume-GUID recovery manifest and known WIM hash'
    } catch {
        $failed++
        Write-Host "FAIL real volume-GUID recovery manifest: $($_.Exception.Message)"
        Write-Host $_.ScriptStackTrace
    }
} finally { Remove-Item -LiteralPath $fixture -Recurse -Force }
Write-Host "RESULT: $passed passed; $failed failed; 0 skipped."
Write-Host 'Scope: temporary files on an existing Windows volume only. No disk, partition, WinRE, BitLocker, boot, or mount operations executed.'
if ($failed) { exit 1 }
