param([string]$ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Move-WinRE-ExtendC.ps1'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$definitions = @($ast.FindAll({param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-LayoutPlan'
}, $true))
if ($definitions.Count -ne 1) { throw 'Expected one Get-LayoutPlan production function' }
. ([scriptblock]::Create($definitions[0].Extent.Text))
$passed = 0; $failed = 0
function Check([string]$Name, [scriptblock]$Action) {
    try { & $Action; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Expected = '') {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    Assert ($null -ne $caught) 'Unsafe/unsupported layout was accepted'
    if ($Expected) {
        Assert (([string]$caught + ' ' + [string]$caught.FullyQualifiedErrorId) -match [regex]::Escape($Expected)) "Expected error classification $Expected; received $caught"
    }
}
function Part([int]$Number, [long]$Offset, [long]$Size, [string]$GptType = '', [int]$MbrType = 0, [string]$Letter = '') {
    [pscustomobject]@{
        DiskNumber = 0; PartitionNumber = $Number; Offset = $Offset; Size = $Size
        GptType = $GptType; MbrType = $MbrType; DriveLetter = $Letter
        IsBoot = ($Letter -eq 'C'); IsSystem = $false; IsActive = $false
    }
}
function Scenario([string]$Style = 'GPT', [long]$FrontGap = 0) {
    if ($Style -eq 'GPT') {
        $parts = @(
            (Part 1 1MB 100MB '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'),
            (Part 2 101MB 16MB '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'),
            (Part 3 (117MB + $FrontGap) 79GB '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' 0 C),
            (Part 4 (117MB + $FrontGap + 79GB) 523MB '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}')
        )
        $os = $parts[2]
    } else {
        $parts = @(
            (Part 1 1MB 100MB '' 7),
            (Part 2 (101MB + $FrontGap) 79GB '' 7 C),
            (Part 3 (101MB + $FrontGap + 79GB) 523MB '' 39)
        )
        $parts[0].IsActive = $true
        $os = $parts[1]
    }
    $parts[0].IsSystem = $true
    [pscustomobject]@{
        Disk = [pscustomobject]@{ Number = 0; PartitionStyle = $Style; Size = [long]100GB }
        Os = $os; Partitions = $parts; RecoverySize = [long]1GB
        Location = [pscustomobject]@{ DiskNumber = 0; PartitionNumber = $parts[-1].PartitionNumber; RelativePath = '\Recovery\WindowsRE' }
    }
}
function Plan($Scenario, [string]$Placement = 'Auto', [switch]$UseDefault) {
    $callParameters = @{
        Disk = $Scenario.Disk; OsPartition = $Scenario.Os; Partitions = $Scenario.Partitions
        WinRELocation = $Scenario.Location; RecoverySize = $Scenario.RecoverySize
    }
    if (-not $UseDefault) { $callParameters.Placement = $Placement }
    Get-LayoutPlan @callParameters
}
function Assert-PlanMetadata($Scenario, $Result, [string]$Placement) {
    Assert ($Result.SelectedPlacement -eq $Placement) 'Wrong placement selected'
    Assert ($Result.Action -eq 'RelocateAndExtend') 'Unexpected action'
    Assert (-not [string]::IsNullOrWhiteSpace([string]$Result.PlacementReason)) 'Missing placement explanation'
    Assert ($Result.ExpectedCSize -eq ($Result.CGrowthLimit - $Scenario.Os.Offset)) 'C growth bound does not match its planned size'
    Assert ($Result.GainBytes -eq ($Result.ExpectedCSize - $Scenario.Os.Size) -and $Result.GainBytes -ge 1MB) 'Gain is inconsistent or too small'
    Assert ($Result.RecoverySize -eq $Scenario.RecoverySize) 'Requested recovery size changed'
    Assert (($Result.RecoveryOffset % 1MB) -eq 0 -and $Result.RecoveryOffset -ge 1MB) 'Recovery placement violates MiB alignment or reserved initial area'
    Assert ($Result.RecoveryPartition.PartitionNumber -eq $Scenario.Partitions[-1].PartitionNumber) 'Wrong source selected'
}

foreach ($style in @('GPT', 'MBR')) {
    Check "$style omitted Placement automatically uses an exact-sized front gap" {
        $s = Scenario $style 1GB
        $plan = Plan $s -UseDefault
        # This semantic assertion fails against the former end-only implementation.
        Assert (($plan.RecoveryOffset + $plan.RecoverySize) -le $s.Os.Offset) 'Default Auto did not use the existing front gap'
        Assert-PlanMetadata $s $plan BeforeC
        Assert ($plan.CGrowthLimit -eq (100GB - 1MB)) 'BeforeC failed to release trailing space for C'
    }
    Check "$style explicit BeforeC uses only the front gap without moving existing partitions" {
        $s = Scenario $style 1GB
        $before = $s.Partitions | ConvertTo-Json -Depth 5 -Compress
        $plan = Plan $s BeforeC
        Assert-PlanMetadata $s $plan BeforeC
        Assert ($plan.RecoveryOffset -eq ($s.Os.Offset - 1GB)) 'Exact-sized front gap was not selected'
        Assert (($s.Partitions | ConvertTo-Json -Depth 5 -Compress) -ceq $before) 'Planner mutated system/OS/source partitions'
    }
    Check "$style explicit EndOfDisk overrides a usable front gap" {
        $s = Scenario $style 1GB
        $plan = Plan $s EndOfDisk
        Assert-PlanMetadata $s $plan EndOfDisk
        Assert ($plan.RecoveryOffset -eq (99GB - 1MB)) 'End placement used the front gap'
        Assert ($plan.CGrowthLimit -eq $plan.RecoveryOffset) 'End placement lets C overlap recovery'
    }
    Check "$style Auto falls back to end when the front gap is too small" {
        $s = Scenario $style 512MB
        $plan = Plan $s Auto
        Assert-PlanMetadata $s $plan EndOfDisk
        Assert ($plan.RecoveryOffset -eq (99GB - 1MB)) 'Fallback offset is incorrect'
    }
    Check "$style strict BeforeC reports offline relocation when no front gap fits" {
        $s = Scenario $style 512MB
        Assert-Throws { Plan $s BeforeC } 'RequiresOfflineRelocation'
    }
    Check "$style BeforeC reclaims the old recovery when trailing free space is zero" {
        $s = Scenario $style 1GB
        $s.Disk.Size = $s.Partitions[-1].Offset + $s.Partitions[-1].Size
        $plan = Plan $s BeforeC
        Assert-PlanMetadata $s $plan BeforeC
        Assert ($plan.TailBytes -eq 0) 'Reported nonexistent trailing free space'
        Assert ($plan.GainBytes -eq 522MB) 'Old recovery capacity was not reclaimed conservatively'
    }
    Check "$style Auto uses the front gap when zero tail would prevent end placement" {
        $s = Scenario $style 1GB
        $s.Disk.Size = $s.Partitions[-1].Offset + $s.Partitions[-1].Size
        Assert-PlanMetadata $s (Plan $s Auto) BeforeC
    }
    Check "$style forced EndOfDisk rejects zero-tail layout that would shrink C" {
        $s = Scenario $style 1GB
        $s.Disk.Size = $s.Partitions[-1].Offset + $s.Partitions[-1].Size
        Assert-Throws { Plan $s EndOfDisk }
    }
}

Check 'Exact user MBR geometry defaults to end with exact size/gain limits' {
    $s = Scenario MBR
    $s.Os.Size = [long]85242937344
    $s.Partitions[-1].Offset = [long]85348843520
    $s.Partitions[-1].Size = [long]548405248
    $plan = Plan $s -UseDefault
    Assert-PlanMetadata $s $plan EndOfDisk
    Assert ($plan.ExpectedCSize -eq 106193485824) 'Reported MBR C size differs'
    Assert ($plan.RecoveryOffset -eq 106299392000 -and $plan.CGrowthLimit -eq 106299392000) 'Reported MBR boundary differs'
    Assert ($plan.TailBytes -eq 21476933632 -and $plan.GainBytes -eq 20950548480) 'Reported MBR tail/gain differs'
}
Check 'Exact user MBR strict BeforeC identifies need for offline relocation' {
    $s = Scenario MBR
    $s.Os.Size = [long]85242937344
    $s.Partitions[-1].Offset = [long]85348843520
    $s.Partitions[-1].Size = [long]548405248
    Assert-Throws { Plan $s BeforeC } 'RequiresOfflineRelocation'
}
Check 'Unaligned front gap chooses an aligned fitting location' {
    $s = Scenario GPT (1GB + 2MB + 256KB)
    $s.Partitions[1].Size += 512KB
    $plan = Plan $s BeforeC
    Assert-PlanMetadata $s $plan BeforeC
    Assert ($plan.RecoveryOffset -ge 118MB) 'Placement begins before the aligned free gap'
    Assert (($plan.RecoveryOffset + $plan.RecoverySize) -le $s.Os.Offset) 'Aligned recovery overlaps C'
}
Check 'Raw gap size is insufficient when alignment consumes the margin' {
    $s = Scenario GPT (1GB + 512KB)
    $s.Partitions[1].Size += 512KB
    Assert-Throws { Plan $s BeforeC } 'RequiresOfflineRelocation'
    Assert-PlanMetadata $s (Plan $s Auto) EndOfDisk
}
Check 'Nearest fitting front gap is preferred over a farther larger gap' {
    $s = Scenario GPT (5GB - 117MB)
    $marker = Part 8 2GB 100MB '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    $s.Partitions = @($s.Partitions[0], $s.Partitions[1], $marker, $s.Os, $s.Partitions[-1])
    $plan = Plan $s BeforeC
    Assert-PlanMetadata $s $plan BeforeC
    Assert ($plan.RecoveryOffset -ge (2GB + 100MB)) 'Farther gap selected despite suitable nearest gap'
    Assert (($plan.RecoveryOffset + 1GB) -le 5GB) 'Recovery extends past the nearest gap'
}
Check 'Farther fitting gap used when the nearest gap is undersized' {
    $s = Scenario GPT (5GB - 117MB)
    $marker = Part 8 2GB (2GB + 512MB) '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    $s.Partitions = @($s.Partitions[0], $s.Partitions[1], $marker, $s.Os, $s.Partitions[-1])
    $plan = Plan $s BeforeC
    Assert-PlanMetadata $s $plan BeforeC
    Assert ($plan.RecoveryOffset -ge 117MB -and ($plan.RecoveryOffset + 1GB) -le 2GB) 'Farther fitting gap not used'
}
Check 'Initial front gap reserves first MiB and preserves the system partitions' {
    $s = Scenario GPT 1GB
    $s.Partitions[0].Offset += 1GB
    $s.Partitions[1].Offset += 1GB
    $plan = Plan $s BeforeC
    Assert-PlanMetadata $s $plan BeforeC
    Assert ($plan.RecoveryOffset -eq 1MB) 'Initial reserved MiB used or exact-sized initial gap missed'
}
Check 'Initial raw 1-GiB hole cannot consume reserved first MiB' {
    $s = Scenario GPT (1GB - 1MB)
    $s.Partitions[0].Offset += (1GB - 1MB)
    $s.Partitions[1].Offset += (1GB - 1MB)
    Assert-Throws { Plan $s BeforeC } 'RequiresOfflineRelocation'
}
Check 'Multiple dormant GPT recovery partitions before C are preserved' {
    $s = Scenario GPT (3GB - 117MB)
    $r1 = Part 8 512MB 128MB '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
    $r2 = Part 9 768MB 128MB '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
    $s.Partitions = @($s.Partitions[0], $s.Partitions[1], $r1, $r2, $s.Os, $s.Partitions[-1])
    $before = $s.Partitions | ConvertTo-Json -Depth 5 -Compress
    $plan = Plan $s Auto
    Assert-PlanMetadata $s $plan BeforeC
    Assert ($plan.RecoveryOffset -ge 896MB) 'Existing dormant recovery would be overwritten'
    Assert (($s.Partitions | ConvertTo-Json -Depth 5 -Compress) -ceq $before) 'Dormant recovery partitions changed during planning'
}
Check 'Four occupied MBR entries rejected because create-first needs a free slot' {
    $s = Scenario MBR 2GB
    $old = Part 4 512MB 128MB '' 39
    $s.Partitions = @($s.Partitions[0], $old, $s.Os, $s.Partitions[-1])
    foreach ($placement in @('Auto', 'BeforeC', 'EndOfDisk')) {
        Assert-Throws { Plan $s $placement }
    }
}
Check 'Disabled WinRE rejected even with only one suitable blocker after C' {
    $s = Scenario GPT (3GB - 117MB)
    $old = Part 8 512MB 128MB '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
    $s.Partitions = @($s.Partitions[0], $s.Partitions[1], $old, $s.Os, $s.Partitions[-1])
    $s.Location = $null
    Assert-Throws { Plan $s Auto }
}
Check 'Registered earlier recovery is not substituted by the blocker after C' {
    $s = Scenario GPT 2GB
    $old = Part 8 512MB 128MB '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
    $s.Partitions = @($s.Partitions[0], $s.Partitions[1], $old, $s.Os, $s.Partitions[-1])
    $s.Location.PartitionNumber = 8
    Assert-Throws { Plan $s Auto }
}
Check 'Registered source on another disk rejected' {
    $s = Scenario GPT 1GB; $s.Location.DiskNumber = 9
    Assert-Throws { Plan $s Auto }
}
Check 'Overlap between a front-gap boundary and C rejected' {
    $s = Scenario GPT 1GB; $s.Partitions[1].Size = 2GB
    Assert-Throws { Plan $s BeforeC }
}
Check 'Negative partition size and reversed bounds rejected' {
    $s = Scenario GPT 1GB; $s.Partitions[1].Size = -1
    Assert-Throws { Plan $s BeforeC }
}
Check 'Negative starting offset rejected' {
    $s = Scenario GPT 1GB; $s.Partitions[0].Offset = -1
    Assert-Throws { Plan $s BeforeC }
}
Check 'Duplicate partition number rejected before selecting a gap' {
    $s = Scenario GPT 1GB; $s.Partitions[1].PartitionNumber = 1
    Assert-Throws { Plan $s BeforeC }
}
Check 'OS identity mismatch rejected before selecting a gap' {
    $s = Scenario GPT 1GB
    $s.Os = $s.Os | Select-Object *
    $s.Os.Offset += 1MB
    Assert-Throws { Plan $s BeforeC }
}
foreach ($kind in @(5, 15, 133, 66)) {
    Check "MBR extended/dynamic partition type $kind rejected for front placement" {
        $s = Scenario MBR 1GB; $s.Partitions[0].MbrType = $kind
        Assert-Throws { Plan $s BeforeC }
    }
}
Check 'MBR disk above 2 TiB rejected despite a usable front gap' {
    $s = Scenario MBR 1GB; $s.Disk.Size = 2TB + 1MB
    Assert-Throws { Plan $s BeforeC }
}
foreach ($flag in @('IsBoot', 'IsSystem', 'IsActive')) {
    Check "Source recovery marked $flag rejected" {
        $s = Scenario GPT 1GB; $s.Partitions[-1].$flag = $true
        Assert-Throws { Plan $s Auto }
    }
}
Check 'Visible source recovery rejected for all placement modes' {
    foreach ($placement in @('Auto', 'BeforeC', 'EndOfDisk')) {
        $s = Scenario GPT 1GB; $s.Partitions[-1].DriveLetter = 'R'
        Assert-Throws { Plan $s $placement }
    }
}
Check 'Unsupported placement value rejected' {
    $s = Scenario GPT 1GB
    Assert-Throws { Plan $s 'SomewhereElse' }
}
foreach ($style in @('GPT', 'MBR')) {
    Check "$style end destination overlapping old recovery rejected despite positive potential gain" {
        $s = Scenario $style
        $s.Disk.Size = $s.Partitions[-1].Offset + $s.Partitions[-1].Size + 900MB
        Assert-Throws { Plan $s EndOfDisk }
    }
    Check "$style Auto rejects overlapping end destination when there is no front gap" {
        $s = Scenario $style
        $s.Disk.Size = $s.Partitions[-1].Offset + $s.Partitions[-1].Size + 900MB
        Assert-Throws { Plan $s Auto }
    }
    Check "$style exact end gap fits create-first without touching old recovery" {
        $s = Scenario $style
        $oldEnd = $s.Partitions[-1].Offset + $s.Partitions[-1].Size
        $s.Disk.Size = $oldEnd + 1GB + 1MB
        $plan = Plan $s EndOfDisk
        Assert-PlanMetadata $s $plan EndOfDisk
        Assert ($plan.RecoveryOffset -eq $oldEnd) 'Exact create-first boundary calculated incorrectly'
        Assert ($plan.GainBytes -eq 523MB) 'Exact boundary did not reclaim just the old recovery'
    }
}

function Existing-Scenario([string]$Style, [string]$Placement) {
    $gap = 0
    if ($Placement -eq 'BeforeC') { $gap = 1GB }
    $s = Scenario $Style $gap
    $s.Partitions[-1].Size = 1GB
    if ($Placement -eq 'BeforeC') { $s.Partitions[-1].Offset = $s.Os.Offset - 1GB }
    else { $s.Partitions[-1].Offset = 99GB - 1MB }
    return $s
}
function Assert-Preserved($Scenario, $Result, [string]$Placement, [string]$Action) {
    Assert ($Result.SelectedPlacement -eq $Placement -and $Result.Action -eq $Action) 'Already-placed recovery selected wrong operation'
    Assert ($Result.RecoveryOffset -eq $Scenario.Partitions[-1].Offset -and $Result.RecoverySize -eq $Scenario.Partitions[-1].Size) 'Existing recovery would be relocated or resized'
    Assert ($Result.RecoveryPartition.PartitionNumber -eq $Scenario.Location.PartitionNumber) 'Existing recovery identity changed'
    Assert (($Scenario.Os.Offset + $Result.ExpectedCSize) -le $Result.CGrowthLimit) 'Preserved-plan target crosses its safe growth limit'
    Assert ($Result.GainBytes -eq ($Result.ExpectedCSize - $Scenario.Os.Size)) 'Preserved-plan gain is inconsistent'
    Assert (-not [string]::IsNullOrWhiteSpace([string]$Result.PlacementReason)) 'Preserved plan lacks reason'
    if ($Action -eq 'NoChange') {
        Assert ($Result.GainBytes -eq 0 -and $Result.ExpectedCSize -eq $Scenario.Os.Size) 'NoChange misleadingly reports a larger C size or positive gain'
    } else {
        Assert ($Result.GainBytes -ge 1MB) 'ExtendOnly provides no meaningful growth'
        Assert ($Result.ExpectedCSize -eq ($Result.CGrowthLimit - $Scenario.Os.Offset)) 'ExtendOnly does not use its planned growth limit'
    }
}
foreach ($style in @('GPT', 'MBR')) {
    Check "$style existing front recovery yields ExtendOnly in Auto and BeforeC" {
        $s = Existing-Scenario $style BeforeC
        $before = $s.Partitions | ConvertTo-Json -Depth 5 -Compress
        foreach ($placement in @('Auto', 'BeforeC')) {
            $plan = Plan $s $placement
            Assert-Preserved $s $plan BeforeC ExtendOnly
            Assert ($plan.CGrowthLimit -eq (100GB - 1MB)) 'Existing front recovery unnecessarily limits C growth'
        }
        Assert (($s.Partitions | ConvertTo-Json -Depth 5 -Compress) -ceq $before) 'Preserve branch mutated partition inputs'
    }
    Check "$style existing front recovery yields NoChange after C has filled usable space" {
        $s = Existing-Scenario $style BeforeC
        $s.Os.Size = 100GB - 1MB - $s.Os.Offset
        foreach ($placement in @('Auto', 'BeforeC')) { Assert-Preserved $s (Plan $s $placement) BeforeC NoChange }
    }
    Check "$style strict EndOfDisk rejects moving existing front recovery" {
        $s = Existing-Scenario $style BeforeC
        Assert-Throws { Plan $s EndOfDisk }
    }
    Check "$style existing end recovery yields ExtendOnly without reallocating it" {
        $s = Existing-Scenario $style EndOfDisk
        foreach ($placement in @('Auto', 'EndOfDisk')) {
            $plan = Plan $s $placement
            Assert-Preserved $s $plan EndOfDisk ExtendOnly
            Assert ($plan.CGrowthLimit -eq $s.Partitions[-1].Offset) 'ExtendOnly crosses preserved end recovery'
        }
    }
    Check "$style existing end recovery yields NoChange when C already reaches it" {
        $s = Existing-Scenario $style EndOfDisk
        $s.Os.Size = $s.Partitions[-1].Offset - $s.Os.Offset
        foreach ($placement in @('Auto', 'EndOfDisk')) { Assert-Preserved $s (Plan $s $placement) EndOfDisk NoChange }
    }
    Check "$style strict BeforeC rejects an existing end recovery when no front gap fits" {
        $s = Existing-Scenario $style EndOfDisk
        Assert-Throws { Plan $s BeforeC } 'RequiresOfflineRelocation'
    }
}
Check 'Sub-MiB unallocated tail reports honest NoChange for existing front recovery' {
    $s = Existing-Scenario GPT BeforeC
    $s.Os.Size = 100GB - 1MB - $s.Os.Offset - 512KB
    Assert-Preserved $s (Plan $s Auto) BeforeC NoChange
}
Check 'Sub-MiB internal gap reports honest NoChange for existing end recovery' {
    $s = Existing-Scenario GPT EndOfDisk
    $s.Os.Size = $s.Partitions[-1].Offset - $s.Os.Offset - 512KB
    Assert-Preserved $s (Plan $s Auto) EndOfDisk NoChange
}
Check 'Already adequate oversized end recovery retains its full original size' {
    $s = Existing-Scenario GPT EndOfDisk
    $s.Partitions[-1].Offset -= 1GB
    $s.Partitions[-1].Size += 1GB
    Assert-Preserved $s (Plan $s Auto) EndOfDisk ExtendOnly
}

Write-Host "RESULT: $passed passed; $failed failed."
Write-Host 'Scope: actual pure planner under PowerShell on Linux; no partition, filesystem, boot, or recovery changes executed.'
if ($failed) { exit 1 }
