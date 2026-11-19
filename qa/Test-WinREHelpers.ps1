param(
    [string]$ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Move-WinRE-ExtendC.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Load ONLY the two pure functions. Never invoke the production script body.
if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    throw "FAIL: Requested production implementation does not exist: $ScriptPath"
}
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $ScriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) {
    throw ('PowerShell parse errors: ' + ($parseErrors | Out-String))
}
foreach ($name in @('Get-WinRELocation', 'Get-LayoutPlan')) {
    $matches = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $name
    }, $true))
    if ($matches.Count -ne 1) { throw "Expected exactly one production function $name" }
    . ([scriptblock]::Create($matches[0].Extent.Text))
}

$script:Passed = 0
$script:Failed = 0
function Test-Case([string]$Name, [scriptblock]$Action) {
    try {
        & $Action
        $script:Passed++
        Write-Host "PASS $Name"
    } catch {
        $script:Failed++
        Write-Host "FAIL $Name : $($_.Exception.Message)"
    }
}
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $didThrow = $false
    try { & $Action | Out-Null } catch { $didThrow = $true }
    Assert $didThrow $Message
}
function New-Part(
    [uint32]$Number, [uint64]$Offset, [uint64]$Size,
    [string]$GptType = '', [uint32]$MbrType = 0,
    [char]$DriveLetter = [char]0, [bool]$IsBoot = $false,
    [bool]$IsSystem = $false, [bool]$IsActive = $false
) {
    [pscustomobject]@{
        DiskNumber = [uint32]0; PartitionNumber = $Number
        Offset = $Offset; Size = $Size; GptType = $GptType; MbrType = $MbrType
        DriveLetter = $DriveLetter; IsBoot = $IsBoot; IsSystem = $IsSystem
        IsActive = $IsActive
    }
}
function New-Scenario([string]$Style = 'GPT') {
    $basic = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    $recovery = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
    if ($Style -eq 'GPT') {
        $parts = @(
            (New-Part -Number 1 -Offset 1MB -Size 100MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' -IsSystem $true),
            (New-Part -Number 2 -Offset 101MB -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'),
            (New-Part -Number 3 -Offset 117MB -Size 79GB -GptType $basic -DriveLetter C -IsBoot $true),
            (New-Part -Number 4 -Offset (117MB + 79GB) -Size 523MB -GptType $recovery)
        )
        $osIndex = 2
    } else {
        $parts = @(
            (New-Part -Number 1 -Offset 1MB -Size 100MB -MbrType 7 -IsSystem $true -IsActive $true),
            (New-Part -Number 2 -Offset 101MB -Size 79GB -MbrType 7 -DriveLetter C -IsBoot $true),
            (New-Part -Number 3 -Offset (101MB + 79GB) -Size 523MB -MbrType 39)
        )
        $osIndex = 1
    }
    [pscustomobject]@{
        Disk = [pscustomobject]@{Number = [uint32]0; Size = [uint64]100GB; PartitionStyle = $Style}
        OsPartition = $parts[$osIndex]
        Partitions = $parts
        WinRELocation = [pscustomobject]@{DiskNumber = 0; PartitionNumber = $parts[-1].PartitionNumber; RelativePath = '\Recovery\WindowsRE'}
        RecoverySize = [uint64]1GB
    }
}
function Get-Plan($Scenario) {
    Get-LayoutPlan -Disk $Scenario.Disk -OsPartition $Scenario.OsPartition `
        -Partitions $Scenario.Partitions -WinRELocation $Scenario.WinRELocation `
        -RecoverySize $Scenario.RecoverySize -Placement EndOfDisk
}

Test-Case 'English WinRE location identifies disk and partition' {
    $location = Get-WinRELocation -Text "Windows RE status: Enabled`r`nWindows RE location: \\?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE`r`nBCD identifier: 1111"
    Assert ($location.DiskNumber -eq 0) 'Disk number not parsed'
    Assert ($location.PartitionNumber -eq 4) 'Partition number not parsed'
    Assert ($location.RelativePath -eq '\Recovery\WindowsRE') 'Relative path changed'
}
Test-Case 'German WinRE output parses without English labels' {
    $location = Get-WinRELocation -Text "Windows RE-Status: Enabled`r`nWindows RE-Ort:    \\?\GLOBALROOT\device\harddisk12\partition18\Recovery\WindowsRE`r`n"
    Assert ($location.DiskNumber -eq 12 -and $location.PartitionNumber -eq 18) 'Localized labels broke parsing'
}
Test-Case 'Disabled WinRE without location returns null' {
    Assert ($null -eq (Get-WinRELocation -Text "Windows RE status: Disabled`nWindows RE location:`n")) 'Missing location must return null'
}
Test-Case 'Factory image location is not mistaken for WinRE' {
    $info = "Windows RE location: \\?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE`nRecovery image location: \\?\GLOBALROOT\device\harddisk1\partition2\Factory\Image"
    $location = Get-WinRELocation -Text $info
    Assert ($location.DiskNumber -eq 0 -and $location.PartitionNumber -eq 4) 'Factory image path selected'
}
Test-Case 'Ambiguous multiple WinRE locations rejected' {
    $info = "Windows RE location: \\?\GLOBALROOT\device\harddisk0\partition4\Recovery\WindowsRE`nOther location: \\?\GLOBALROOT\device\harddisk1\partition2\Recovery\WindowsRE"
    Assert-Throws { Get-WinRELocation -Text $info } 'Ambiguous WinRE locations accepted'
}
Test-Case 'Lowercase path components and trailing whitespace parsed' {
    $location = Get-WinRELocation -Text " Location: \\?\globalroot\device\harddisk2\partition5\recovery\windowsre  `r`n"
    Assert ($location.DiskNumber -eq 2 -and $location.PartitionNumber -eq 5) 'Case/whitespace broke parsing'
}

foreach ($style in @('GPT', 'MBR')) {
    Test-Case "$style valid 100 GiB disk has aligned end recovery and growth" {
        $s = New-Scenario $style
        $plan = Get-Plan $s
        Assert ($plan.RecoveryPartition.PartitionNumber -eq $s.Partitions[-1].PartitionNumber) 'Wrong recovery selected'
        Assert ($plan.RecoveryOffset -eq (99GB - 1MB)) 'Recovery offset must leave the chosen 1 MiB disk tail'
        Assert ($plan.ExpectedCSize -eq ($plan.RecoveryOffset - $s.OsPartition.Offset)) 'C: endpoint differs from recovery start'
        Assert ($plan.ExpectedCSize -gt $s.OsPartition.Size) 'C: does not grow'
        Assert ($plan.RecoverySize -eq 1GB) 'Requested recovery size changed'
        Assert ($plan.TailBytes -eq ($s.Disk.Size - ($s.Partitions[-1].Offset + $s.Partitions[-1].Size))) 'Trailing space calculated incorrectly'
        Assert (($plan.RecoveryOffset % 1MB) -eq 0) 'Recovery offset is not MiB aligned'
    }
    Test-Case "$style unallocated gap before recovery accepted" {
        $s = New-Scenario $style
        $s.Partitions[-1].Offset += 2MB
        $plan = Get-Plan $s
        Assert ($plan.ExpectedCSize -gt $s.OsPartition.Size) 'Recoverable gap rejected'
    }
    Test-Case "$style large gap before C does not affect end allocation" {
        $s = New-Scenario $style
        $s.OsPartition.Offset += 1GB
        $s.Partitions[-1].Offset += 1GB
        $plan = Get-Plan $s
        Assert ($plan.RecoveryOffset -eq (99GB - 1MB)) 'Pre-C hole changed end allocation'
    }
    Test-Case "$style fractional disk capacity rounds recovery offset down" {
        $s = New-Scenario $style
        $s.Disk.Size += 512KB
        $plan = Get-Plan $s
        Assert ($plan.RecoveryOffset -eq (99GB - 1MB)) 'Fractional MiB rounded up'
    }
    Test-Case "$style larger recovery image reservation preserves capacity arithmetic" {
        $s = New-Scenario $style
        $s.RecoverySize = 1536MB
        $plan = Get-Plan $s
        Assert ($plan.RecoveryOffset -eq (100GB - 1MB - 1536MB)) 'Larger reservation offset wrong'
        Assert ($plan.RecoverySize -eq 1536MB) 'Larger reservation lost'
    }
}
Test-Case 'Missing active WinRE location rejected before choosing a deletion source' {
    $s = New-Scenario
    $s.WinRELocation = $null
    Assert-Throws { Get-Plan $s } 'Unregistered recovery partition accepted as a deletion source'
}
Test-Case 'RAW partition style rejected' {
    $s = New-Scenario
    $s.Disk.PartitionStyle = 'RAW'
    Assert-Throws { Get-Plan $s } 'RAW disk accepted'
}
Test-Case 'Different registered WinRE disk rejected' {
    $s = New-Scenario
    $s.WinRELocation.DiskNumber = 1
    Assert-Throws { Get-Plan $s } 'WinRE disk mismatch accepted'
}
Test-Case 'Different registered WinRE partition rejected' {
    $s = New-Scenario
    $s.WinRELocation.PartitionNumber = 1
    Assert-Throws { Get-Plan $s } 'WinRE partition mismatch accepted'
}
Test-Case 'Missing recovery partition rejected' {
    $s = New-Scenario
    $s.Partitions = @($s.Partitions[0..2])
    Assert-Throws { Get-Plan $s } 'Missing recovery accepted'
}
Test-Case 'Data partition following recovery rejected' {
    $s = New-Scenario
    $s.Partitions += New-Part -Number 5 -Offset 90GB -Size 2GB -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' -DriveLetter D
    Assert-Throws { Get-Plan $s } 'Later data partition accepted'
}
Test-Case 'Data partition between C and recovery rejected' {
    $s = New-Scenario
    $s.Partitions[-1].Offset = 90GB
    $s.Partitions += New-Part -Number 5 -Offset 85GB -Size 2GB -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' -DriveLetter D
    Assert-Throws { Get-Plan $s } 'Intervening data partition accepted'
}
Test-Case 'Earlier recovery partition preserved while the registered source is selected' {
    $s = New-Scenario
    $s.Partitions[1].GptType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
    $before = $s.Partitions | ConvertTo-Json -Depth 5 -Compress
    $plan = Get-Plan $s
    Assert ($plan.RecoveryPartition.PartitionNumber -eq 4) 'Earlier recovery was selected for deletion'
    Assert (($s.Partitions | ConvertTo-Json -Depth 5 -Compress) -ceq $before) 'Planning mutated an existing partition'
}
Test-Case 'GPT target without recovery GUID rejected' {
    $s = New-Scenario
    $s.Partitions[-1].GptType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    Assert-Throws { Get-Plan $s } 'Basic-data target accepted as recovery'
}
Test-Case 'MBR target without recovery type rejected' {
    $s = New-Scenario MBR
    $s.Partitions[-1].MbrType = 7
    Assert-Throws { Get-Plan $s } 'MBR data target accepted as recovery'
}
foreach ($flag in @('IsBoot', 'IsSystem', 'IsActive')) {
    Test-Case "Recovery target with $flag true rejected" {
        $s = New-Scenario
        $s.Partitions[-1].$flag = $true
        Assert-Throws { Get-Plan $s } "Protected target $flag accepted"
    }
}
Test-Case 'Recovery partition with assigned drive letter rejected' {
    $s = New-Scenario
    $s.Partitions[-1].DriveLetter = 'R'
    Assert-Throws { Get-Plan $s } 'Visible target accepted'
}
foreach ($extendedType in @(5, 15, 133)) {
    Test-Case "MBR extended partition type $extendedType rejected" {
        $s = New-Scenario MBR
        $s.Partitions[0].MbrType = $extendedType
        Assert-Throws { Get-Plan $s } 'Extended MBR layout accepted'
    }
}
Test-Case 'MBR more than four partition entries rejected' {
    $s = New-Scenario MBR
    $s.OsPartition.Offset = 1GB
    $s.Partitions[-1].Offset = 80GB
    $s.Partitions += New-Part -Number 4 -Offset 200MB -Size 10MB -MbrType 7
    $s.Partitions += New-Part -Number 5 -Offset 300MB -Size 10MB -MbrType 7
    Assert-Throws { Get-Plan $s } 'Too many MBR partitions accepted'
}
Test-Case 'GPT C partition with non-basic-data type rejected' {
    $s = New-Scenario
    $s.OsPartition.GptType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    Assert-Throws { Get-Plan $s } 'Wrong C GPT type accepted'
}
Test-Case 'MBR C partition with non-NTFS type rejected' {
    $s = New-Scenario MBR
    $s.OsPartition.MbrType = 12
    Assert-Throws { Get-Plan $s } 'Wrong C MBR type accepted'
}
Test-Case 'Overlapping recovery and C rejected' {
    $s = New-Scenario
    $s.Partitions[-1].Offset -= 1MB
    Assert-Throws { Get-Plan $s } 'Overlapping partitions accepted'
}
Test-Case 'Overlapping earlier partitions rejected' {
    $s = New-Scenario
    $s.Partitions[1].Offset = 50MB
    Assert-Throws { Get-Plan $s } 'Overlapping boot area accepted'
}
Test-Case 'Recovery beyond disk size rejected' {
    $s = New-Scenario
    $s.Partitions[-1].Offset = 100GB
    Assert-Throws { Get-Plan $s } 'Out-of-bounds recovery accepted'
}
Test-Case 'Mismatched OS disk rejected' {
    $s = New-Scenario
    $s.OsPartition.DiskNumber = 1
    Assert-Throws { Get-Plan $s } 'Wrong OS disk accepted'
}
Test-Case 'OS metadata inconsistent with listed partition rejected' {
    $s = New-Scenario
    $s.OsPartition = $s.OsPartition | Select-Object *
    $s.OsPartition.Size += 1MB
    Assert-Throws { Get-Plan $s } 'Inconsistent C metadata accepted'
}
Test-Case 'Recovery reservation that would shrink C rejected' {
    $s = New-Scenario
    $s.RecoverySize = 30GB
    Assert-Throws { Get-Plan $s } 'Implicit C shrink accepted'
}
Test-Case 'No useful growth rejected' {
    $s = New-Scenario
    $s.Disk.Size = $s.OsPartition.Offset + $s.OsPartition.Size + 1GB + 1MB
    Assert-Throws { Get-Plan $s } 'Zero-growth destructive work accepted'
}
Test-Case 'Sub-MiB growth rejected' {
    $s = New-Scenario
    $s.OsPartition.Size += 512KB
    $s.Partitions[-1].Offset += 512KB
    $s.Disk.Size = $s.OsPartition.Offset + $s.OsPartition.Size + 1GB + 2MB
    Assert-Throws { Get-Plan $s } 'Sub-MiB growth accepted'
}

Write-Host "RESULT: $script:Passed passed; $script:Failed failed."
Write-Host 'Scope: pure production helper functions and PowerShell syntax only; no Windows storage, REAgentC, DISM, or BitLocker operations executed.'
if ($script:Failed -ne 0) { exit 1 }
