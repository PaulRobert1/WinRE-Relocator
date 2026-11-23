param([string]$ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Move-WinRE-ExtendC.ps1'))
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($ScriptPath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$defs=@($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $n.Name -in @('New-MbrPrimaryCreateCommands','Assert-MbrPrimaryCreation')},$true))
if($defs.Count -ne 2){throw 'Expected both production MBR helpers'}
foreach($d in $defs){. ([scriptblock]::Create($d.Extent.Text))}
$passed=0;$failed=0
function Check([string]$Name,[scriptblock]$Run){try{& $Run;$script:passed++;Write-Host "PASS $Name"}catch{$script:failed++;Write-Host "FAIL $Name : $($_.Exception.Message)"}}
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Refuse([scriptblock]$Run){$hit=$false;try{& $Run|Out-Null}catch{$hit=$true};Assert $hit 'Unexpected acceptance'}
function Part($Number,$Offset,$Size,$MbrType,$Boot=$false,$System=$false,$Active=$false){
    [pscustomobject]@{PartitionNumber=$Number;DiskNumber=0;Offset=[uint64]$Offset;Size=[uint64]$Size;MbrType=$MbrType;IsBoot=$Boot;IsSystem=$System;IsActive=$Active}
}
$before=@(
 Part 1 1048576 104857600 7 $false $true $true
 Part 2 105906176 85242937344 7 $true
 Part 3 85348843520 548405248 39
)
$new=Part 4 106299392000 1073741824 7
$after=@($before)+@($new)
$badExtended=Part 0 85897248768 21475885056 15
Check 'MBR commands explicitly demand primary and preserve exact requested bytes' {
    $c=@(New-MbrPrimaryCreateCommands -DiskNumber 0 -Offset 106299392000 -Size 1073741824)
    Assert ($c.Count -eq 2) 'Unexpected command count'
    Assert ($c[0] -ceq 'select disk 0') 'Disk selection incorrect'
    Assert ($c[1] -ceq 'create partition primary size=1024 offset=103808000 id=07') 'Primary command size or offset incorrect'
    Assert ($c[1] -notmatch 'logical|extended|noerr') 'Unsafe command'
}
Check 'Exact four primary topology accepted' {
    $r=@(Assert-MbrPrimaryCreation -Before $before -After $after -DiskNumber 0 -Offset 106299392000 -Size 1073741824)
    Assert ($r.Count -eq 1 -and $r[0].PartitionNumber -eq 4) 'Candidate not uniquely selected'
}
Check 'Actual observed extended plus logical topology rejected' {
    Refuse { Assert-MbrPrimaryCreation -Before $before -After (@($before)+@($badExtended)+@($new)) -DiskNumber 0 -Offset 106299392000 -Size 1073741824 }
}
Check 'Extended partition rejected despite four total entries' {
    Refuse { Assert-MbrPrimaryCreation -Before $before -After (@($before)+@($badExtended)) -DiskNumber 0 -Offset 106299392000 -Size 1073741824 }
}
Check 'Changed original partition size rejected' {
    $modified=@($after | ForEach-Object {if($_.PartitionNumber -eq 2){Part 2 105906176 85242937345 7 $true}else{$_}})
    Refuse { Assert-MbrPrimaryCreation -Before $before -After $modified -DiskNumber 0 -Offset 106299392000 -Size 1073741824 }
}
Check 'Wrong candidate type rejected' {
    $wrong=Part 4 106299392000 1073741824 39
    Refuse { Assert-MbrPrimaryCreation -Before $before -After (@($before)+@($wrong)) -DiskNumber 0 -Offset 106299392000 -Size 1073741824 }
}
Check 'Wrong candidate offset rejected' {
    $wrong=Part 4 106298343424 1073741824 7
    Refuse { Assert-MbrPrimaryCreation -Before $before -After (@($before)+@($wrong)) -DiskNumber 0 -Offset 106299392000 -Size 1073741824 }
}
Check 'Candidate marked system rejected' {
    $wrong=Part 4 106299392000 1073741824 7 $false $true
    Refuse { Assert-MbrPrimaryCreation -Before $before -After (@($before)+@($wrong)) -DiskNumber 0 -Offset 106299392000 -Size 1073741824 }
}
Check 'Three partition no-create state rejected' {
    Refuse { Assert-MbrPrimaryCreation -Before $before -After $before -DiskNumber 0 -Offset 106299392000 -Size 1073741824 }
}
Check 'Misaligned size or offset rejected before issuing command' {
    Refuse { New-MbrPrimaryCreateCommands -DiskNumber 0 -Offset 106299392001 -Size 1073741824 }
    Refuse { New-MbrPrimaryCreateCommands -DiskNumber 0 -Offset 106299392000 -Size 1073741825 }
}
Write-Host "RESULT: $passed passed; $failed failed."
Write-Host 'Scope: extracted pure helper tests. No disk/partition/REAgentC/BitLocker operations.'
if($failed){exit 1}
