# Release notes

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
