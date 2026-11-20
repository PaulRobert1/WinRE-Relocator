param([string]$ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Move-WinRE-ExtendC.ps1'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$definitions = @($ast.FindAll({param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -in @('Get-PendingFileOperationAssessment', 'Assert-NoPendingMaintenance')
}, $true))
# Load real helper/gate definitions only. Never execute the main disk workflow.
foreach ($definition in $definitions) { . ([scriptblock]::Create($definition.Extent.Text)) }
if (@($definitions | Where-Object { $_.Name -eq 'Assert-NoPendingMaintenance' }).Count -ne 1) {
    throw 'Expected exactly one production Assert-NoPendingMaintenance function.'
}
$passed = 0; $failed = 0
function Check([string]$Name, [scriptblock]$Action) {
    try { & $Action; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$MessagePattern = '') {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    Assert ($null -ne $caught) 'Pending or malformed maintenance was allowed.'
    if ($MessagePattern) {
        Assert ($caught.Exception.Message -match $MessagePattern) "Unexpected failure: $($caught.Exception.Message)"
    }
}
function Get-Assessment($Session, [string]$Windows = 'C:\Windows',
    [string[]]$Programs = @('C:\Program Files', 'C:\Program Files (x86)')) {
    $output = @(Get-PendingFileOperationAssessment -SessionManager $Session -WindowsDirectory $Windows -ProgramFilesDirectories $Programs)
    Assert ($output.Count -eq 1) 'Assessment must return exactly one result object.'
    $result = $output[0]
    foreach ($name in @('OperationCount', 'AllowedCleanupCount', 'BlockedCount', 'CanAllowCleanup', 'Operations')) {
        Assert ($null -ne $result.PSObject.Properties[$name]) "Missing assessment property $name"
    }
    Assert ($null -ne $result.Operations -and $result.Operations -is [array]) 'Operations must be an array, including when empty.'
    Assert ($result.OperationCount -eq $result.Operations.Count) 'Operation count does not describe all records.'
    Assert (($result.AllowedCleanupCount + $result.BlockedCount) -eq $result.OperationCount) 'Allowed and blocked counts do not account for every operation.'
    Assert ($result.CanAllowCleanup -eq ($result.OperationCount -gt 0 -and $result.BlockedCount -eq 0)) 'Cleanup decision does not match assessed operations.'
    foreach ($operation in $result.Operations) {
        foreach ($name in @('ValueName', 'PairIndex', 'Source', 'Destination', 'Category', 'AllowedCleanup', 'Reason')) {
            Assert ($null -ne $operation.PSObject.Properties[$name]) "Missing operation property $name"
        }
        if (-not $operation.AllowedCleanup) {
            Assert (-not [string]::IsNullOrWhiteSpace([string]$operation.Reason)) 'Every blocked operation needs an explanatory reason.'
        }
    }
    return $result
}
function Assert-BlockedAssessment($Session) {
    $result = Get-Assessment $Session
    Assert (-not $result.CanAllowCleanup -and $result.BlockedCount -gt 0) 'Unsafe or malformed queue was treated as allowable cleanup.'
}

# The only substituted production dependencies are these two registry reads.
# Unknown paths fail instead of accidentally touching the host registry/files.
$script:fixtureSession = [pscustomobject]@{}
$script:fixturePendingKeys = @()
$script:fixtureRegistryError = $null
function Set-RegistryFixture($Session, [string[]]$PendingKeys = @(), [string]$RegistryError = '') {
    $script:fixtureSession = $Session
    $script:fixturePendingKeys = $PendingKeys
    $script:fixtureRegistryError = $RegistryError
}
function Test-Path {
    param([string]$LiteralPath)
    if ($LiteralPath -notin @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )) { throw "Unexpected registry existence query: $LiteralPath" }
    return ($LiteralPath -in $script:fixturePendingKeys)
}
function Get-ItemProperty {
    param([string]$LiteralPath, [string]$ErrorAction)
    if ($LiteralPath -ne 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager') {
        throw "Unexpected registry value query: $LiteralPath"
    }
    if ($script:fixtureRegistryError) { throw $script:fixtureRegistryError }
    return $script:fixtureSession
}

$savedWindows = $env:windir
$savedSystemRoot = $env:SystemRoot
$savedProgramFiles = $env:ProgramFiles
$savedProgramFilesX86 = ${env:ProgramFiles(x86)}
try {
    $env:windir = 'C:\Windows'
    $env:SystemRoot = 'C:\Windows'
    $env:ProgramFiles = 'C:\Program Files'
    ${env:ProgramFiles(x86)} = 'C:\Program Files (x86)'
    Check 'Explicit cleanup exception permits a recognized Edge deletion queue' {
        Set-RegistryFixture ([pscustomobject]@{
            PendingFileRenameOperations = [string[]]@('\??\C:\Program Files (x86)\Microsoft\Edge\Temp\123456_789\old_msedge.exe', '')
        })
        Assert-NoPendingMaintenance -AllowPendingCleanup
    }

    # Each positive fixture names the literal path/category required by the
    # approved exception. Expectations are independent of production matching.
    $allowedCases = @(
        @{ Name = 'Edge numeric directory'; Source = '\??\C:\Program Files\Microsoft\Edge\Temp\123456_789'; Category = 'EdgeCleanup' },
        @{ Name = 'Edge scoped directory'; Source = '\??\C:\Program Files (x86)\Microsoft\Edge\Temp\scoped_dir123_456'; Category = 'EdgeCleanup' },
        @{ Name = 'Edge old executable in numeric child'; Source = '\??\C:\Program Files (x86)\Microsoft\Edge\Temp\12_3\old_msedge.exe'; Category = 'EdgeCleanup' },
        @{ Name = 'Edge old executable in scoped child'; Source = '\??\C:\Program Files\Microsoft\Edge\Temp\scoped_dir12_3\old_msedge.exe'; Category = 'EdgeCleanup' },
        @{ Name = 'Recognized star-one prefix'; Source = '*1\??\C:\Program Files\Microsoft\Edge\Temp\123_456'; Category = 'EdgeCleanup' },
        @{ Name = 'Recognized star-two prefix'; Source = '*2\??\C:\Program Files\Microsoft\Edge\Temp\123_456\old_msedge.exe'; Category = 'EdgeCleanup' },
        @{ Name = 'Windows path comparison ignores case'; Source = '\??\c:\PROGRAM FILES\microsoft\EDGE\temp\SCOPED_DIR1_2\OLD_MSEDGE.EXE'; Category = 'EdgeCleanup' },
        @{ Name = 'Printer canonical unbraced GUID directory'; Source = '\??\C:\Windows\System32\spool\V4Dirs\11111111-2222-3333-4444-555555555555'; Category = 'PrintDriverCleanup' },
        @{ Name = 'Printer hexadecimal BUD leaf'; Source = '*1\??\C:\Windows\System32\spool\V4Dirs\11111111-2222-3333-4444-555555555555\A19f.BUD'; Category = 'PrintDriverCleanup' },
        @{ Name = 'Printer hexadecimal gpd leaf'; Source = '*2\??\C:\Windows\System32\spool\V4Dirs\11111111-2222-3333-4444-555555555555\012ab.gpd'; Category = 'PrintDriverCleanup' },
        @{ Name = 'Printer pdc metadata'; Source = '\??\C:\Windows\System32\spool\V4Dirs\11111111-2222-3333-4444-555555555555\pdc.xml'; Category = 'PrintDriverCleanup' },
        @{ Name = 'Installer rollback on C'; Source = '\??\C:\Config.Msi\0Ab123.rbf'; Category = 'InstallerRollbackCleanup' },
        @{ Name = 'Installer rollback on another drive'; Source = '*2\??\D:\Config.Msi\aB09.RBF'; Category = 'InstallerRollbackCleanup' },
        @{ Name = 'Exact Edge Temp root'; Source = '\??\C:\Program Files\Microsoft\Edge\Temp'; Category = 'EdgeCleanup' }
    )
    foreach ($case in $allowedCases) {
        Check ("Allowed deletion: " + $case.Name) {
            $result = Get-Assessment ([pscustomobject]@{ PendingFileRenameOperations = [string[]]@($case.Source, '') })
            Assert ($result.OperationCount -eq 1 -and $result.AllowedCleanupCount -eq 1 -and $result.BlockedCount -eq 0 -and $result.CanAllowCleanup) 'Recognized cleanup was blocked or miscounted.'
            Assert ($result.Operations[0].Category -eq $case.Category -and $result.Operations[0].AllowedCleanup) 'Cleanup was assigned the wrong category.'
            Assert ($result.Operations[0].Source -ceq $case.Source -and $result.Operations[0].Destination -ceq '') 'Original pair was not preserved.'
        }
    }

    Check 'Missing queue values produce no operations' {
        $result = Get-Assessment ([pscustomobject]@{ UnrelatedProperty = 'retained' })
        Assert ($result.OperationCount -eq 0 -and -not $result.CanAllowCleanup) 'Missing queues are not empty.'
    }
    Check 'Actual zero-length string arrays produce no operations' {
        $result = Get-Assessment ([pscustomobject]@{ PendingFileRenameOperations = [string[]]@(); PendingFileRenameOperations2 = [string[]]@() })
        Assert ($result.OperationCount -eq 0 -and -not $result.CanAllowCleanup) 'Empty string arrays are not empty queues.'
    }
    foreach ($emptyArrayCase in @(
        @{ Name = 'object'; Value = [object[]]@() },
        @{ Name = 'integer'; Value = [int[]]@() }
    )) {
        Check ("Zero-length " + $emptyArrayCase.Name + ' array also contains no operations') {
            $result = Get-Assessment ([pscustomobject]@{ PendingFileRenameOperations = $emptyArrayCase.Value })
            Assert ($result.OperationCount -eq 0 -and $result.BlockedCount -eq 0 -and -not $result.CanAllowCleanup) 'Empty one-dimensional array was treated as maintenance.'
        }
    }
    Check 'Both value names preserve pairing, identity and empty destinations' {
        $first = [string[]]@($allowedCases[0].Source, '', $allowedCases[8].Source, '')
        $second = [string[]]@($allowedCases[11].Source, '')
        $firstBefore = $first.Clone(); $secondBefore = $second.Clone()
        $session = [pscustomobject]@{ PendingFileRenameOperations = $first; PendingFileRenameOperations2 = $second }
        $result = Get-Assessment $session
        Assert ($result.OperationCount -eq 3 -and $result.AllowedCleanupCount -eq 3 -and $result.CanAllowCleanup) 'Both registry values were not fully assessed.'
        Assert ([object]::ReferenceEquals($first, $session.PendingFileRenameOperations) -and [object]::ReferenceEquals($second, $session.PendingFileRenameOperations2)) 'Assessment replaced a registry fixture array.'
        for ($i = 0; $i -lt $first.Length; $i++) { Assert ($first[$i] -ceq $firstBefore[$i]) 'First queue was modified.' }
        for ($i = 0; $i -lt $second.Length; $i++) { Assert ($second[$i] -ceq $secondBefore[$i]) 'Second queue was modified.' }
        $firstRecords = @($result.Operations | Where-Object { $_.ValueName -eq 'PendingFileRenameOperations' })
        $secondRecords = @($result.Operations | Where-Object { $_.ValueName -eq 'PendingFileRenameOperations2' })
        Assert ($firstRecords.Count -eq 2 -and $secondRecords.Count -eq 1) 'Source registry value identities were lost.'
        Assert ([int]$firstRecords[1].PairIndex -eq ([int]$firstRecords[0].PairIndex + 1)) 'Pair indexes are not consecutive within a value.'
        Assert ($firstRecords[0].Source -ceq $first[0] -and $firstRecords[1].Source -ceq $first[2] -and $secondRecords[0].Source -ceq $second[0]) 'Pairs were reordered or joined across registry values.'
    }
    Check 'Configured installation roots are honored literally' {
        $queue = [pscustomobject]@{ PendingFileRenameOperations = [string[]]@(
            '\??\E:\Apps (64)\Microsoft\Edge\Temp\1_2', '',
            '\??\E:\WinNT\System32\spool\V4Dirs\11111111-2222-3333-4444-555555555555\pdc.xml', ''
        ) }
        $result = Get-Assessment $queue -Windows 'E:\WinNT' -Programs @('E:\Apps (64)', 'E:\Apps (32)')
        Assert ($result.OperationCount -eq 2 -and $result.AllowedCleanupCount -eq 2 -and $result.CanAllowCleanup) 'Installation roots were hardcoded or treated as regex syntax.'
    }
    Check 'Default paths are not accepted when different roots are configured' {
        $result = Get-Assessment ([pscustomobject]@{ PendingFileRenameOperations = [string[]]@($allowedCases[0].Source, '') }) -Windows 'E:\WinNT' -Programs @('E:\Apps')
        Assert ($result.BlockedCount -eq 1 -and -not $result.CanAllowCleanup) 'An unconfigured Program Files root was accepted.'
    }

    $blockedPaths = @(
        @{ Name = 'Missing native prefix'; Source = 'C:\Config.Msi\123.rbf' },
        @{ Name = 'Win32 device prefix'; Source = '\\?\C:\Config.Msi\123.rbf' },
        @{ Name = 'Unknown star-zero flag'; Source = '*0\??\C:\Config.Msi\123.rbf' },
        @{ Name = 'Unknown star-three flag'; Source = '*3\??\C:\Config.Msi\123.rbf' },
        @{ Name = 'Multiple digit flag'; Source = '*12\??\C:\Config.Msi\123.rbf' },
        @{ Name = 'Duplicate flag'; Source = '*1*2\??\C:\Config.Msi\123.rbf' },
        @{ Name = 'Bare flagged path'; Source = '*1C:\Config.Msi\123.rbf' },
        @{ Name = 'Native UNC path'; Source = '\??\UNC\server\share\Config.Msi\123.rbf' },
        @{ Name = 'Traversal into installer directory'; Source = '\??\C:\Windows\..\Config.Msi\123.rbf' },
        @{ Name = 'Traversal out of cleanup child'; Source = '\??\C:\Program Files\Microsoft\Edge\Temp\1_2\..\old_msedge.exe' },
        @{ Name = 'Alternate data stream'; Source = '\??\C:\Config.Msi\123.rbf:stream' },
        @{ Name = 'Wildcard installer leaf'; Source = '\??\C:\Config.Msi\*.rbf' },
        @{ Name = 'Wildcard Edge leaf'; Source = '\??\C:\Program Files\Microsoft\Edge\Temp\1_2\old_*.exe' },
        @{ Name = 'Program Files prefix collision'; Source = '\??\C:\Program Files Backup\Microsoft\Edge\Temp\1_2' },
        @{ Name = 'Unrecognized Edge child'; Source = '\??\C:\Program Files\Microsoft\Edge\Temp\anything' },
        @{ Name = 'Edge child partial numeric name'; Source = '\??\C:\Program Files\Microsoft\Edge\Temp\1_2suffix' },
        @{ Name = 'Active Edge executable'; Source = '\??\C:\Program Files\Microsoft\Edge\Temp\1_2\msedge.exe' },
        @{ Name = 'Dangerous DLL inside recognized Edge child'; Source = '\??\C:\Program Files\Microsoft\Edge\Temp\1_2\kernel32.dll' },
        @{ Name = 'Nested Edge executable'; Source = '\??\C:\Program Files\Microsoft\Edge\Temp\1_2\nested\old_msedge.exe' },
        @{ Name = 'Unexpected slashes'; Source = '\??\C:/Config.Msi/123.rbf' },
        @{ Name = 'Duplicate separator'; Source = '\??\C:\Config.Msi\\123.rbf' },
        @{ Name = 'Trailing whitespace'; Source = '\??\C:\Config.Msi\123.rbf ' },
        @{ Name = 'Trailing dot'; Source = '\??\C:\Config.Msi\123.rbf.' },
        @{ Name = 'System DLL deletion'; Source = '\??\C:\Windows\System32\kernel32.dll' },
        @{ Name = 'Printer GUID braces are outside observed contract'; Source = '\??\C:\Windows\System32\spool\V4Dirs\{11111111-2222-3333-4444-555555555555}\pdc.xml' },
        @{ Name = 'Malformed printer GUID'; Source = '\??\C:\Windows\System32\spool\V4Dirs\11111111-2222-3333-4444-55555555555Z\pdc.xml' },
        @{ Name = 'Whole printer directory'; Source = '\??\C:\Windows\System32\spool\V4Dirs' },
        @{ Name = 'Printer DLL leaf'; Source = '\??\C:\Windows\System32\spool\V4Dirs\11111111-2222-3333-4444-555555555555\driver.dll' },
        @{ Name = 'Nonhex printer BUD leaf'; Source = '\??\C:\Windows\System32\spool\V4Dirs\11111111-2222-3333-4444-555555555555\printer.BUD' },
        @{ Name = 'Nested printer metadata'; Source = '\??\C:\Windows\System32\spool\V4Dirs\11111111-2222-3333-4444-555555555555\child\pdc.xml' },
        @{ Name = 'Printer Windows root collision'; Source = '\??\C:\Windows.old\System32\spool\V4Dirs\11111111-2222-3333-4444-555555555555\pdc.xml' },
        @{ Name = 'Installer leaf without hex identifier'; Source = '\??\C:\Config.Msi\.rbf' },
        @{ Name = 'Installer nonhex leaf'; Source = '\??\C:\Config.Msi\rollback.rbf' },
        @{ Name = 'Installer child directory'; Source = '\??\C:\Config.Msi\other\123.rbf' },
        @{ Name = 'Installer script extension'; Source = '\??\C:\Config.Msi\123.rbs' },
        @{ Name = 'Unknown directory'; Source = '\??\C:\Temp\123.rbf' },
        @{ Name = 'Embedded newline'; Source = ("\??\C:\Config.Msi\123.rbf`n") }
    )
    foreach ($case in $blockedPaths) {
        Check ("Blocked deletion: " + $case.Name) {
            Assert-BlockedAssessment ([pscustomobject]@{ PendingFileRenameOperations = [string[]]@($case.Source, '') })
        }
    }
    foreach ($destination in @(' ', '\??\C:\Config.Msi\456.rbf', '!\??\C:\Windows\System32\kernel32.dll', "`t")) {
        Check ("Any nonempty destination is blocked (length " + $destination.Length + ')') {
            Assert-BlockedAssessment ([pscustomobject]@{ PendingFileRenameOperations = [string[]]@($allowedCases[11].Source, $destination) })
        }
    }

    $malformedCases = @(
        @{ Name = 'Present null value'; Value = $null },
        @{ Name = 'Scalar source string'; Value = $allowedCases[0].Source },
        @{ Name = 'Scalar empty string'; Value = '' },
        @{ Name = 'Nonstring scalar value'; Value = 42 },
        @{ Name = 'Unpaired source'; Value = [string[]]@($allowedCases[0].Source) },
        @{ Name = 'Odd queue after a valid pair'; Value = [string[]]@($allowedCases[0].Source, '', $allowedCases[11].Source) },
        @{ Name = 'Empty source'; Value = [string[]]@('', '') },
        @{ Name = 'Whitespace source'; Value = [string[]]@('  ', '') },
        @{ Name = 'Null source element'; Value = [object[]]@($null, '') },
        @{ Name = 'Null destination element'; Value = [object[]]@($allowedCases[0].Source, $null) },
        @{ Name = 'Numeric source element'; Value = [object[]]@(42, '') },
        @{ Name = 'Numeric destination element'; Value = [object[]]@($allowedCases[0].Source, 0) }
    )
    foreach ($case in $malformedCases) {
        Check ("Malformed queue is blocked: " + $case.Name) {
            Assert-BlockedAssessment ([pscustomobject]@{ PendingFileRenameOperations = $case.Value })
        }
    }
    Check 'Pairs cannot be assembled across the two registry value arrays' {
        Assert-BlockedAssessment ([pscustomobject]@{
            PendingFileRenameOperations = [string[]]@($allowedCases[0].Source)
            PendingFileRenameOperations2 = [string[]]@('')
        })
    }
    Check 'One unsafe operation blocks an otherwise recognized queue' {
        $result = Get-Assessment ([pscustomobject]@{ PendingFileRenameOperations = [string[]]@(
            $allowedCases[0].Source, '', '\??\C:\Windows\System32\ntdll.dll', '', $allowedCases[11].Source, ''
        ) })
        Assert ($result.OperationCount -eq 3 -and $result.AllowedCleanupCount -eq 2 -and $result.BlockedCount -eq 1 -and -not $result.CanAllowCleanup) 'Mixed queue was accepted or incompletely counted.'
    }
    Check 'Unsafe second registry value blocks an allowed first value' {
        $result = Get-Assessment ([pscustomobject]@{
            PendingFileRenameOperations = [string[]]@($allowedCases[0].Source, '')
            PendingFileRenameOperations2 = [string[]]@('\??\C:\Windows\System32\ntdll.dll', '')
        })
        Assert ($result.OperationCount -eq 2 -and $result.AllowedCleanupCount -eq 1 -and $result.BlockedCount -eq 1 -and -not $result.CanAllowCleanup) 'Second value was ignored.'
    }

    Check 'Default gate still blocks even recognized cleanup' {
        Set-RegistryFixture ([pscustomobject]@{ PendingFileRenameOperations = [string[]]@($allowedCases[0].Source, '') })
        Assert-Throws { Assert-NoPendingMaintenance }
    }
    Check 'Default gate blocks actual operations in the second registry value' {
        Set-RegistryFixture ([pscustomobject]@{ PendingFileRenameOperations2 = [string[]]@($allowedCases[11].Source, '') })
        Assert-Throws { Assert-NoPendingMaintenance }
    }
    Check 'Cleanup gate accepts recognized deletions in both values' {
        Set-RegistryFixture ([pscustomobject]@{
            PendingFileRenameOperations = [string[]]@($allowedCases[0].Source, '')
            PendingFileRenameOperations2 = [string[]]@($allowedCases[11].Source, '')
        })
        Assert-NoPendingMaintenance -AllowPendingCleanup
    }
    Check 'Missing queues allow the default and explicit cleanup gate' {
        Set-RegistryFixture ([pscustomobject]@{})
        Assert-NoPendingMaintenance
        Assert-NoPendingMaintenance -AllowPendingCleanup
    }
    Check 'Zero-length string arrays allow the default and explicit cleanup gate' {
        Set-RegistryFixture ([pscustomobject]@{ PendingFileRenameOperations = [string[]]@(); PendingFileRenameOperations2 = [string[]]@() })
        Assert-NoPendingMaintenance
        Assert-NoPendingMaintenance -AllowPendingCleanup
    }
    Check 'Cleanup gate cannot override an unsafe mixed queue' {
        Set-RegistryFixture ([pscustomobject]@{
            PendingFileRenameOperations = [string[]]@($allowedCases[0].Source, '', '\??\C:\Windows\System32\kernel32.dll', '')
        })
        Assert-Throws { Assert-NoPendingMaintenance -AllowPendingCleanup }
    }
    Check 'Cleanup gate cannot reinterpret a null destination as deletion' {
        Set-RegistryFixture ([pscustomobject]@{ PendingFileRenameOperations = [object[]]@($allowedCases[0].Source, $null) })
        Assert-Throws { Assert-NoPendingMaintenance -AllowPendingCleanup }
    }
    Check 'Registry read failure remains fatal with the exception enabled' {
        Set-RegistryFixture ([pscustomobject]@{}) -RegistryError 'Synthetic registry read failure'
        Assert-Throws { Assert-NoPendingMaintenance -AllowPendingCleanup } 'Synthetic registry read failure'
    }
    foreach ($pendingKey in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )) {
        Check ("Servicing restart is refused before queue reads: " + ($pendingKey -split '\\')[-1]) {
            Set-RegistryFixture ([pscustomobject]@{}) -PendingKeys @($pendingKey) -RegistryError 'Queue read was reached before servicing refusal'
            Assert-Throws { Assert-NoPendingMaintenance -AllowPendingCleanup } 'servicing|restart|reboot|update'
        }
    }
    Check 'A fresh gate invocation detects a newly dangerous queue' {
        Set-RegistryFixture ([pscustomobject]@{ PendingFileRenameOperations = [string[]]@($allowedCases[0].Source, '') })
        Assert-NoPendingMaintenance -AllowPendingCleanup
        $script:fixtureSession = [pscustomobject]@{ PendingFileRenameOperations = [string[]]@('\??\C:\Windows\System32\ntdll.dll', '') }
        Assert-Throws { Assert-NoPendingMaintenance -AllowPendingCleanup }
    }

    # Exercise each real main-workflow gate call expression in isolation using
    # the actual top-level parameter block. This checks switch binding at both
    # consumers while executing no other workflow statement.
    $gateCalls = @($ast.FindAll({param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Assert-NoPendingMaintenance'
    }, $true))
    Check 'Both main-workflow maintenance gate consumers are present' {
        Assert ($gateCalls.Count -eq 2) 'Expected preflight and pre-mutation maintenance checks.'
    }
    for ($callIndex = 0; $callIndex -lt $gateCalls.Count; $callIndex++) {
        Check ("Main gate consumer " + ($callIndex + 1) + ' binds the explicit cleanup switch') {
            Set-RegistryFixture ([pscustomobject]@{ PendingFileRenameOperations = [string[]]@($allowedCases[0].Source, '') })
            $consumer = [scriptblock]::Create($ast.ParamBlock.Extent.Text + "`n" + $gateCalls[$callIndex].Extent.Text)
            & $consumer -AllowPendingCleanup
        }
        Check ("Main gate consumer " + ($callIndex + 1) + ' keeps strict default behavior') {
            Set-RegistryFixture ([pscustomobject]@{ PendingFileRenameOperations = [string[]]@($allowedCases[0].Source, '') })
            $consumer = [scriptblock]::Create($ast.ParamBlock.Extent.Text + "`n" + $gateCalls[$callIndex].Extent.Text)
            Assert-Throws { & $consumer }
        }
    }
} finally {
    $env:windir = $savedWindows
    $env:SystemRoot = $savedSystemRoot
    $env:ProgramFiles = $savedProgramFiles
    ${env:ProgramFiles(x86)} = $savedProgramFilesX86
}
Write-Host "RESULT: $passed passed; $failed failed."
Write-Host 'Scope: AST-extracted maintenance logic with synthetic registry reads; no main workflow, registry writes, or Windows servicing operations.'
if ($failed) { exit 1 }
