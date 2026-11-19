param([string]$ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Move-WinRE-ExtendC.ps1'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Parse and load only the four helpers under test. Never execute the production
# script body, its platform checks, or its disk/WinRE/BitLocker operations.
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$helperNames = @('New-PartitionIdentity', 'Assert-PartitionIdentity', 'Get-RecoveryManifest', 'Assert-RecoveryManifest')
$missing = @()
foreach ($name in $helperNames) {
    $matches = @($ast.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true))
    if ($matches.Count -ne 1) {
        $missing += $name
        Write-Host "FAIL Required helper $name : expected exactly one definition; found $($matches.Count)."
    } else { . ([scriptblock]::Create($matches[0].Extent.Text)) }
}
if ($missing.Count) {
    Write-Host "RESULT: 0 passed; $($missing.Count) missing helper failures."
    exit 1
}

$passed = 0; $failed = 0; $skipped = 0
function Check([string]$Name, [scriptblock]$Action) {
    try { & $Action; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$ReasonPattern = '') {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    Assert ($null -ne $caught) 'An unsafe change was accepted.'
    if ($ReasonPattern) {
        Assert ($caught.Exception.Message -match $ReasonPattern) "Wrong rejection reason: $($caught.Exception.Message)"
    }
}
function IdentityFixture([string]$Style = 'GPT') {
    [pscustomobject]@{
        Disk = [pscustomobject]@{
            Number = [uint32]0; UniqueId = '6000C29E633D5777289C1E5394269F63'
            Size = [uint64]100GB; PartitionStyle = $Style
            Guid = '{7762d140-d94b-4aaf-ab48-6336a08b5b2c}'; Signature = [uint32]305419896
        }
        Partition = [pscustomobject]@{
            DiskNumber = [uint32]0; PartitionNumber = [uint32]4
            Offset = [uint64]80GB; Size = [uint64]523MB
            Guid = $(if ($Style -eq 'GPT') { '{829a635a-6b4a-40e3-93f4-7893c902a760}' } else { '' })
            GptType = $(if ($Style -eq 'GPT') { '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}' } else { '' })
            MbrType = $(if ($Style -eq 'MBR') { [uint16]39 } else { [uint16]0 })
            DriveLetter = [char]0; IsBoot = $false; IsSystem = $false; IsActive = $false
        }
        VolumePath = '\\?\Volume{ab1ecf52-07c3-4c8c-9030-cc4ccf2d9733}\'
    }
}

Check 'Identity records the verified disk, physical bounds, and unique partition GUID' {
    $f = IdentityFixture
    $i = New-PartitionIdentity $f.Disk $f.Partition $f.VolumePath
    Assert ($i.DiskNumber -eq 0 -and $i.DiskUniqueId -eq '6000C29E633D5777289C1E5394269F63') 'Disk identity not captured.'
    Assert ($i.DiskSize -eq 100GB -and $i.PartitionStyle -eq 'GPT') 'Disk size/style not captured.'
    Assert ($i.Offset -eq 80GB -and $i.Size -eq 523MB) 'Physical partition bounds not captured.'
    Assert (([string]$i.Guid).Trim('{}') -ieq '829a635a-6b4a-40e3-93f4-7893c902a760') 'Partition GUID was lost or confused with GptType.'
    Assert ($i.VolumePath -eq $f.VolumePath) 'Volume GUID path not captured.'
    Assert-PartitionIdentity $i $f.Disk $f.Partition $f.VolumePath
}
foreach ($style in @('GPT', 'MBR')) {
    Check "$style partition renumbering preserves identity" {
        $f = IdentityFixture $style
        $i = New-PartitionIdentity $f.Disk $f.Partition $f.VolumePath
        $f.Partition.PartitionNumber = 2
        Assert-PartitionIdentity $i $f.Disk $f.Partition $f.VolumePath
    }
}
foreach ($case in @(
    @{ Property = 'UniqueId'; Value = 'A_DIFFERENT_PHYSICAL_DISK' },
    @{ Property = 'Number'; Value = [uint32]1 },
    @{ Property = 'Size'; Value = [uint64]101GB },
    @{ Property = 'PartitionStyle'; Value = 'MBR' }
)) {
    Check "Identity rejects changed disk $($case.Property)" {
        $f = IdentityFixture
        $i = New-PartitionIdentity $f.Disk $f.Partition $f.VolumePath
        $f.Disk.($case.Property) = $case.Value
        Assert-Throws { Assert-PartitionIdentity $i $f.Disk $f.Partition $f.VolumePath }
    }
}
foreach ($case in @(
    @{ Property = 'DiskNumber'; Value = [uint32]1 },
    @{ Property = 'Offset'; Value = [uint64](80GB + 1MB) },
    @{ Property = 'Size'; Value = [uint64](523MB + 1MB) },
    @{ Property = 'Guid'; Value = '{a21b0f88-6405-4d98-b1da-dcc8d30ae853}' }
)) {
    Check "Identity rejects changed partition $($case.Property)" {
        $f = IdentityFixture
        $i = New-PartitionIdentity $f.Disk $f.Partition $f.VolumePath
        $f.Partition.($case.Property) = $case.Value
        Assert-Throws { Assert-PartitionIdentity $i $f.Disk $f.Partition $f.VolumePath }
    }
}
Check 'Identity rejects a drive letter remapped to another volume GUID' {
    $f = IdentityFixture
    $i = New-PartitionIdentity $f.Disk $f.Partition $f.VolumePath
    Assert-Throws { Assert-PartitionIdentity $i $f.Disk $f.Partition '\\?\Volume{e8a3a130-9a11-4c6a-b652-a18c6bfbf833}\' }
}
Check 'Windows volume GUID path comparison tolerates case changes' {
    $f = IdentityFixture
    $i = New-PartitionIdentity $f.Disk $f.Partition $f.VolumePath
    Assert-PartitionIdentity $i $f.Disk $f.Partition $f.VolumePath.ToUpperInvariant()
}
Check 'An unrecorded volume path does not invalidate a new known volume path' {
    $f = IdentityFixture
    $i = New-PartitionIdentity $f.Disk $f.Partition
    Assert-PartitionIdentity $i $f.Disk $f.Partition $f.VolumePath
}
Check 'AllowSizeChange permits expected C growth with unchanged identity' {
    $f = IdentityFixture
    $i = New-PartitionIdentity $f.Disk $f.Partition $f.VolumePath
    $f.Partition.Size += 1GB
    Assert-PartitionIdentity $i $f.Disk $f.Partition $f.VolumePath -AllowSizeChange
}
Check 'AllowSizeChange does not permit moving the partition start' {
    $f = IdentityFixture
    $i = New-PartitionIdentity $f.Disk $f.Partition $f.VolumePath
    $f.Partition.Offset += 1MB
    $f.Partition.Size += 1GB
    Assert-Throws { Assert-PartitionIdentity $i $f.Disk $f.Partition $f.VolumePath -AllowSizeChange }
}
Check 'AllowSizeChange does not permit replacing the GPT partition' {
    $f = IdentityFixture
    $i = New-PartitionIdentity $f.Disk $f.Partition $f.VolumePath
    $f.Partition.Guid = '{a21b0f88-6405-4d98-b1da-dcc8d30ae853}'
    $f.Partition.Size += 1GB
    Assert-Throws { Assert-PartitionIdentity $i $f.Disk $f.Partition $f.VolumePath -AllowSizeChange }
}
foreach ($badId in @('', '   ')) {
    Check 'An empty or whitespace disk UniqueId cannot form a destructive-operation identity' {
        $f = IdentityFixture
        $f.Disk.UniqueId = $badId
        Assert-Throws { New-PartitionIdentity $f.Disk $f.Partition }
    }
}
Check 'GPT identity refuses an empty partition GUID' {
    $f = IdentityFixture
    $f.Partition.Guid = ''
    Assert-Throws { New-PartitionIdentity $f.Disk $f.Partition }
}
Check 'GPT identity refuses a missing partition GUID property' {
    $f = IdentityFixture
    $f.Partition.PSObject.Properties.Remove('Guid')
    Assert-Throws { New-PartitionIdentity $f.Disk $f.Partition }
}
Check 'MBR identity accepts the absence of a GPT partition GUID' {
    $f = IdentityFixture MBR
    $i = New-PartitionIdentity $f.Disk $f.Partition $f.VolumePath
    Assert ([string]::IsNullOrEmpty([string]$i.Guid)) 'MBR fixture acquired a fictitious GPT GUID.'
    Assert-PartitionIdentity $i $f.Disk $f.Partition $f.VolumePath
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('WinRE-ManifestQA-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
function Write-TestFile([string]$Path, [string]$Content) {
    [IO.File]::WriteAllBytes($Path, [Text.Encoding]::ASCII.GetBytes($Content))
}
function New-ManifestFixture {
    $root = Join-Path $script:testRoot ([guid]::NewGuid().ToString('N'))
    foreach ($relative in @(
        '', 'Recovery', 'Recovery/WindowsRE', 'Recovery/OEM', 'Recovery/OEM/Empty',
        'System Volume Information', '$RECYCLE.BIN',
        'Recovery/System Volume Information', 'Recovery/$RECYCLE.BIN'
    )) {
        $path = $root
        if ($relative) { $path = Join-Path $root $relative }
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    Write-TestFile (Join-Path $root 'Recovery/WindowsRE/Winre.wim') 'abc'
    Write-TestFile (Join-Path $root 'Recovery/WindowsRE/boot.sdi') 'hello'
    Write-TestFile (Join-Path $root 'Recovery/OEM/config.ini') 'OEM'
    Write-TestFile (Join-Path $root 'Recovery/System Volume Information/keep.txt') 's'
    Write-TestFile (Join-Path $root 'Recovery/$RECYCLE.BIN/keep.txt') 'r'
    Write-TestFile (Join-Path $root 'loose.txt') 'x'
    Write-TestFile (Join-Path $root 'System Volume Information/excluded.txt') 'not recovery data'
    Write-TestFile (Join-Path $root '$RECYCLE.BIN/excluded.txt') 'not recovery data'
    return $root
}
function ManifestMap($Entries) {
    $map = @{}
    foreach ($entry in @($Entries)) {
        $path = ([string]$entry.RelativePath).Replace('\', '/')
        Assert (-not $map.ContainsKey($path)) "Duplicate relative path: $path"
        $map[$path] = $entry
    }
    return $map
}
function ManifestEntry([string]$Path, [bool]$Directory, [long]$Length = 0, [AllowEmptyString()][string]$Hash = '') {
    [pscustomobject]@{ RelativePath = $Path; IsDirectory = $Directory; Length = $Length; Hash = $Hash }
}
function ComparisonFixture {
    @(
        (ManifestEntry 'Recovery' $true),
        (ManifestEntry 'Recovery\WindowsRE' $true),
        (ManifestEntry 'Recovery\WindowsRE\Winre.wim' $false 3 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD'),
        (ManifestEntry 'Recovery\WindowsRE\boot.sdi' $false 5 '2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824')
    )
}

try {
    Check 'Manifest includes nested files and empty directories, excluding only root metadata folders' {
        $root = New-ManifestFixture
        $entries = @(Get-RecoveryManifest -Root $root)
        $map = ManifestMap $entries
        $paths = @(
            'Recovery', 'Recovery/WindowsRE', 'Recovery/OEM', 'Recovery/OEM/Empty',
            'Recovery/WindowsRE/Winre.wim', 'Recovery/WindowsRE/boot.sdi', 'Recovery/OEM/config.ini',
            'Recovery/System Volume Information', 'Recovery/System Volume Information/keep.txt',
            'Recovery/$RECYCLE.BIN', 'Recovery/$RECYCLE.BIN/keep.txt', 'loose.txt'
        )
        Assert ($entries.Count -eq 12) "Expected 12 entries; got $($entries.Count)."
        foreach ($path in $paths) { Assert ($map.ContainsKey($path)) "Missing fixture path $path" }
        Assert ($map['Recovery/OEM/Empty'].IsDirectory) 'Empty directory was lost or classified as a file.'
        Assert (-not $map['Recovery/WindowsRE/Winre.wim'].IsDirectory) 'WIM classified as a directory.'
        Assert ($map['Recovery/WindowsRE/Winre.wim'].Length -eq 3) 'WIM byte length is wrong.'
        Assert ($map['Recovery/WindowsRE/boot.sdi'].Length -eq 5) 'Boot file byte length is wrong.'
        foreach ($entry in $entries) {
            Assert (-not [IO.Path]::IsPathRooted([string]$entry.RelativePath)) 'Manifest leaked an absolute path.'
            Assert ([string]::IsNullOrEmpty([string]$entry.Hash)) 'Hash populated without WithHash.'
        }
    }
    Check 'Manifest SHA256 matches known file bytes' {
        $root = New-ManifestFixture
        $entries = @(Get-RecoveryManifest -Root $root -WithHash)
        $map = ManifestMap $entries
        Assert ($map['Recovery/WindowsRE/Winre.wim'].Hash -ieq 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD') 'SHA256 of abc did not match.'
        Assert ($map['Recovery/WindowsRE/boot.sdi'].Hash -ieq '2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824') 'SHA256 of hello did not match.'
        foreach ($entry in $entries) {
            if ($entry.IsDirectory) { Assert ([string]::IsNullOrEmpty([string]$entry.Hash)) 'A directory acquired a file hash.' }
            else { Assert ($entry.Hash -match '^[0-9a-fA-F]{64}$') 'A file lacks a SHA256 digest.' }
        }
    }
    Check 'Manifest roots with or without a trailing separator describe the same files' {
        $root = New-ManifestFixture
        $a = @(Get-RecoveryManifest -Root $root -WithHash)
        $b = @(Get-RecoveryManifest -Root ($root + [IO.Path]::DirectorySeparatorChar) -WithHash)
        Assert-RecoveryManifest $a $b
    }
    Check 'Missing manifest root is rejected' {
        Assert-Throws { Get-RecoveryManifest -Root (Join-Path $testRoot 'does-not-exist') }
    }
    Check 'A file cannot be used as the recovery root' {
        $root = New-ManifestFixture
        Assert-Throws { Get-RecoveryManifest -Root (Join-Path $root 'loose.txt') }
    }
    Check 'Manifest comparison detects a same-length content change in real files' {
        $root = New-ManifestFixture
        $before = @(Get-RecoveryManifest -Root $root -WithHash)
        Write-TestFile (Join-Path $root 'Recovery/WindowsRE/Winre.wim') 'abd'
        $after = @(Get-RecoveryManifest -Root $root -WithHash)
        Assert-Throws { Assert-RecoveryManifest $before $after }
    }
    Check 'Manifest comparison detects a new file in a real directory tree' {
        $root = New-ManifestFixture
        $before = @(Get-RecoveryManifest -Root $root -WithHash)
        Write-TestFile (Join-Path $root 'Recovery/WindowsRE/unexpected.bin') 'new'
        Assert-Throws { Assert-RecoveryManifest $before @(Get-RecoveryManifest -Root $root -WithHash) }
    }
    Check 'Matching manifests are accepted without depending on enumeration order' {
        $expected = @(ComparisonFixture)
        $actual = @(ComparisonFixture)
        [array]::Reverse($actual)
        Assert-RecoveryManifest $expected $actual
    }
    Check 'Relative path comparison follows Windows case-insensitive semantics' {
        $expected = @(ComparisonFixture)
        $actual = @(ComparisonFixture)
        foreach ($entry in $actual) { $entry.RelativePath = $entry.RelativePath.ToUpperInvariant() }
        Assert-RecoveryManifest $expected $actual
    }
    Check 'Missing backup file is rejected' {
        $expected = @(ComparisonFixture)
        $actual = @((ComparisonFixture) | Where-Object { $_.RelativePath -notlike '*boot.sdi' })
        Assert-Throws { Assert-RecoveryManifest $expected $actual }
    }
    Check 'Unexpected backup file is rejected' {
        $expected = @(ComparisonFixture)
        $actual = @(ComparisonFixture) + @(ManifestEntry 'unexpected.bin' $false 1 ('A' * 64))
        Assert-Throws { Assert-RecoveryManifest $expected $actual }
    }
    Check 'Renaming a file is rejected even when count, length and hash match' {
        $expected = @(ComparisonFixture)
        $actual = @(ComparisonFixture)
        $actual[3].RelativePath = 'Recovery\WindowsRE\renamed.sdi'
        Assert-Throws { Assert-RecoveryManifest $expected $actual }
    }
    Check 'Changed file length is rejected' {
        $expected = @(ComparisonFixture)
        $actual = @(ComparisonFixture)
        $actual[2].Length = 4
        Assert-Throws { Assert-RecoveryManifest $expected $actual }
    }
    Check 'Changed file hash is rejected even when length matches' {
        $expected = @(ComparisonFixture)
        $actual = @(ComparisonFixture)
        $actual[2].Hash = 'F' * 64
        Assert-Throws { Assert-RecoveryManifest $expected $actual }
    }
    Check 'Replacing a directory with a file is rejected' {
        $expected = @(ComparisonFixture)
        $actual = @(ComparisonFixture)
        $actual[1].IsDirectory = $false
        Assert-Throws { Assert-RecoveryManifest $expected $actual }
    }
    Check 'Case-equivalent duplicate entries are rejected' {
        $expected = @(ComparisonFixture)
        $actual = @(ComparisonFixture) + @(ManifestEntry 'RECOVERY\WINDOWSRE\WINRE.WIM' $false 3 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD')
        Assert-Throws { Assert-RecoveryManifest $expected $actual }
    }
    Check 'IgnoreHashes permits hash differences while retaining other comparisons' {
        $expected = @(ComparisonFixture)
        $actual = @(ComparisonFixture)
        $actual[2].Hash = ''
        $actual[3].Hash = 'F' * 64
        Assert-RecoveryManifest $expected $actual -IgnoreHashes
    }
    Check 'IgnoreHashes still rejects file-size differences' {
        $expected = @(ComparisonFixture)
        $actual = @(ComparisonFixture)
        $actual[2].Length = 4
        Assert-Throws { Assert-RecoveryManifest $expected $actual -IgnoreHashes }
    }
    Check 'IgnoreHashes still rejects unexpected files' {
        $expected = @(ComparisonFixture)
        $actual = @(ComparisonFixture) + @(ManifestEntry 'unexpected.bin' $false 0)
        Assert-Throws { Assert-RecoveryManifest $expected $actual -IgnoreHashes }
    }

    # Real symlinks exercise FileAttributes.ReparsePoint on Linux and Windows.
    # Their targets stay inside this disposable test tree, including cleanup.
    foreach ($linkKind in @('Directory', 'File', 'RootDirectory')) {
        $root = New-ManifestFixture
        $outside = Join-Path $testRoot ('outside-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $outside | Out-Null
        Write-TestFile (Join-Path $outside 'outside.txt') 'outside recovery payload'
        $target = $outside
        if ($linkKind -eq 'File') { $target = Join-Path $outside 'outside.txt' }
        $link = Join-Path $root 'Recovery/linked-entry'
        if ($linkKind -eq 'RootDirectory') { $link = Join-Path $testRoot ('root-link-' + [guid]::NewGuid().ToString('N')) }
        $created = $false
        try {
            New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop | Out-Null
            $created = $true
        } catch {
            $script:skipped++
            Write-Host "SKIP $linkKind reparse rejection: this host could not create a symbolic link. $($_.Exception.Message)"
        }
        if ($created) {
            Check "$linkKind reparse point is rejected rather than followed" {
                $manifestRoot = $root
                if ($linkKind -eq 'RootDirectory') { $manifestRoot = $link }
                Assert-Throws { Get-RecoveryManifest -Root $manifestRoot -WithHash } 'reparse|symbolic|link'
            }
        }
    }

    $root = New-ManifestFixture
    $efsFile = Join-Path $root 'Recovery/OEM/config.ini'
    $efsAvailable = $false
    try {
        [IO.File]::Encrypt($efsFile)
        $efsAvailable = ((Get-Item -LiteralPath $efsFile -Force).Attributes -band [IO.FileAttributes]::Encrypted) -ne 0
    } catch { $efsAvailable = $false }
    if ($efsAvailable) {
        Check 'EFS-encrypted recovery file is rejected before backup' {
            Assert-Throws { Get-RecoveryManifest -Root $root -WithHash } 'encrypt|EFS'
        }
    } else {
        $script:skipped++
        Write-Host 'SKIP EFS rejection: this host/filesystem cannot create a real EFS-encrypted fixture.'
    }
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}

Write-Host "RESULT: $passed passed; $failed failed; $skipped skipped."
Write-Host 'Scope: production identity/manifest helpers and disposable filesystem fixtures only. No Windows disk, WinRE, or BitLocker operations executed.'
if ($failed) { exit 1 }
