# WinRE Relocator

**Relocate Windows Recovery Environment and extend C: online on supported basic GPT and MBR disks.**

WinRE Relocator is a standalone PowerShell script that creates and verifies a replacement recovery partition before deleting the original. It can use an existing unallocated gap before C: or unallocated space at the end of the disk. It never moves the beginning of C: or initiates or schedules a reboot.

**[Download Move-WinRE-ExtendC.ps1 — v3.0.0](https://github.com/PaulRobert1/WinRE-Relocator/releases/download/v3.0.0/Move-WinRE-ExtendC.ps1)**

[Full operations guide](docs/OPERATIONS.txt) · [Validation record](docs/VALIDATION.txt) · [Release notes](RELEASE_NOTES.md)

> **Validation status:** The included tests report **200 passing checks, zero failures, and one skipped EFS fixture** on Linux with PowerShell 7.6.9. Real Windows Storage, REAgentC, BitLocker, rollback registration, and recovery boot operations have not been executed as part of that validation. Validate the tool on a disposable Windows clone before production use.

## Quick start

Take a recoverable system or VM backup first. The recovery-file backup created by this script does not replace a system backup.

Download the script, open **64-bit Windows PowerShell 5.1 as Administrator**, and change to the directory containing it. Use `powershell.exe` for the Windows operation; the script refuses `pwsh.exe` for disk changes.

### 1. Preview the plan

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Move-WinRE-ExtendC.ps1" -BackupDrive D
```

Preview is the default. It inspects the configuration and reports the selected placement, expected C: growth, and working-space requirements. It does not create a backup or change partitions, WinRE settings, or BitLocker protection.

### 2. Apply the reviewed plan

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Move-WinRE-ExtendC.ps1" -BackupDrive D -Placement Auto -Apply
```

`-Apply` executes the selected plan without another interactive confirmation. Backups and operation logs go to a new directory on D: by default. Specify a different separate local NTFS data volume if needed.

### Other examples

Use disk-end placement even when a suitable front gap exists:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Move-WinRE-ExtendC.ps1" -BackupDrive D -Placement EndOfDisk -Apply
```

Preview strict front placement. This stops if an existing gap cannot hold the replacement:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Move-WinRE-ExtendC.ps1" -BackupDrive D -Placement BeforeC
```

Use E: for backups and reserve at least 2 GiB for the new recovery partition:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Move-WinRE-ExtendC.ps1" -BackupDrive E -MinimumRecoverySizeMB 2048 -Apply
```

## Parameters

| Parameter | Default | Purpose |
|---|---|---|
| `-Apply` | Absent | Perform the operation. Omit it for preview. |
| `-Placement` | `Auto` | Select `Auto`, `BeforeC`, or `EndOfDisk`. See the placement rules below. |
| `-BackupDrive` | `D` | Letter of a separate, accessible, healthy, fixed NTFS data volume. Supply the letter without a colon. C: and the recovery volume are rejected as backup destinations. |
| `-MinimumRecoverySizeMB` | `1024` | Minimum new recovery size in **MiB**, from `1024` through `8192`. The actual allocation grows if the payload requires more space. |
| `-PassThru` | Absent | Return a structured result object in addition to normal host progress for preview, completion, or `NoChange`. |

The new recovery allocation is the larger of the requested minimum and the recovery payload plus **350 MiB**, rounded up to a MiB. After copying, the new volume must still have at least **250 MiB free**. A conservative **1 MiB** is reserved at the disk end for alignment and metadata.

## Placement and resulting actions

| Placement | Behavior |
|---|---|
| `Auto` | Prefer a sufficiently large, aligned, already-unallocated gap before C:. If several fit, use the nearest suitable gap. Otherwise, use already-unallocated space at the disk end. |
| `BeforeC` | Require an existing suitable gap before C:. If none fits, stop with `RequiresOfflineRelocation`; the script does not move C: to create one. |
| `EndOfDisk` | Use the final disk extent for relocation. It does not use a front gap or move recovery that is already before C:. |

The planner also recognizes configurations that do not need another recovery partition:

| Action | Meaning |
|---|---|
| `RelocateAndExtend` | Create and verify the replacement, switch WinRE, remove the old recovery partition, then extend C:. |
| `ExtendOnly` | Preserve recovery that is already before C: with no later blocker, or already occupies an adequate final extent, and extend C: into the available contiguous space. |
| `NoChange` | Preserve the current layout because there is no meaningful extension to perform. |

Microsoft's [partition-layout guidance](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/configure-uefigpt-based-hard-drive-partitions) recommends placing recovery immediately after Windows for servicing. Choose `EndOfDisk` for that layout. Front placement does not guarantee that future Windows servicing will never create another recovery partition.

## How it works

1. **Identify the source.** Find the running C: volume and the separate WinRE partition currently registered with Windows. Record disk, partition, physical-boundary, and volume identities.
2. **Calculate a bounded plan.** Inspect the actual recovery payload and choose a destination that fits entirely within space that is already unallocated. Keep C:'s starting offset unchanged.
3. **Back up and verify.** Save the recovery payload, SHA-256 manifest, WinRE image, partition metadata, REAgent configuration, and BCD export to the selected data volume. Verify the copied contents and query the WIM with DISM.
4. **Create the replacement first.** Create, format, populate, and verify the new partition while the original recovery partition still exists and WinRE remains registered there.
5. **Switch WinRE.** Disable the original configuration, verify the image staged by REAgentC on C:, register the replacement, apply the correct GPT or MBR recovery type, enable WinRE, remove the temporary drive letter, and verify the new registration and image hash.
6. **Remove the old partition after handover.** Recheck the partition identities and resolve the current partition number immediately before issuing the deletion command. Delete only the original registered recovery partition.
7. **Extend and verify C:.** Use a size bounded by both the plan and Windows' supported maximum. Verify the final partition identities and WinRE registration. Restore BitLocker protection if this operation suspended it, reporting any failure to resume protection.

This process recreates WinRE at a new location. It does not perform a sector-by-sector partition move, shrink C:, move unrelated partitions, convert the partition style, or remove an unregistered recovery/OEM partition to make room.

## Supported scope and refusal conditions

The intended execution environment is:

- 64-bit Windows PowerShell **5.1**, running as Administrator, with Windows installed on C:.
- The Windows Storage module and built-in REAgentC, DiskPart, DISM, and BCDEdit tools.
- A healthy, writable **basic GPT or MBR disk**, with healthy NTFS Windows and recovery volumes.
- Enabled WinRE registered at the standard `\Recovery\WindowsRE` path on the Windows disk.
- For relocation, the registered recovery partition is the only partition after C:, and the complete replacement fits in existing unallocated space.
- For MBR relocation, a spare primary partition entry: **at most three existing primary partitions**. Preserving an existing recovery partition for `ExtendOnly` does not require a new entry.

The tool stops when it encounters an unsupported or unsafe state, including:

- Disabled, missing, ambiguous, nonstandard, or differently located WinRE.
- A request that would require moving C: or moving/deleting another partition.
- Relocation with four occupied MBR primary entries, or without a spare GPT entry.
- MBR extended/logical partitions, dynamic disks, or MBR capacity above the tool's 2 TiB limit.
- Reported clustered/shared storage or Storage Spaces disks.
- A recovery source marked boot/system/active, exposed through a drive letter or mounted folder, or lacking the expected recovery type.
- Known pending Windows servicing or file-replacement restart indicators.
- BitLocker conversion, paused or unknown encryption state, or an encrypted recovery destination.
- Changes to disk or volume identities, partition boundaries, recovery contents, or the prepared plan.
- Insufficient C: staging space or backup space; recovery content containing reparse points or EFS-encrypted entries.

Other recovery-type partitions before C: are preserved. Their presence does not make them deletion candidates.

**No reboot is initiated or scheduled.** This does not bypass pending maintenance or guarantee that every Windows installation can complete the operation in its current state.

## C: working space and D: backups

Moving backups to D: reduces the space required on C:, but it does not redirect REAgentC's staging directory at `C:\Windows\System32\Recovery`.

For relocation, the preflight requirements are:

| Volume | Required free space |
|---|---|
| C: | Actual `Winre.wim` size **+ 256 MiB** |
| Selected backup volume | **2 × original recovery partition size + 256 MiB** |

For example, a 523 MiB recovery partition requires at least **1,302 MiB** free on the backup volume. If its WIM is 400 MiB, C: requires at least **656 MiB** free. The script checks C: space again before switching WinRE because other services may consume it during preparation.

The script's backup, transcript, and DISM scratch/log files use the selected data volume. Windows-native utilities can still write their normal system logs.

## Logs and failure handling

Each apply creates a restricted directory such as:

```text
D:\WinRE-Relocation-<timestamp>-<id>\
```

| File or directory | Contents |
|---|---|
| `Operation.log` | Operation transcript and diagnostic output. |
| `State.json` | Current or last stage, prepared plan, partition identities, attempted changes, and outcome. |
| `Partitions-before.xml`, `WinRE-before.txt`, `BCD-before`, `ReAgent-before.xml` | Original partition and recovery configuration records; REAgent XML is saved when present. |
| `OldPartition\`, `Payload-manifest.json` | Original ordinary files/directories and their sizes and SHA-256 hashes. |
| `Winre.wim`, `Winre.sha256.txt` | Separate recovery-image backup and hash. |
| `DISM-WimInfo.log` | Image-metadata verification log. |

The backup covers recovery files; it is not a raw partition image or a system backup. Root `System Volume Information` and `$RECYCLE.BIN` directories are excluded. The manifest verifies ordinary contents and directories, not original ACLs or alternate data streams. The WIM is copied byte-for-byte and hash-checked.

Before confirmed handover, a failed WinRE switch attempts to restore the original image and explicitly register its original partition again. After the replacement is confirmed, later failure preserves it. There is no destructive automatic partition rollback, so a failed C: extension can leave the replacement in place while C: retains its old size.

After a failed creation, deletion, or resize attempt, inspect `State.json`, `Operation.log`, the live partition list, and `reagentc /info` before running the tool again or removing any partition. An unused replacement partition may remain after an early failure. The journal records the operation; it is not an automatic resume mechanism.

BitLocker is resumed only if the tool suspended protection that was originally on. An already-suspended configuration is preserved. A failure to restore protection is reported and must be resolved before treating the operation as complete.

### Read-only post-checks

```powershell
reagentc /info

$diskNumber = (Get-Partition -DriveLetter C).DiskNumber
Get-Partition -DiskNumber $diskNumber |
    Sort-Object Offset |
    Format-Table PartitionNumber, DriveLetter, Type, Size, Offset

Get-Volume -DriveLetter C |
    Format-List FileSystem, HealthStatus, Size, SizeRemaining
```

Successful completion confirms the intended WinRE registration and the checked C: extension. It does not establish recovery bootability. Keep the backup until a later planned recovery boot test succeeds; the script does not schedule that test.

## Tests and validation

From the repository or an extracted source archive:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\qa\Run-Tests.ps1
```

The helper suites can also run with PowerShell 7 on Linux:

```powershell
pwsh -NoProfile -File ./qa/Run-Tests.ps1
```

The runner parses the main script, checks known PowerShell 5.1 syntax and encoding constraints, and runs seven suites in isolated processes. Tests extract helper definitions rather than execute the main Windows disk workflow.

The recorded run contains **200 passes, zero failures, one skipped real-EFS fixture, zero parser errors, and zero known syntax/encoding compatibility failures** under **PowerShell Core 7.6.9 on Linux**. Coverage includes layout planning, stable partition identities, sizing, real temporary-file manifests, native exit handling, and simulated DiskPart selection/failure gates.

These results do not establish Windows integration compatibility. Before production deployment, validate on disposable Windows clones, including MBR/GPT relocation, front-gap partition renumbering, BitLocker states, failure recovery, subsequent Windows startup, and a separate WinRE boot test. See the [validation record](docs/VALIDATION.txt) and [full operations guide](docs/OPERATIONS.txt) for the test boundary and remaining Windows checks.

## Microsoft references

- [REAgentC command-line options](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/reagentc-command-line-options)
- [WinRE partition procedure and recovery types — KB5028997](https://support.microsoft.com/en-us/servicing/os/windows/2023/06/kb5028997-instructions-to-manually-resize-your-partition-to-install-the-winre-update)
- [WinRE resize sample and staging guidance — KB5035679](https://support.microsoft.com/en-us/servicing/os/windows/2024/02/kb5035679-instructions-to-run-a-script-to-resize-the-recovery-partition-to-install-a-winre-update)
- [Extend a basic volume](https://learn.microsoft.com/en-us/windows-server/storage/disk-management/extend-a-basic-volume)
- [UEFI/GPT partition layout](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/configure-uefigpt-based-hard-drive-partitions)
- [BIOS/MBR partition layout](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/configure-biosmbr-based-hard-drive-partitions)

WinRE Relocator implements its own bounded workflow using Windows utilities. It is not an unchanged Microsoft sample or a Microsoft-certified utility.
