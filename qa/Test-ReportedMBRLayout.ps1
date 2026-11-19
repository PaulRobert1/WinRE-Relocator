param([string]$ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Move-WinRE-ExtendC.ps1'))
$ErrorActionPreference = 'Stop'
$file = $ScriptPath
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Get-WinRELocation', 'Get-LayoutPlan')) {
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    Invoke-Expression $fn.Extent.Text
}
$wrapped = "Windows RE status: Enabled`r`nWindows RE location: \\?\GLOBALROOT\device\harddisk0\partition3\Recovery\Win`r`n dowsRE`r`nBoot Configuration Data (BCD) identifier: 11111111-2222-4333-8444-555555555555"
$location = Get-WinRELocation $wrapped
if ($null -eq $location -or $location.DiskNumber -ne 0 -or $location.PartitionNumber -ne 3 -or $location.RelativePath -ne '\Recovery\WindowsRE') {
    throw 'The exact wrapped WinRE location supplied by the user was not recognized.'
}
Write-Host 'PASS exact wrapped WinRE location'
$plain = '\\?\GLOBALROOT\device\harddisk0\partition3\Recovery\WindowsRE'
$suffix = '\Recovery\WindowsRE'
for ($i = 1; $i -lt $suffix.Length; $i++) {
    $variant = $plain.Substring(0, $plain.Length - $suffix.Length) + $suffix.Substring(0, $i) + "`r`n " + $suffix.Substring($i)
    $loc = Get-WinRELocation $variant
    if ($null -eq $loc -or $loc.RelativePath -ne $suffix -or $loc.PartitionNumber -ne 3) { throw "Suffix wrap $i was not recognized." }
}
Write-Host 'PASS recovery-directory wraps at every suffix boundary'
$disk = [pscustomobject]@{ Number=0; PartitionStyle='MBR'; Size=[uint64]107374182400 }
function New-ReportedPart($Number, $Letter, $Size, $Offset, $Mbr, $Boot, $System, $Active) {
    [pscustomobject]@{ DiskNumber=0; PartitionNumber=$Number; DriveLetter=$Letter; Size=[uint64]$Size; Offset=[uint64]$Offset; MbrType=$Mbr; GptType=$null; IsBoot=$Boot; IsSystem=$System; IsActive=$Active }
}
# The report omits raw MbrType; 0x27 is the expected value, rechecked on Windows by the script.
$parts = @(
    (New-ReportedPart 1 '' 104857600 1048576 7 $false $true $true),
    (New-ReportedPart 2 'C' 85242937344 105906176 7 $true $false $false),
    (New-ReportedPart 3 '' 548405248 85348843520 39 $false $false $false)
)
$plan = Get-LayoutPlan $disk $parts[1] $parts $location 1GB -Placement EndOfDisk
if ($plan.ExpectedCSize -ne 106193485824 -or $plan.RecoveryOffset -ne 106299392000 -or $plan.TailBytes -ne 21476933632) {
    throw 'The plan does not match the exact reported geometry.'
}
Write-Host 'PASS 100-GiB MBR regression offsets and 1-GiB recovery allocation'
$plan | Select-Object ExpectedCSize, RecoveryOffset, RecoverySize, TailBytes | Format-List
Write-Host 'Scope: pure helpers only. Recovery MbrType 0x27 and partition flags are assumptions checked against the live machine at runtime.'
Write-Host 'RESULT: 3 passed; 0 failed.'
