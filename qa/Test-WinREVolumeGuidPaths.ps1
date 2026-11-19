param(
    [string]$ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Move-WinRE-ExtendC.ps1'),
    [switch]$LegacyBaseline
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
if ($LegacyBaseline -and $null -ne $ast.Find({param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Initialize-RecoveryFileAccess'
}, $true)) {
    throw 'LegacyBaseline requires the original pre-adapter script. Pass the v3.0.0 source with -ScriptPath; do not interpret missing wrapper dependencies as a legacy path failure.'
}
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
$script:passed = 0; $script:failed = 0; $script:skipped = 0
function Check([string]$Name, [scriptblock]$Action) {
    try { & $Action; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)"; Write-Host $_.ScriptStackTrace }
}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Reason = '') {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    Assert ($null -ne $caught) 'Expected refusal did not occur.'
    if ($Reason) { Assert ($caught.Exception.Message -match $Reason) "Unexpected refusal: $($caught.Exception.Message)" }
}
function Skip([string]$Reason) { $script:skipped++; Write-Host "SKIP $Reason" }
if (-not $LegacyBaseline) {
    Check 'GUID string join preserves the existing root without provider normalization' {
        $root = '\\?\Volume{12345678-1234-1234-1234-123456789abc}\'
        $joined = Join-RecoveryPath -Root $root -RelativePath 'Recovery\WindowsRE'
        Assert ($joined -eq ($root + 'Recovery\WindowsRE')) 'GUID root was altered or joined incorrectly.'
    }
    Check 'GUID string join rejects a volume root missing its required separator' {
        $root = '\\?\Volume{12345678-1234-1234-1234-123456789abc}'
        Assert-Throws { Join-RecoveryPath -Root $root -RelativePath 'literal [file] name' } 'volume-GUID'
    }
    Check 'Ordinary string join preserves the normal platform path behavior' {
        $root = [IO.Path]::GetTempPath()
        Assert ((Join-RecoveryPath -Root $root -RelativePath 'ordinary [literal]') -eq (Join-Path $root 'ordinary [literal]')) 'Ordinary path fallback differs from Join-Path.'
    }
}
if ($env:OS -ne 'Windows_NT') {
    Skip 'real volume-GUID fixture: Windows and its Storage provider are required.'
    Write-Host "RESULT: $script:passed passed; $script:failed failed; $script:skipped skipped."
    if ($script:failed) { exit 1 }; exit 0
}
Import-Module Storage -ErrorAction Stop
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('WinRE-VolumeGuid-QA-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
try {
    $source = Join-Path $fixture 'source [literal]'
    $recovery = Join-Path $source 'Recovery\WindowsRE'
    [IO.Directory]::CreateDirectory($recovery) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $recovery 'empty\nested')) | Out-Null
    $wim = Join-Path $recovery 'Winre.wim'
    $payload = [Text.Encoding]::UTF8.GetBytes('Disposable GUID-path regression fixture; not a real recovery image.')
    [IO.File]::WriteAllBytes($wim, $payload)
    $expectedHash = (Get-FileHash -LiteralPath $wim -Algorithm SHA256).Hash
    $specialName = 'settings [literal] ' + [char]0x00E9 + [char]0x4E2D + '.ini'
    $specialRelative = 'Recovery\OEM\' + $specialName
    $specialBytes = [Text.Encoding]::UTF8.GetBytes('Known bytes in a literal Unicode and bracket-containing filename.')
    if (-not $LegacyBaseline) {
        [IO.Directory]::CreateDirectory((Join-Path $source 'Recovery\OEM')) | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $source $specialRelative), $specialBytes)
        [IO.File]::SetAttributes($wim, ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System -bor [IO.FileAttributes]::Archive))
    }
    $driveRoot = [IO.Path]::GetPathRoot($source)
    if ($driveRoot -notmatch '^[A-Za-z]:\\$') { throw 'The TEMP fixture must reside on a local drive-letter volume.' }
    $volumes = @(Get-Volume -DriveLetter ([char]$driveRoot[0]) -ErrorAction Stop)
    if ($volumes.Count -ne 1 -or [string]$volumes[0].Path -notmatch '^\\\\\?\\Volume\{[0-9A-Fa-f-]+\}\\$') {
        throw 'Could not resolve the TEMP drive to exactly one existing volume GUID path.'
    }
    # Construct the GUID fixture path without using the provider under test.
    $guidSource = ([string]$volumes[0].Path).TrimEnd('\') + '\' + $source.Substring($driveRoot.Length)
    $guidFixture = ([string]$volumes[0].Path).TrimEnd('\') + '\' + $fixture.Substring($driveRoot.Length)
    Write-Host "Runtime: $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion); LegacyBaseline=$LegacyBaseline"
    Write-Host 'Fixture is an ordinary temporary directory accessed through the existing volume GUID. No volume access path is added.'
    if (-not $LegacyBaseline) { Initialize-RecoveryFileAccess }
    Check 'real volume-GUID recovery manifest and known WIM hash' {
        $manifest = @(Get-RecoveryManifest -Root $guidSource -WithHash)
        $image = @($manifest | Where-Object { $_.RelativePath -eq 'Recovery\WindowsRE\Winre.wim' })
        if ($image.Count -ne 1 -or $image[0].Length -ne $payload.Length -or $image[0].Hash -ne $expectedHash) {
            throw 'GUID manifest did not reproduce the known ordinary-path WIM bytes and hash.'
        }
        if (@($manifest | Where-Object { $_.RelativePath -eq 'Recovery\WindowsRE\empty\nested' -and $_.IsDirectory }).Count -ne 1) {
            throw 'GUID manifest omitted the nested empty directory.'
        }
    }
    if (-not $LegacyBaseline) {
        $guidWim = Join-RecoveryPath -Root $guidSource -RelativePath 'Recovery\WindowsRE\Winre.wim'
        $backup = Join-Path $fixture 'ordinary backup [literal]'
        $restore = Join-Path $fixture 'restored [literal]'
        $guidRestore = Join-RecoveryPath -Root $guidFixture -RelativePath 'restored [literal]'
        [IO.Directory]::CreateDirectory($backup) | Out-Null
        $ordinaryManifest = @(Get-RecoveryManifest -Root $source -WithHash)

        Check 'Native adapter initialization is idempotent' {
            Initialize-RecoveryFileAccess
            Initialize-RecoveryFileAccess
        }
        Check 'Actual volume-GUID root metadata is a directory with the root separator intact' {
            $volumeRoot = [string]$volumes[0].Path
            $item = Get-RecoveryFileItem -LiteralPath $volumeRoot
            Assert ($item.PSIsContainer -and ($item.Attributes -band [IO.FileAttributes]::Directory) -ne 0) 'Volume root was not recognized as a directory.'
            Assert ($item.FullName -eq $volumeRoot) 'Volume-root identity or mandatory separator changed.'
        }
        Check 'GUID WIM metadata contains real length, attributes and UTC timestamp' {
            $item = Get-RecoveryFileItem -LiteralPath $guidWim
            $ordinary = Get-Item -LiteralPath $wim -Force
            Assert ($item.FullName -eq $guidWim -and $item.Name -eq 'Winre.wim') 'GUID metadata lost the literal file identity.'
            Assert (-not $item.PSIsContainer -and $item.Length -eq $payload.Length) 'WIM length or file type differs.'
            Assert (($item.Attributes -band [IO.FileAttributes]::Hidden) -ne 0 -and ($item.Attributes -band [IO.FileAttributes]::System) -ne 0) 'Hidden/system attributes were lost.'
            Assert (([datetime]$item.LastWriteTimeUtc - $ordinary.LastWriteTimeUtc).Duration().TotalSeconds -lt 1) 'UTC modification time differs.'
        }
        Check 'GUID directory metadata identifies a directory without a trailing slash' {
            $item = Get-RecoveryFileItem -LiteralPath $guidSource
            Assert ($item.PSIsContainer -and ($item.Attributes -band [IO.FileAttributes]::Directory) -ne 0) 'Directory metadata was not recognized.'
        }
        Check 'GUID SHA256 returns the known digest as one string' {
            $hash = Get-RecoveryFileHash -LiteralPath $guidWim
            Assert ($hash -is [string] -and $hash -eq $expectedHash) 'GUID SHA256 is missing or incorrect.'
        }
        Check 'GUID children enumerate literal entries without dot pseudo-directories' {
            $children = @(Get-RecoveryChildItem -LiteralPath (Join-RecoveryPath $guidSource 'Recovery\WindowsRE'))
            Assert ($children.Count -eq 2) 'Unexpected immediate child count.'
            Assert (@($children | Where-Object Name -eq 'Winre.wim').Count -eq 1) 'WIM is absent from enumeration.'
            Assert (@($children | Where-Object { $_.Name -in @('.', '..') }).Count -eq 0) 'Native pseudo-directory entries escaped filtering.'
        }
        Check 'GUID Unicode and bracket filename remains literal during lookup and enumeration' {
            $item = Get-RecoveryFileItem -LiteralPath (Join-RecoveryPath $guidSource $specialRelative)
            Assert ($item.Name -ceq $specialName -and $item.Length -eq $specialBytes.Length) 'Unicode or brackets were interpreted or changed.'
            $children = @(Get-RecoveryChildItem -LiteralPath (Join-RecoveryPath $guidSource 'Recovery\OEM'))
            Assert ($children.Count -eq 1 -and $children[0].Name -ceq $specialName) 'Unicode literal child enumeration differs.'
        }
        Check 'GUID and ordinary-path manifests describe identical files and empty directories' {
            Assert-RecoveryManifest -Expected $ordinaryManifest -Actual @(Get-RecoveryManifest -Root $guidSource -WithHash)
        }
        Check 'GUID payload copies to an ordinary backup with matching hashes and empty directories' {
            Copy-RecoveryPayload -Source $guidSource -Destination $backup -Manifest $ordinaryManifest
            Assert-RecoveryManifest -Expected $ordinaryManifest -Actual @(Get-RecoveryManifest -Root $backup -WithHash)
        }
        Check 'Ordinary backup restores through a GUID destination and remains byte-identical' {
            New-RecoveryDirectory -LiteralPath $guidRestore | Out-Null
            Copy-RecoveryPayload -Source $backup -Destination $guidRestore -Manifest $ordinaryManifest
            Assert-RecoveryManifest -Expected $ordinaryManifest -Actual @(Get-RecoveryManifest -Root $guidRestore -WithHash)
            Assert ((Get-FileHash -LiteralPath (Join-Path $restore 'Recovery\WindowsRE\Winre.wim') -Algorithm SHA256).Hash -eq $expectedHash) 'Drive-letter view of restored WIM differs.'
        }
        Check 'GUID directory creation handles nested empty folders and an existing destination' {
            $relative = 'created [literal]\deep\empty'
            $path = Join-RecoveryPath -Root $guidFixture -RelativePath $relative
            New-RecoveryDirectory -LiteralPath $path | Out-Null
            New-RecoveryDirectory -LiteralPath $path | Out-Null
            Assert ([IO.Directory]::Exists((Join-Path $fixture $relative))) 'Nested directory was not created.'
            Assert (@(Get-RecoveryChildItem -LiteralPath $path).Count -eq 0) 'New empty directory contains unexpected entries.'
        }
        Check 'GUID-to-GUID standalone copy preserves literal special-file bytes' {
            $destination = Join-RecoveryPath -Root $guidFixture -RelativePath ('copied ' + $specialName)
            Copy-RecoveryFile -LiteralPath (Join-RecoveryPath $guidSource $specialRelative) -Destination $destination
            $expected = (Get-FileHash -LiteralPath (Join-Path $source $specialRelative) -Algorithm SHA256).Hash
            Assert ((Get-RecoveryFileHash -LiteralPath $destination) -eq $expected) 'Standalone native copy changed file bytes.'
        }
        Check 'Copy-RecoveryFile overwrites a hidden read-only destination like Copy-Item Force' {
            $ordinaryTarget = Join-Path $fixture 'overwrite [literal].wim'
            [IO.File]::WriteAllBytes($ordinaryTarget, [byte[]]@(1, 2, 3))
            [IO.File]::SetAttributes($ordinaryTarget, ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::ReadOnly))
            $guidTarget = Join-RecoveryPath -Root $guidFixture -RelativePath 'overwrite [literal].wim'
            Copy-RecoveryFile -LiteralPath $guidWim -Destination $guidTarget
            Assert ((Get-FileHash -LiteralPath $ordinaryTarget -Algorithm SHA256).Hash -eq $expectedHash) 'Read-only destination was not replaced.'
        }
        Check 'AllowMissing returns null for a missing GUID file' {
            Assert ($null -eq (Get-RecoveryFileItem -LiteralPath (Join-RecoveryPath $guidFixture 'missing.wim') -AllowMissing)) 'Missing file did not return null.'
        }
        Check 'AllowMissing returns null for a missing parent directory' {
            Assert ($null -eq (Get-RecoveryFileItem -LiteralPath (Join-RecoveryPath $guidFixture 'missing-parent\missing.wim') -AllowMissing)) 'Missing parent did not return null.'
        }
        Check 'Missing GUID file throws when AllowMissing is absent' {
            Assert-Throws { Get-RecoveryFileItem -LiteralPath (Join-RecoveryPath $guidFixture 'missing.wim') }
        }
        Check 'Missing GUID source copy fails without creating a destination' {
            $destination = Join-RecoveryPath -Root $guidFixture -RelativePath 'missing-source-copy.wim'
            Assert-Throws { Copy-RecoveryFile -LiteralPath (Join-RecoveryPath $guidFixture 'missing.wim') -Destination $destination }
            Assert ($null -eq (Get-RecoveryFileItem -LiteralPath $destination -AllowMissing)) 'Failed source copy created a file.'
        }

        # Reparse fixtures remain inside this unique TEMP directory. They do not
        # add a drive letter, volume mount point, or access path to any partition.
        $reparseRoot = Join-Path $fixture 'reparse source'
        [IO.Directory]::CreateDirectory($reparseRoot) | Out-Null
        $replaceable = Join-Path $reparseRoot 'redirect.ini'
        [IO.File]::WriteAllBytes($replaceable, [byte[]]@(4, 5, 6))
        $beforeLink = @(Get-RecoveryManifest -Root $reparseRoot -WithHash)
        $linkReady = $false
        try {
            Remove-Item -LiteralPath $replaceable -Force
            New-Item -ItemType SymbolicLink -Path $replaceable -Target $wim -ErrorAction Stop | Out-Null
            $linkReady = $true
        } catch { Skip 'reparse fixture: symbolic-link creation is unavailable on this host.' }
        if ($linkReady) {
            $guidReparse = Join-RecoveryPath -Root $guidFixture -RelativePath 'reparse source'
            Check 'GUID manifest rejects a reparse file rather than following it' {
                Assert-Throws { Get-RecoveryManifest -Root $guidReparse -WithHash } 'reparse|symbolic|link'
            }
            Check 'GUID payload copy rejects a source replaced by a reparse file after inventory' {
                Assert-Throws { Copy-RecoveryPayload -Source $guidReparse -Destination $backup -Manifest $beforeLink } 'reparse|unsupported|link'
            }
        }
        $efsRoot = Join-Path $fixture 'efs source'
        [IO.Directory]::CreateDirectory($efsRoot) | Out-Null
        $efsFile = Join-Path $efsRoot 'secret.ini'
        [IO.File]::WriteAllBytes($efsFile, [byte[]]@(7, 8, 9))
        $beforeEncryption = @(Get-RecoveryManifest -Root $efsRoot -WithHash)
        $efsReady = $false
        try {
            [IO.File]::Encrypt($efsFile)
            $efsReady = (([IO.File]::GetAttributes($efsFile) -band [IO.FileAttributes]::Encrypted) -ne 0)
        } catch { $efsReady = $false }
        if ($efsReady) {
            $guidEfs = Join-RecoveryPath -Root $guidFixture -RelativePath 'efs source'
            Check 'GUID manifest retains refusal of a real EFS-encrypted file' {
                Assert-Throws { Get-RecoveryManifest -Root $guidEfs -WithHash } 'encrypt|EFS'
            }
            Check 'GUID payload copy rejects a source encrypted after inventory' {
                Assert-Throws { Copy-RecoveryPayload -Source $guidEfs -Destination $backup -Manifest $beforeEncryption } 'encrypt|unsupported|EFS'
            }
        } else { Skip 'EFS fixture: this host/filesystem cannot encrypt a disposable file.' }
    }
} finally { Remove-Item -LiteralPath $fixture -Recurse -Force }
Write-Host "RESULT: $script:passed passed; $script:failed failed; $script:skipped skipped."
Write-Host 'Scope: temporary files on an existing Windows volume only. No disk, partition, WinRE, BitLocker, boot, or mount operations executed.'
if ($script:failed) { exit 1 }
