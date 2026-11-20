# Release notes

## v3.0.2

Adds an explicit, limited exception for recognized pending cleanup deletions.

**[Download Move-WinRE-ExtendC.ps1](https://github.com/PaulRobert1/WinRE-Relocator/releases/download/v3.0.2/Move-WinRE-ExtendC.ps1)**

### Pending cleanup option

The new `-AllowPendingCleanup` switch checks both `PendingFileRenameOperations` and `PendingFileRenameOperations2`. It permits only recognized deletion patterns for Edge temporary files, printer-spool V4 directories, and Windows Installer rollback files. Every accepted entry must have an empty destination. The default behavior still blocks queued file operations.

Pending CBS or Windows Update restart flags, renames/replacements with nonempty destinations, unknown paths, and malformed queues always block the operation. Each queue is parsed independently; null and whitespace destinations do not qualify as an empty deletion destination. The tool repeats the maintenance checks after backup verification, before partition changes begin. It preserves the registry queue and queued files; it does not perform or cancel their pending cleanup.

Accepted entries generate a warning with category counts. Apply journals record the selected option as `AllowPendingCleanupRequested` in `State.json`. Recognized source markers `*1` and `*2` are treated as opaque prefixes, not interpreted as operation codes. The precise path shapes are listed in the [operations guide](docs/OPERATIONS.txt).

These classifications identify queue content. They do not certify completed maintenance, printer-driver health, or overall readiness for disk changes.

### Usage

Pass the switch on both invocations when selecting this exception. Preview:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Move-WinRE-ExtendC.ps1" -BackupDrive D -Placement Auto -AllowPendingCleanup
```

Apply after reviewing a successful preview:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Move-WinRE-ExtendC.ps1" -BackupDrive D -Placement Auto -AllowPendingCleanup -Apply
```

Both examples are complete single-line commands. The option is not persisted between runs. See the [operations guide](docs/OPERATIONS.txt) for the recognized path patterns and refusal conditions.

### Validation

The **nine suites** completed in [CI run 44702822339](https://github.com/PaulRobert1/WinRE-Relocator/actions/runs/44702822339), for code and tests at commit `6b2fe0374e5f088581ad3bb4c12293a4622babf0`:

| Host | Passed | Failed | Skipped | Compatibility failures |
|---|---:|---:|---:|---:|
| Windows Server 2022, Windows PowerShell Desktop 5.1.20348.5773, CLR 4.0.30319.42000 | 318 | 0 | 1 | 0 |
| Linux, PowerShell Core 7.6.10 | 297 | 0 | 2 | 0 |

Both main-script parses passed. The new pending-maintenance suite passed **94 checks on each platform** using fixtures and mocked registry reads. It does not exercise real registry-provider fixtures or write registry values. The Windows volume GUID suite still passed 23 checks, with a symbolic-link fixture unavailable. Linux skipped the real EFS and Windows-only volume GUID fixtures.

The [validation record](docs/VALIDATION.txt) records the executed checks. Real partition changes, WinRE registration, BitLocker operations, REAgentC rollback registration, Windows startup after relocation, and recovery boot remain outside the integration-tested scope. Validate on a disposable Windows clone before production use.

## v3.0.1

Compatibility hotfix for recovery-file access through volume GUID paths on Windows PowerShell 5.1.

**[Download Move-WinRE-ExtendC.ps1](https://github.com/PaulRobert1/WinRE-Relocator/releases/download/v3.0.1/Move-WinRE-ExtendC.ps1)**

### Fix

An affected host reported `Get-Item: Illegal characters in path` during v3.0.0 preflight while reading `Winre.wim` through `\\?\Volume{GUID}\...`. Windows accepts that volume GUID syntax, but PowerShell's filesystem provider can involve host-dependent .NET path normalization. The reporting host was not available for testing. The v3.0.0 manifest passed on the modern Windows runner, so the identical failure was not reproduced there.

v3.0.1 uses native Win32 file operations for metadata, directory enumeration, SHA-256 hashing, copying, and rollback directory/file restoration when a volume GUID path is involved. The source and destination volume GUIDs remain the identities used to verify the intended partitions. Preview requires no mount point or drive-letter assignment and makes no .NET/runtime configuration changes.

The fix covers access throughout the workflow, including reading the source payload, verifying the replacement after its temporary letter is removed, and restoring original recovery files during an attempted rollback. Native REAgentC rollback registration still requires integration validation on a disposable Windows clone.

### Retrying the reported preflight failure

Replace the script with v3.0.1, open a fresh elevated 64-bit Windows PowerShell 5.1 window, and rerun preview:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Move-WinRE-ExtendC.ps1" -BackupDrive D
```

The reported `Get-Item` preflight failure occurs before partition or WinRE changes; no partition cleanup is needed for that failure. Review the preview before adding `-Apply`. If a previous attempt progressed into partition changes, inspect its `State.json`, `Operation.log`, live partition list, and `reagentc /info` before retrying.

### Validation

The runner now executes **eight suites**. [CI run 44552477165](https://github.com/PaulRobert1/WinRE-Relocator/actions/runs/44552477165), for code and tests at commit `d905dbe27d04b4a571d3f07c07adf91da60611f7`, recorded:

| Host | Passed | Failed | Skipped | Compatibility failures |
|---|---:|---:|---:|---:|
| Windows Server 2022, Windows PowerShell Desktop 5.1.20348.5773, CLR 4.0.30319.42000 | 224 | 0 | 1 | 0 |
| Linux, PowerShell Core 7.6.10 | 203 | 0 | 2 | 0 |

Both main-script parses passed. The Windows volume GUID suite passed **23 checks** on real temporary files; its sole skip was an unavailable symbolic-link fixture. Linux skipped the real EFS and Windows-only volume GUID fixtures. The tests also corrected a PowerShell 5.1 JSON-wrapper expectation; that correction required no production-code change.

These results validate helpers and native file fixtures, not the complete disk workflow. **Real partition changes, WinRE registration, BitLocker operations, REAgentC rollback registration, Windows startup after relocation, and recovery boot remain untested.** The reporting host's exact failure was not reproduced. The requirement to validate on a disposable Windows clone before production use still applies.

Microsoft background: [path normalization](https://learn.microsoft.com/en-us/dotnet/framework/migration-guide/mitigation-path-normalization) and [volume GUID paths](https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-volume).

## v3.0.0

Standalone online WinRE relocation and C: extension for supported basic GPT and MBR layouts.

**[Download Move-WinRE-ExtendC.ps1](https://github.com/PaulRobert1/WinRE-Relocator/releases/download/v3.0.0/Move-WinRE-ExtendC.ps1)**

### Features

- **Create before deletion:** Build and verify the replacement recovery partition while the original remains intact. Remove the original only after the new WinRE registration and image are verified.
- **Three placement modes:** `Auto` prefers a suitable existing gap before C: and otherwise selects the disk end. `BeforeC` requires a front gap; `EndOfDisk` selects the final extent.
- **Preview by default:** `-Apply` executes the selected plan; `-PassThru` adds a structured result object.
- **Preserve completed layouts:** Use `ExtendOnly` or `NoChange` when the registered recovery partition is already suitably placed.
- **Verified backups on a separate volume:** D: is the default. Backups include the recovery payload, SHA-256 manifest, separate WIM, partition metadata, recovery configuration, and BCD export.
- **Bounded changes:** Validate disk/partition/volume identities, resolve partition numbers after the DiskPart wait, enforce supported C: growth limits, and require existing destination space and a spare partition entry.
- **Operation journal and failure handling:** Record progress in `State.json` and `Operation.log`; attempt original WinRE registration recovery before confirmed handover and preserve a verified replacement afterward.
- **BitLocker handling:** Suspend originally enabled protection when needed and attempt to restore it on exit, reporting any resumption failure.
- **No automatic reboot:** The tool neither initiates nor schedules a reboot and does not move the beginning of C:.

### Validation

The included QA runner recorded **200 passing checks, zero failures, and one skipped real-EFS fixture** on **Linux with PowerShell Core 7.6.9**. The main script parsed without errors and passed the included checks for known PowerShell 5.1 syntax and encoding constraints.

These tests cover helpers, temporary filesystem fixtures, harmless native process calls, and simulated DiskPart failure gates. **Real Windows Storage, REAgentC, BitLocker, rollback registration, and recovery boot behavior have not been validated by that run.** Validate on a disposable Windows clone before production use.

### Execution requirements and limits

Run the Windows operation with **64-bit Windows PowerShell 5.1 as Administrator**. WinRE must be enabled at the standard path on the Windows disk, and the complete replacement must fit in existing unallocated space. MBR relocation requires a spare primary partition entry. Unsupported layouts, insufficient working space, pending maintenance, and unsafe identity or encryption changes are refused.

Read the [README](README.md) for commands and parameters, the [operations guide](docs/OPERATIONS.txt) for the complete workflow and failure handling, and the [validation record](docs/VALIDATION.txt) for the recorded test results.
