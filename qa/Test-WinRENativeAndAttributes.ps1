param([string]$ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Move-WinRE-ExtendC.ps1'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$function = @($ast.FindAll({param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-NativeChecked'
}, $true))
if ($function.Count -ne 1) { throw 'Expected exactly one Invoke-NativeChecked definition' }
. ([scriptblock]::Create($function[0].Extent.Text))
$attributeRegex = @($ast.FindAll({param($node)
    $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
    $node.Value.StartsWith('(?im)') -and $node.Value.Contains('0x8000000000000001')
}, $true))
if ($attributeRegex.Count -ne 1) { throw 'Could not identify one production GPT attribute validation regex' }
$attributeRegex = $attributeRegex[0].Value
$passed = 0; $failed = 0
function Check([string]$Name, [scriptblock]$Action) {
    try { & $Action; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

$hostExecutable = Join-Path $PSHOME 'powershell.exe'
if ($PSVersionTable.PSEdition -eq 'Core') {
    $hostExecutable = Join-Path $PSHOME 'pwsh'
    if (Test-Path -LiteralPath (Join-Path $PSHOME 'pwsh.exe')) { $hostExecutable = Join-Path $PSHOME 'pwsh.exe' }
}
$probeDirectory = Join-Path ([IO.Path]::GetTempPath()) ('WinRE-Native-QA-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $probeDirectory | Out-Null
$probePath = Join-Path $probeDirectory 'Native-Probe.ps1'
@'
param([string]$Mode, [Parameter(ValueFromRemainingArguments=$true)][string[]]$Payload)
switch ($Mode) {
    'Echo' { ConvertTo-Json -InputObject @($Payload) -Compress; exit 0 }
    'Output' { [Console]::Out.WriteLine('ordinary-output'); [Console]::Error.WriteLine('warning-output'); exit 0 }
    'Fail' { [Console]::Out.WriteLine('failure-output'); exit 17 }
    default { exit 99 }
}
'@ | Set-Content -LiteralPath $probePath -Encoding UTF8
try {
Check 'Native argument arrays retain switches, paths with spaces and backslashes' {
    $actual = Invoke-NativeChecked $hostExecutable @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $probePath, '-Mode', 'Echo', '/setreimage', '/path', 'Z:\Recovery\WindowsRE', 'C:\Folder with spaces\Winre.wim')
    $values = @($actual | ConvertFrom-Json)
    Assert ($values.Count -eq 4) 'Arguments expanded, combined, or lost'
    Assert ($values[0] -eq '/setreimage') 'First argument changed'
    Assert ($values[2] -eq 'Z:\Recovery\WindowsRE') 'Windows path changed'
    Assert ($values[3] -eq 'C:\Folder with spaces\Winre.wim') 'Space-containing path split'
}
Check 'Native success captures both stdout and stderr without throwing' {
    $actual = Invoke-NativeChecked $hostExecutable @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $probePath, '-Mode', 'Output')
    Assert ($actual.Contains('ordinary-output') -and $actual.Contains('warning-output')) 'Native output missing'
}
Check 'Native failure throws with exit code and output' {
    $errorMessage = $null
    try { Invoke-NativeChecked $hostExecutable @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $probePath, '-Mode', 'Fail') | Out-Null }
    catch { $errorMessage = $_.Exception.Message }
    Assert ($null -ne $errorMessage -and $errorMessage.Contains('17') -and $errorMessage.Contains('failure-output')) 'Nonzero exit not rejected correctly'
}
Check 'Native call does not change caller ErrorActionPreference' {
    $before = $ErrorActionPreference
    Invoke-NativeChecked $hostExecutable @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $probePath, '-Mode', 'Echo', 'ok') | Out-Null
    Assert ($ErrorActionPreference -eq $before) 'Caller error preference changed'
}
Check 'GPT English detail attribute recognized' {
    Assert ("Partition 4`r`nType : de94bba4-06d1-4d40-a16a-bfd50179d6ac`r`nAttrib : 0X8000000000000001`r`nOffset in Bytes : 106300440576" -match $attributeRegex) 'English attributes not recognized'
}
Check 'GPT German detail attribute recognized' {
    Assert ("Partition 4`r`nTyp : de94bba4-06d1-4d40-a16a-bfd50179d6ac`r`nAttribut : 0x8000000000000001`r`nOffset in Byte : 106300440576" -match $attributeRegex) 'German attributes not recognized'
}
Check 'GPT required-only attributes rejected' {
    Assert ("Attrib : 0x0000000000000001`r`n" -notmatch $attributeRegex) 'Missing no-drive-letter flag accepted'
}
Check 'GPT echoed set command is not treated as verified detail' {
    Assert ("DISKPART> gpt attributes=0x8000000000000001`r`nDiskPart has encountered an error." -notmatch $attributeRegex) 'Failed command echo accepted'
}
Check 'GPT longer or malformed attribute value rejected' {
    Assert ("Attrib : 0x80000000000000011`r`n" -notmatch $attributeRegex) 'Incorrect value accepted'
}
} finally { Remove-Item -LiteralPath $probeDirectory -Recurse -Force }

# Exercise the real DiskPart wrapper's control flow while replacing only native
# execution and the timed wait. Actual temporary script-file output is inspected.
$diskPartDefinitions = @($ast.FindAll({param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DiskPartChecked'
}, $true))
if ($diskPartDefinitions.Count -ne 1) { throw 'Expected one Invoke-DiskPartChecked definition' }
function With-DiskPartFixture([scriptblock]$Action) {
    $fixtureDirectory = Join-Path ([IO.Path]::GetTempPath()) ('WinRE-DiskPart-QA-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fixtureDirectory | Out-Null
    $script:workDir = $fixtureDirectory
    $script:diskpart = 'mock-diskpart-never-executed'
    $script:lastDiskPart = [DateTime]::UtcNow
    $script:mockPartitionNumber = 3
    $script:mockIdentity = 'original-physical-partition'
    $script:invalidateDuringWait = $false
    $script:failNative = $false
    $script:waitCalls = 0; $script:nativeCalls = 0; $script:factoryCalls = 0
    $script:capturedCommands = @()
    function Start-Sleep {
        param([int]$Seconds)
        $script:waitCalls++
        $script:mockPartitionNumber = 7
        if ($script:invalidateDuringWait) { $script:mockIdentity = 'unexpected-physical-partition' }
    }
    function Invoke-NativeChecked {
        param([string]$Executable, [string[]]$ArgumentList)
        $script:nativeCalls++
        Assert ($Executable -eq 'mock-diskpart-never-executed') 'Unexpected native executable requested'
        Assert ($ArgumentList.Count -eq 2 -and $ArgumentList[0] -eq '/s') 'DiskPart input was not passed as a script file'
        $script:capturedCommands = @(Get-Content -LiteralPath $ArgumentList[1])
        if ($script:failNative) { throw 'simulated-native-failure' }
        return 'Simulated DiskPart result; no Windows operation executed.'
    }
    . ([scriptblock]::Create($diskPartDefinitions[0].Extent.Text))
    try { & $Action } finally { Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force }
}
Check 'Partition-number selection observes renumbering during the required wait' {
    With-DiskPartFixture {
        Invoke-DiskPartChecked -PrepareCommands {
            $script:factoryCalls++
            @('select disk 0', "select partition $script:mockPartitionNumber", 'delete partition override')
        } | Out-Null
        Assert ($script:waitCalls -eq 1 -and $script:factoryCalls -eq 1 -and $script:nativeCalls -eq 1) 'Wait, validation factory or native dispatch count differs'
        Assert ($script:capturedCommands -contains 'select partition 7') 'Stale partition number was selected before the wait completed'
        Assert ($script:capturedCommands -notcontains 'select partition 3') 'Original stale number reached DiskPart input'
        Assert ($script:capturedCommands[-1] -eq 'exit') 'DiskPart script lacks its terminating exit'
    }
}
Check 'Identity change during wait prevents script creation and native dispatch' {
    With-DiskPartFixture {
        $script:invalidateDuringWait = $true
        $caught = $null
        try {
            Invoke-DiskPartChecked -PrepareCommands {
                $script:factoryCalls++
                if ($script:mockIdentity -ne 'original-physical-partition') { throw 'identity-changed-after-wait' }
                @('select disk 0', "select partition $script:mockPartitionNumber", 'delete partition override')
            } | Out-Null
        } catch { $caught = $_ }
        Assert ($null -ne $caught -and [string]$caught -match 'identity-changed-after-wait') 'Post-wait identity failure was not propagated'
        Assert ($script:waitCalls -eq 1 -and $script:factoryCalls -eq 1 -and $script:nativeCalls -eq 0) 'Native execution occurred despite failed identity validation'
        Assert (@(Get-ChildItem -LiteralPath $script:workDir -Force).Count -eq 0) 'Unvalidated command file was created'
    }
}
Check 'Empty validation result cannot fall back to supplied stale commands' {
    With-DiskPartFixture {
        $caught = $null
        try { Invoke-DiskPartChecked -Commands @('select partition 3', 'delete partition override') -PrepareCommands { @() } | Out-Null }
        catch { $caught = $_ }
        Assert ($null -ne $caught -and $script:nativeCalls -eq 0) 'Empty validation result executed stale commands'
        Assert (@(Get-ChildItem -LiteralPath $script:workDir -Force).Count -eq 0) 'Empty validation result created a command file'
    }
}
Check 'Native DiskPart failure propagates while updating the invocation timestamp' {
    With-DiskPartFixture {
        $before = [DateTime]::UtcNow.AddDays(-1)
        $script:lastDiskPart = $before
        $script:failNative = $true
        $caught = $null
        try { Invoke-DiskPartChecked -Commands @('list disk') | Out-Null } catch { $caught = $_ }
        Assert ($null -ne $caught -and [string]$caught -match 'simulated-native-failure') 'Native failure was suppressed'
        Assert ($script:nativeCalls -eq 1 -and $script:lastDiskPart -gt $before.AddHours(1)) 'Failed native call did not update timing state'
    }
}
Check 'Explicit nondeletion commands remain supported without a validation factory' {
    With-DiskPartFixture {
        Invoke-DiskPartChecked -Commands @('select disk 0', 'select partition 7', 'detail partition') | Out-Null
        Assert ($script:nativeCalls -eq 1 -and $script:factoryCalls -eq 0) 'Explicit command dispatch changed'
        Assert (($script:capturedCommands -join '|') -eq 'select disk 0|select partition 7|detail partition|exit') 'Explicit commands were changed or reordered'
    }
}
Write-Host "RESULT: $passed passed; $failed failed."
Write-Host 'Scope: harmless child PowerShell process, production attribute regex, and stateful DiskPart-wrapper simulation with fake wait/native execution. No real DiskPart or Windows storage operation ran; native marshalling is checked only for the current host.'
if ($failed) { exit 1 }
