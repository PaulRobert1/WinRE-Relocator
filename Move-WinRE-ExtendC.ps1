#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Previews or performs online WinRE relocation and C: extension on supported basic disks.
.DESCRIPTION
For a BASIC GPT/MBR disk with enabled WinRE registered on the Windows disk.
Auto uses an existing adequate gap before C:; otherwise it uses the disk end.
It never moves the beginning of C:, shrinks C:, initiates or schedules a reboot.
It stops if required online preconditions cannot be satisfied.
Run from 64-bit Windows PowerShell as Administrator. No third-party tools are needed.
Without -Apply, only inspect the layout. With -Apply, perform the operation without prompts.
Take a recoverable system/VM backup first. The script's WinRE backup is NOT a system backup.
Minimum new recovery size: 1 GiB; increased automatically for the image and other files.
Creates and verifies the replacement BEFORE deleting the original partition.
MBR relocation requires a spare primary partition slot; extended/dynamic disks are refused.
Keep the displayed backup directory until recovery has been boot-tested later.
Backups and the operation log are written to D: by default, before WinRE is disabled.
C: still needs the actual Winre.wim size plus 256 MiB for REAgentC staging.
.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Move-WinRE-ExtendC.ps1 -BackupDrive D
.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Move-WinRE-ExtendC.ps1 -Placement Auto -BackupDrive D -Apply
.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Move-WinRE-ExtendC.ps1 -Placement BeforeC -BackupDrive E
.PARAMETER AllowPendingCleanup
Explicitly permit only recognized deletion-only entries under Edge Temp, printer
V4Dirs, and Config.Msi. Preserve the pending queue and files. Servicing restarts,
file replacements, malformed entries, and other paths still block execution.
.NOTES
Version 3.0.2. See the included validation record; Windows disk/WinRE/BitLocker
integration and boot testing are still required on a disposable clone before production.
Preview is read-only. -Apply authorizes the selected plan without interactive prompts.
This is a scoped tool, not a promise that every possible Windows disk layout is supported.
Procedure references (Microsoft):
https://support.microsoft.com/en-us/servicing/os/windows/2023/06/kb5028997-instructions-to-manually-resize-your-partition-to-install-the-winre-update
https://support.microsoft.com/en-us/servicing/os/windows/2024/02/kb5035679-instructions-to-run-a-script-to-resize-the-recovery-partition-to-install-a-winre-update
https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/reagentc-command-line-options
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [ValidateSet('Auto', 'BeforeC', 'EndOfDisk')]
    [string]$Placement = 'Auto',
    [ValidateRange(1024, 8192)]
    [int]$MinimumRecoverySizeMB = 1024,
    [ValidatePattern('^[A-Za-z]$')]
    [string]$BackupDrive = 'D',
    [switch]$AllowPendingCleanup,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-WinRELocation {
    param([AllowEmptyString()][string]$Text)
    # Device paths are invariant; the headings and Enabled/Disabled words are localized.
    # Accept console line wrapping inside the known directory suffix only.
    # Keep disk/partition identity and the exact directory name mandatory.
    $relativePath = '\Recovery\WindowsRE'
    $lineWrap = '(?:[ \t]*\r?\n[ \t]*)?'
    $suffix = ($relativePath.ToCharArray() | ForEach-Object { [regex]::Escape([string]$_) }) -join $lineWrap
    $pattern = '(?im)\\\\\?\\GLOBALROOT\\device\\harddisk(?<disk>\d+)\\partition(?<part>\d+)' + $suffix + '\\?[ \t]*\r?$'
    $locations = [regex]::Matches($Text, $pattern)
    if ($locations.Count -gt 1) { throw 'More than one WinRE location was reported.' }
    if ($locations.Count -eq 0) { return $null }
    [pscustomobject]@{
        DiskNumber = [int]$locations[0].Groups['disk'].Value
        PartitionNumber = [int]$locations[0].Groups['part'].Value
        RelativePath = $relativePath
    }
}

function Get-LayoutPlan {
    param(
        [Parameter(Mandatory)]$Disk,
        [Parameter(Mandatory)]$OsPartition,
        [Parameter(Mandatory)][object[]]$Partitions,
        [AllowNull()]$WinRELocation,
        [uint64]$RecoverySize = 1GB,
        [ValidateSet('Auto', 'BeforeC', 'EndOfDisk')][string]$Placement = 'Auto'
    )
    $recoveryGuid = 'de94bba4-06d1-4d40-a16a-bfd50179d6ac'
    $basicGuid = 'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7'
    $style = [string]$Disk.PartitionStyle
    if ($style -notin @('GPT', 'MBR')) { throw 'Only basic GPT or MBR disks are supported.' }
    if ($OsPartition.DiskNumber -ne $Disk.Number) { throw 'C: is on a different disk.' }
    if ($null -eq $WinRELocation -or $WinRELocation.DiskNumber -ne $Disk.Number) {
        throw 'Enabled WinRE registered on the Windows disk is required. No unregistered recovery partition will be deleted.'
    }
    if ($RecoverySize -lt 1GB -or ($RecoverySize % 1MB) -ne 0) {
        throw 'Recovery reservation must be at least 1 GiB and aligned to 1 MiB.'
    }
    $ordered = @($Partitions | Sort-Object Offset)
    $lastEnd = [uint64]0
    $numbers = @{}
    foreach ($p in $ordered) {
        if ($p.DiskNumber -ne $Disk.Number -or $numbers.ContainsKey([int]$p.PartitionNumber)) {
            throw 'Partition enumeration is inconsistent.'
        }
        $numbers[[int]$p.PartitionNumber] = $true
        if ($p.Size -le 0 -or $p.Offset -lt 1MB -or $p.Offset -lt $lastEnd -or ($p.Offset + $p.Size) -gt $Disk.Size) {
            throw 'Partition boundaries overlap or exceed the disk.'
        }
        $lastEnd = [uint64]($p.Offset + $p.Size)
    }
    $listedOs = @($ordered | Where-Object PartitionNumber -eq $OsPartition.PartitionNumber)
    if ($listedOs.Count -ne 1 -or $listedOs[0].Offset -ne $OsPartition.Offset -or
        $listedOs[0].Size -ne $OsPartition.Size -or $listedOs[0].DriveLetter -ne $OsPartition.DriveLetter) {
        throw 'The C: partition changed or could not be identified uniquely.'
    }
    if ($style -eq 'MBR') {
        if ($Disk.Size -gt 2TB -or $ordered.Count -gt 4 -or
            @($ordered | Where-Object { [int]$_.MbrType -in @(0x05, 0x0F, 0x85, 0x42) }).Count -gt 0) {
            throw 'Extended, logical, dynamic, or MBR disks above 2 TiB are unsupported.'
        }
        if ([int]$OsPartition.MbrType -ne 0x07) { throw 'C: is not a primary NTFS/basic partition.' }
    } else {
        if (([string]$OsPartition.GptType).Trim('{}') -ine $basicGuid) { throw 'C: is not a GPT basic-data partition.' }
        if (@($ordered | Where-Object { ([string]$_.GptType).Trim('{}') -in @(
            '5808c8aa-7e8f-42e0-85d2-e1e90434cfb3', 'af9b60a0-1431-4f62-bc68-3311714a69ad') }).Count -gt 0) {
            throw 'GPT dynamic disks are unsupported.'
        }
    }
    $registered = @($ordered | Where-Object PartitionNumber -eq $WinRELocation.PartitionNumber)
    if ($registered.Count -ne 1) { throw 'The registered WinRE partition cannot be identified uniquely.' }
    $r = $registered[0]
    if (($style -eq 'MBR' -and [int]$r.MbrType -ne 0x27) -or
        ($style -eq 'GPT' -and ([string]$r.GptType).Trim('{}') -ine $recoveryGuid)) {
        throw 'The registered WinRE location is not a standard separate recovery partition.'
    }
    $afterOs = @($ordered | Where-Object { $_.Offset -gt $OsPartition.Offset })
    if ($r.IsBoot -or $r.IsSystem -or $r.IsActive -or ([string]$r.DriveLetter -match '[A-Za-z]')) {
        throw 'The target recovery partition is boot/system/active or has a drive letter.'
    }
    if ($r.PSObject.Properties['AccessPaths'] -and
        @($r.AccessPaths | Where-Object { $_ -match '^[A-Za-z]:\\' }).Count -gt 0) {
        throw 'The recovery partition has a mounted drive or folder. Unmount it before using this tool.'
    }

    # All arithmetic describes exclusive byte boundaries; never change C:'s start.
    $usableEnd = [long]([Math]::Floor(($Disk.Size - 1MB) / 1MB) * 1MB)
    $osEnd = [long]($OsPartition.Offset + $OsPartition.Size)
    $tail = [long]$Disk.Size - [long]($ordered[-1].Offset + $ordered[-1].Size)
    $beforeOs = @($ordered | Where-Object { $_.Offset -lt $OsPartition.Offset })
    $frontGaps = @()
    $cursor = [long]1MB
    foreach ($p in @($beforeOs) + @($OsPartition)) {
        $gapStart = [long]([Math]::Ceiling($cursor / 1MB) * 1MB)
        $gapEnd = [long]([Math]::Floor($p.Offset / 1MB) * 1MB)
        if (($gapEnd - $gapStart) -ge [long]$RecoverySize) {
            $frontGaps += [pscustomobject]@{ Start = $gapStart; End = $gapEnd }
        }
        $cursor = [long]($p.Offset + $p.Size)
    }
    $selected = $Placement
    if ($Placement -eq 'Auto') {
        if ($frontGaps.Count -gt 0 -or $r.Offset -lt $OsPartition.Offset) { $selected = 'BeforeC' }
        else { $selected = 'EndOfDisk' }
    }

    # Successful earlier front placement needs only ordinary online C: growth.
    if ($r.Offset -lt $OsPartition.Offset) {
        if ($afterOs.Count -gt 0) {
            throw 'Another partition after C: blocks extension; it is not the registered WinRE partition and will not be deleted.'
        }
        if ($selected -ne 'BeforeC') { throw 'WinRE is already before C:. Use Auto or BeforeC to preserve it and extend C:.' }
        $targetSize = [Math]::Max([long]$OsPartition.Size, ($usableEnd - [long]$OsPartition.Offset))
        $action = 'NoChange'
        if (($targetSize - [long]$OsPartition.Size) -ge 1MB) { $action = 'ExtendOnly' }
        else { $targetSize = [long]$OsPartition.Size }
        return [pscustomobject]@{
            RecoveryPartition = $r; ExpectedCSize = [uint64]$targetSize
            RecoveryOffset = [uint64]$r.Offset; RecoverySize = [uint64]$r.Size; TailBytes = [uint64]$tail
            SelectedPlacement = 'BeforeC'; CGrowthLimit = [uint64]($OsPartition.Offset + $targetSize)
            GainBytes = [uint64]($targetSize - $OsPartition.Size); Action = $action
            PlacementReason = 'Registered WinRE is already before C: and can be preserved.'
        }
    }
    if ($afterOs.Count -ne 1 -or $afterOs[0].Offset -ne $r.Offset) {
        throw 'Required relocation layout: C:, its registered recovery partition, then unallocated space. Other partitions will not be moved.'
    }
    if ($selected -eq 'BeforeC' -and $frontGaps.Count -eq 0) {
        throw 'RequiresOfflineRelocation: no sufficiently large existing gap before C:. The running C: partition will not be moved.'
    }
    if ($selected -eq 'EndOfDisk' -and ($r.Offset + $r.Size) -ge $usableEnd -and $r.Size -ge $RecoverySize) {
        $targetSize = [long]$r.Offset - [long]$OsPartition.Offset
        $action = 'NoChange'
        if (($targetSize - [long]$OsPartition.Size) -ge 1MB) { $action = 'ExtendOnly' }
        else { $targetSize = [long]$OsPartition.Size }
        return [pscustomobject]@{
            RecoveryPartition = $r; ExpectedCSize = [uint64]$targetSize
            RecoveryOffset = [uint64]$r.Offset; RecoverySize = [uint64]$r.Size; TailBytes = [uint64]$tail
            SelectedPlacement = 'EndOfDisk'; CGrowthLimit = [uint64]$r.Offset
            GainBytes = [uint64]($targetSize - $OsPartition.Size); Action = $action
            PlacementReason = 'Registered WinRE already occupies the final recovery extent and can be preserved.'
        }
    }
    if ($style -eq 'MBR' -and $ordered.Count -ge 4) {
        throw 'No spare MBR primary partition slot. Creating and verifying the replacement before deletion requires a free slot.'
    }
    if ($style -eq 'GPT' -and $ordered.Count -ge 128) { throw 'No spare GPT partition entry is available.' }
    if ($selected -eq 'BeforeC') {
        $gap = $frontGaps[-1]
        $newOffset = [long]$gap.End - [long]$RecoverySize
        $growthLimit = $usableEnd
        $reason = 'An existing aligned gap before C: fits the complete replacement. No existing partition start will move.'
    } else {
        $newOffset = $usableEnd - [long]$RecoverySize
        $growthLimit = $newOffset
        $reason = 'The replacement fits in existing unallocated space at the disk end.'
        if ($Placement -eq 'Auto') { $reason = 'No adequate front gap exists. Auto selected existing unallocated space at the disk end.' }
        if ($newOffset -lt [long]($r.Offset + $r.Size)) {
            throw 'Not enough existing trailing unallocated space to create the replacement while preserving the original recovery partition.'
        }
    }
    $newCSize = [long]$growthLimit - [long]$OsPartition.Offset
    if ($newCSize -lt ([long]$OsPartition.Size + 1MB)) {
        throw 'The proposed relocation would not grow C: by at least 1 MiB. Nothing will be changed.'
    }
    [pscustomobject]@{
        RecoveryPartition = $r
        ExpectedCSize = [uint64]$newCSize
        RecoveryOffset = [uint64]$newOffset
        RecoverySize = $RecoverySize
        TailBytes = [uint64]$tail
        SelectedPlacement = $selected
        CGrowthLimit = [uint64]$growthLimit
        GainBytes = [uint64]($newCSize - $OsPartition.Size)
        Action = 'RelocateAndExtend'
        PlacementReason = $reason
    }
}

function Get-StagingSpacePlan {
    param([long]$WimBytes, [long]$RecoveryPartitionBytes, [long]$CFreeBytes, [long]$BackupFreeBytes)
    if ($WimBytes -le 0 -or $RecoveryPartitionBytes -le 0 -or $WimBytes -gt $RecoveryPartitionBytes -or
        $CFreeBytes -lt 0 -or $BackupFreeBytes -lt 0) {
        throw 'Invalid image size or volume free-space information. No partition changes were made.'
    }
    $requiredC = $WimBytes + 256MB
    $requiredBackup = 2 * $RecoveryPartitionBytes + 256MB
    if ($CFreeBytes -lt $requiredC) {
        throw ('C: has {0:N1} MiB free; at least {1:N1} MiB is needed for WinRE staging and a 256-MiB margin. Free working space first.' -f ($CFreeBytes / 1MB), ($requiredC / 1MB))
    }
    if ($BackupFreeBytes -lt $requiredBackup) {
        throw ('The backup drive has {0:N1} MiB free; at least {1:N1} MiB is required.' -f ($BackupFreeBytes / 1MB), ($requiredBackup / 1MB))
    }
    [pscustomobject]@{ RequiredCBytes = [long]$requiredC; RequiredBackupBytes = [long]$requiredBackup }
}

function Get-RecoverySize {
    param([long]$WimBytes, [long]$OtherBytes, [int]$MinimumSizeMB = 1024)
    if ($WimBytes -le 0 -or $OtherBytes -lt 0 -or $MinimumSizeMB -lt 1024 -or $MinimumSizeMB -gt 8192) {
        throw 'Invalid recovery payload size or minimum size (1024-8192 MiB).'
    }
    $required = [decimal]$WimBytes + [decimal]$OtherBytes + 350MB
    if ($required -gt [long]::MaxValue) { throw 'Recovery payload size is out of range.' }
    [uint64]([Math]::Ceiling([Math]::Max(([long]$MinimumSizeMB * 1MB), [double]$required) / 1MB) * 1MB)
}

function Get-CGrowthTarget {
    param($OsPartition, [uint64]$SupportedSizeMax, [uint64]$CGrowthLimit)
    if ($OsPartition.Offset -lt 0 -or $OsPartition.Size -le 0 -or
        $CGrowthLimit -le $OsPartition.Offset -or $SupportedSizeMax -lt $OsPartition.Size) {
        throw 'Invalid C: growth bounds; shrinking is not allowed.'
    }
    $maximum = [Math]::Min([decimal]$SupportedSizeMax, ([decimal]$CGrowthLimit - $OsPartition.Offset))
    $end = [Math]::Floor(([decimal]$OsPartition.Offset + $maximum) / 1MB) * 1MB
    $target = $end - $OsPartition.Offset
    if ($target -lt ([decimal]$OsPartition.Size + 1MB)) {
        throw 'C: cannot grow by at least 1 MiB within the supported and planned boundary.'
    }
    [uint64]$target
}

function New-PartitionIdentity {
    param($Disk, $Partition, [string]$VolumePath = '')
    if ([string]::IsNullOrWhiteSpace([string]$Disk.UniqueId) -or $Disk.Number -ne $Partition.DiskNumber) {
        throw 'A stable disk identity is required.'
    }
    $guid = ''
    if ([string]$Disk.PartitionStyle -eq 'GPT') {
        if (-not $Partition.PSObject.Properties['Guid'] -or [string]::IsNullOrWhiteSpace([string]$Partition.Guid)) {
            throw 'A unique GPT partition GUID is required.'
        }
        $guid = ([string]$Partition.Guid).Trim('{}')
    }
    [pscustomobject]@{
        DiskNumber = [uint32]$Disk.Number; DiskUniqueId = [string]$Disk.UniqueId
        DiskSize = [uint64]$Disk.Size; PartitionStyle = [string]$Disk.PartitionStyle
        Offset = [uint64]$Partition.Offset; Size = [uint64]$Partition.Size
        Guid = $guid; VolumePath = $VolumePath
    }
}

function Assert-PartitionIdentity {
    param($Identity, $Disk, $Partition, [string]$VolumePath = '', [switch]$AllowSizeChange)
    if ($Disk.Number -ne $Identity.DiskNumber -or $Disk.UniqueId -ine $Identity.DiskUniqueId -or
        $Disk.Size -ne $Identity.DiskSize -or [string]$Disk.PartitionStyle -ine $Identity.PartitionStyle -or
        $Partition.DiskNumber -ne $Identity.DiskNumber -or $Partition.Offset -ne $Identity.Offset -or
        (-not $AllowSizeChange -and $Partition.Size -ne $Identity.Size)) {
        throw 'Disk or physical partition identity changed. No further destructive operation is allowed.'
    }
    if ($Identity.Guid -and (-not $Partition.PSObject.Properties['Guid'] -or
        ([string]$Partition.Guid).Trim('{}') -ine $Identity.Guid)) { throw 'The GPT partition GUID changed.' }
    if ($Identity.VolumePath -and $VolumePath -ine $Identity.VolumePath) { throw 'The volume GUID path changed.' }
}

function Initialize-RecoveryFileAccess {
    # Windows PowerShell 5.1 can send device paths through legacy .NET path
    # validation even with -LiteralPath. Keep GUID paths out of that provider.
    if ($null -ne ('WinRERelocator.NativeFilesV301' -as [type])) { return }
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

namespace WinRERelocator {
    public sealed class RecoveryFileItemV301 {
        public string FullName { get; set; }
        public string Name { get; set; }
        public FileAttributes Attributes { get; set; }
        public long Length { get; set; }
        public DateTime LastWriteTimeUtc { get; set; }
        public bool PSIsContainer { get { return (Attributes & FileAttributes.Directory) != 0; } }
    }
    public static class NativeFilesV301 {
        [StructLayout(LayoutKind.Sequential)]
        private struct FileTime { public uint Low; public uint High; }
        [StructLayout(LayoutKind.Sequential)]
        private struct AttributeData {
            public uint Attributes;
            public FileTime CreationTime, LastAccessTime, LastWriteTime;
            public uint SizeHigh, SizeLow;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct FindData {
            public uint Attributes;
            public FileTime CreationTime, LastAccessTime, LastWriteTime;
            public uint SizeHigh, SizeLow, Reserved0, Reserved1;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Name;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string AlternateName;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileAttributesExW(string path, int level, out AttributeData data);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern IntPtr FindFirstFileW(string path, out FindData data);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool FindNextFileW(IntPtr handle, out FindData data);
        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool FindClose(IntPtr handle);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(string path, uint access, uint share,
            IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CopyFileW(string source, string destination, [MarshalAs(UnmanagedType.Bool)] bool failIfExists);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateDirectoryW(string path, IntPtr security);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetFileAttributesW(string path, uint attributes);

        private static int RootLength(string path) {
            Match match = Regex.Match(path, @"^\\\\\?\\Volume\{[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\}\\", RegexOptions.IgnoreCase);
            if (match.Success) return match.Length;
            if (Regex.IsMatch(path, @"^[A-Za-z]:\\")) return 3;
            throw new ArgumentException("Recovery file access requires an absolute volume-GUID or local drive path.");
        }
        private static string ValidatePath(string path) {
            if (String.IsNullOrWhiteSpace(path)) throw new ArgumentException("Recovery path is empty.");
            int rootLength = RootLength(path);
            string tail = path.Substring(rootLength).TrimEnd('\\');
            if (tail.Length != 0) {
                foreach (string part in tail.Split('\\')) {
                    if (part.Length == 0 || part == "." || part == ".." ||
                        part.IndexOfAny(new char[] {'/', ':', '*', '?', '"', '<', '>', '|'}) >= 0)
                        throw new ArgumentException("Recovery path contains an unsafe component.");
                    foreach (char c in part) if (c < 32) throw new ArgumentException("Recovery path contains a control character.");
                }
            }
            return tail.Length == 0 ? path.Substring(0, rootLength) : path.Substring(0, rootLength) + tail;
        }
        private static Exception Error(string operation, string path, int code) {
            return new Win32Exception(code, operation + " failed for '" + path + "': " + new Win32Exception(code).Message);
        }
        private static RecoveryFileItemV301 Item(string path, uint attributes, uint high, uint low, FileTime modified) {
            ulong length = ((ulong)high << 32) | low;
            if (length > Int64.MaxValue) throw new IOException("Recovery file size is out of range.");
            string namePath = path.TrimEnd('\\');
            return new RecoveryFileItemV301 {
                FullName = path, Name = namePath.Substring(namePath.LastIndexOf('\\') + 1),
                Attributes = (FileAttributes)attributes,
                Length = (attributes & 0x10) != 0 ? 0 : (long)length,
                LastWriteTimeUtc = DateTime.FromFileTimeUtc((long)(((ulong)modified.High << 32) | modified.Low))
            };
        }
        public static RecoveryFileItemV301 GetItem(string path, bool allowMissing) {
            path = ValidatePath(path);
            AttributeData data;
            if (!GetFileAttributesExW(path, 0, out data)) {
                int code = Marshal.GetLastWin32Error();
                if (allowMissing && (code == 2 || code == 3)) return null;
                throw Error("Read recovery metadata", path, code);
            }
            return Item(path, data.Attributes, data.SizeHigh, data.SizeLow, data.LastWriteTime);
        }
        private static void RequireOrdinary(RecoveryFileItemV301 item, bool directory) {
            if (item.PSIsContainer != directory || (item.Attributes & (FileAttributes.ReparsePoint | FileAttributes.Encrypted)) != 0)
                throw new IOException("Recovery entry has an unsupported type, reparse point, or EFS encryption: " + item.FullName);
        }
        public static RecoveryFileItemV301[] GetChildren(string path) {
            path = ValidatePath(path);
            RequireOrdinary(GetItem(path, false), true);
            string prefix = path.TrimEnd('\\') + "\\";
            FindData data;
            IntPtr handle = FindFirstFileW(prefix + "*", out data);
            if (handle == new IntPtr(-1)) {
                int code = Marshal.GetLastWin32Error();
                if (code == 2) return new RecoveryFileItemV301[0];
                throw Error("Enumerate recovery directory", path, code);
            }
            List<RecoveryFileItemV301> items = new List<RecoveryFileItemV301>();
            try {
                do {
                    if (data.Name != "." && data.Name != "..")
                        items.Add(Item(prefix + data.Name, data.Attributes, data.SizeHigh, data.SizeLow, data.LastWriteTime));
                } while (FindNextFileW(handle, out data));
                int code = Marshal.GetLastWin32Error();
                if (code != 18) throw Error("Continue recovery directory enumeration", path, code);
            } finally { FindClose(handle); }
            return items.ToArray();
        }
        public static string HashFile(string path) {
            path = ValidatePath(path);
            RequireOrdinary(GetItem(path, false), false);
            // Read-only handle; OPEN_REPARSE_POINT prevents following a replaced file link.
            using (SafeFileHandle handle = CreateFileW(path, 0x80000000, 1, IntPtr.Zero, 3, 0x08200000, IntPtr.Zero)) {
                if (handle.IsInvalid) throw Error("Open recovery file", path, Marshal.GetLastWin32Error());
                using (FileStream stream = new FileStream(handle, FileAccess.Read))
                using (SHA256 hash = SHA256.Create())
                    return BitConverter.ToString(hash.ComputeHash(stream)).Replace("-", "");
            }
        }
        public static void CopyFile(string source, string destination) {
            source = ValidatePath(source); destination = ValidatePath(destination);
            if (String.Equals(source, destination, StringComparison.OrdinalIgnoreCase)) throw new IOException("Recovery copy source equals destination.");
            RequireOrdinary(GetItem(source, false), false);
            RecoveryFileItemV301 existing = GetItem(destination, true);
            uint originalAttributes = 0; bool cleared = false;
            if (existing != null) {
                RequireOrdinary(existing, false);
                originalAttributes = (uint)existing.Attributes;
                // CopyFileW refuses an existing Hidden/ReadOnly target; match -Force.
                uint writable = originalAttributes & ~3U;
                if (writable == 0) writable = 0x80;
                if (writable != originalAttributes) {
                    if (!SetFileAttributesW(destination, writable)) throw Error("Prepare recovery copy target", destination, Marshal.GetLastWin32Error());
                    cleared = true;
                }
            }
            if (!CopyFileW(source, destination, false)) {
                int code = Marshal.GetLastWin32Error();
                if (cleared) SetFileAttributesW(destination, originalAttributes);
                throw Error("Copy recovery file", destination, code);
            }
        }
        public static void CreateDirectory(string path) {
            path = ValidatePath(path);
            RecoveryFileItemV301 existing = GetItem(path, true);
            if (existing != null) { RequireOrdinary(existing, true); return; }
            int rootLength = RootLength(path);
            if (path.Length <= rootLength) throw new IOException("The recovery volume root is unavailable.");
            int split = path.LastIndexOf('\\');
            string parent = split < rootLength ? path.Substring(0, rootLength) : path.Substring(0, split);
            CreateDirectory(parent);
            if (!CreateDirectoryW(path, IntPtr.Zero)) {
                int code = Marshal.GetLastWin32Error();
                if (code != 183) throw Error("Create recovery directory", path, code);
            }
            RequireOrdinary(GetItem(path, false), true);
        }
    }
}
'@ -ErrorAction Stop
}

function Join-RecoveryPath {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath -match '^[\\/]|(^|[\\/])\.{1,2}([\\/]|$)|[:\x00-\x1f<>|"*?]') {
        throw 'Recovery child path must be relative and cannot contain traversal, a stream, or wildcard characters.'
    }
    if ($Root.StartsWith('\\?\', [StringComparison]::Ordinal)) {
        if ($Root -notmatch '^\\\\\?\\Volume\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}\\') {
            throw 'Recovery device path is not a valid volume-GUID path.'
        }
        return $Root.TrimEnd('\') + '\' + $RelativePath.Replace('/', '\')
    }
    Join-Path -Path $Root -ChildPath $RelativePath
}

function Get-RecoveryFileItem {
    param([Parameter(Mandatory)][string]$LiteralPath, [switch]$AllowMissing)
    if ($LiteralPath.StartsWith('\\?\', [StringComparison]::Ordinal)) {
        Initialize-RecoveryFileAccess
        return [WinRERelocator.NativeFilesV301]::GetItem($LiteralPath, [bool]$AllowMissing)
    }
    try { Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] { if (-not $AllowMissing) { throw } }
}

function Get-RecoveryChildItem {
    param([Parameter(Mandatory)][string]$LiteralPath)
    if ($LiteralPath.StartsWith('\\?\', [StringComparison]::Ordinal)) {
        Initialize-RecoveryFileAccess
        return [WinRERelocator.NativeFilesV301]::GetChildren($LiteralPath)
    }
    Get-ChildItem -LiteralPath $LiteralPath -Force -ErrorAction Stop
}

function Get-RecoveryFileHash {
    param([Parameter(Mandatory)][string]$LiteralPath)
    if ($LiteralPath.StartsWith('\\?\', [StringComparison]::Ordinal)) {
        Initialize-RecoveryFileAccess
        return [WinRERelocator.NativeFilesV301]::HashFile($LiteralPath)
    }
    (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256 -ErrorAction Stop).Hash
}

function Copy-RecoveryFile {
    param([Parameter(Mandatory)][string]$LiteralPath, [Parameter(Mandatory)][string]$Destination)
    if ($LiteralPath.StartsWith('\\?\', [StringComparison]::Ordinal) -or $Destination.StartsWith('\\?\', [StringComparison]::Ordinal)) {
        Initialize-RecoveryFileAccess
        [WinRERelocator.NativeFilesV301]::CopyFile($LiteralPath, $Destination)
    } else { Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force -ErrorAction Stop }
}

function New-RecoveryDirectory {
    param([Parameter(Mandatory)][string]$LiteralPath)
    if ($LiteralPath.StartsWith('\\?\', [StringComparison]::Ordinal)) {
        Initialize-RecoveryFileAccess
        [WinRERelocator.NativeFilesV301]::CreateDirectory($LiteralPath)
    } else { New-Item -ItemType Directory -Path $LiteralPath -Force -ErrorAction Stop | Out-Null }
}

function Get-RecoveryManifest {
    param([Parameter(Mandatory)][string]$Root, [switch]$WithHash)
    $rootItem = Get-RecoveryFileItem -LiteralPath $Root
    if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Recovery root must be a real directory, not a reparse point.'
    }
    $rootPrefix = $rootItem.FullName.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($rootItem.FullName)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($entry in @(Get-RecoveryChildItem -LiteralPath $directory)) {
            $relative = $entry.FullName.Substring($rootPrefix.Length)
            if ($directory.TrimEnd([char[]]'\/') -ieq $rootItem.FullName.TrimEnd([char[]]'\/') -and
                $entry.Name -in @('System Volume Information', '$RECYCLE.BIN')) { continue }
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Recovery contains a reparse point: $relative. It will not be traversed."
            }
            if ($entry.Attributes -band [IO.FileAttributes]::Encrypted) { throw "Recovery contains an EFS-encrypted entry: $relative." }
            $length = [long]0; $hash = ''
            if ($entry.PSIsContainer) { $pending.Push($entry.FullName) }
            else {
                $length = [long]$entry.Length
                if ($WithHash) {
                    $hash = Get-RecoveryFileHash -LiteralPath $entry.FullName
                    $after = Get-RecoveryFileItem -LiteralPath $entry.FullName
                    if ($after.Length -ne $length -or $after.LastWriteTimeUtc -ne $entry.LastWriteTimeUtc) {
                        throw "Recovery file changed while it was being verified: $relative."
                    }
                }
            }
            [pscustomobject]@{ RelativePath = $relative; IsDirectory = [bool]$entry.PSIsContainer; Length = $length; Hash = $hash }
        }
    }
}

function Assert-RecoveryManifest {
    param([AllowEmptyCollection()][object[]]$Expected, [AllowEmptyCollection()][object[]]$Actual, [switch]$IgnoreHashes)
    $maps = @(@{}, @{})
    $sets = @(@($Expected), @($Actual))
    for ($index = 0; $index -lt 2; $index++) {
        foreach ($entry in $sets[$index]) {
            $key = ([string]$entry.RelativePath).Replace('\', '/')
            if ([string]::IsNullOrWhiteSpace($key) -or $key.StartsWith('/') -or $key -match '(^|/)\.\.(/|$)' -or
                $key -match '^[A-Za-z]:' -or $maps[$index].ContainsKey($key) -or $entry.Length -lt 0) {
                throw 'Invalid or duplicate recovery manifest path.'
            }
            $maps[$index][$key] = $entry
        }
    }
    if ($maps[0].Count -ne $maps[1].Count) { throw 'Recovery payload membership changed (missing or extra entries).' }
    foreach ($key in $maps[0].Keys) {
        if (-not $maps[1].ContainsKey($key)) { throw "Recovery payload entry is missing: $key." }
        $a = $maps[0][$key]; $b = $maps[1][$key]
        if ($a.IsDirectory -ne $b.IsDirectory -or $a.Length -ne $b.Length) { throw "Recovery payload type/length changed: $key." }
        if (-not $IgnoreHashes -and -not $a.IsDirectory -and
            ([string]$a.Hash -notmatch '^[0-9a-fA-F]{64}$' -or $a.Hash -ine $b.Hash)) {
            throw "Recovery payload SHA256 mismatch: $key."
        }
    }
}

function Invoke-NativeChecked {
    param([string]$Executable, [string[]]$ArgumentList)
    # Windows PowerShell 5.1 represents native stderr as error records.
    $ErrorActionPreference = 'Continue'
    $output = & $Executable @ArgumentList 2>&1
    $exitCode = $LASTEXITCODE
    $result = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ($exitCode -ne 0) { throw "$Executable failed (exit $exitCode).`n$result" }
    return $result
}

function Invoke-DiskPartChecked {
    param([string[]]$Commands, [scriptblock]$PrepareCommands)
    # Microsoft recommends 15 seconds between successive DiskPart script invocations.
    $wait = 15 - ([DateTime]::UtcNow - $script:lastDiskPart).TotalSeconds
    if ($wait -gt 0) { Start-Sleep -Seconds ([int][Math]::Ceiling($wait)) }
    # Resolve partition numbers only after the inter-invocation wait.
    if ($null -ne $PrepareCommands) { $Commands = @(& $PrepareCommands) }
    if ($null -eq $Commands -or $Commands.Count -eq 0) { throw 'No validated DiskPart commands were supplied.' }
    $path = Join-Path $script:workDir ('diskpart-' + [guid]::NewGuid().ToString('N') + '.txt')
    ($Commands + 'exit') | Set-Content -LiteralPath $path -Encoding ASCII
    try {
        $result = Invoke-NativeChecked $script:diskpart @('/s', $path)
        Write-Host $result
        return $result
    } finally { $script:lastDiskPart = [DateTime]::UtcNow }
}

function Invoke-BitLockerMethod {
    param($Volume, [string]$Method, [hashtable]$Arguments = @{})
    $result = Invoke-CimMethod -InputObject $Volume -MethodName $Method -Arguments $Arguments
    if ([uint32]$result.ReturnValue -ne 0) { throw "BitLocker $Method failed: $($result.ReturnValue)." }
    return $result
}

function Get-SinglePartitionVolume {
    param($Partition)
    $volumes = @($Partition | Get-Volume -ErrorAction Stop)
    if ($volumes.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$volumes[0].Path)) {
        throw 'A unique volume GUID path could not be established for the partition.'
    }
    $volumes[0]
}

function Get-CurrentPartition {
    param($Identity, [switch]$AllowSizeChange)
    $currentDisk = Get-Disk -Number $Identity.DiskNumber -ErrorAction Stop
    $matches = @(Get-Partition -DiskNumber $Identity.DiskNumber -ErrorAction Stop |
        Where-Object { $_.Offset -eq $Identity.Offset })
    if ($matches.Count -ne 1) { throw "Partition at byte offset $($Identity.Offset) is absent or ambiguous." }
    $volumePath = ''
    if ($Identity.VolumePath) { $volumePath = [string](Get-SinglePartitionVolume $matches[0]).Path }
    Assert-PartitionIdentity $Identity $currentDisk $matches[0] $volumePath -AllowSizeChange:$AllowSizeChange
    $matches[0]
}

function Assert-CurrentLayout {
    param([switch]$AllowCGrowth)
    $current = @(Get-Partition -DiskNumber $script:disk.Number -ErrorAction Stop)
    $expectedCount = $script:originalIdentities.Count
    if ($script:oldDeleted) { $expectedCount-- }
    if ($null -ne $script:newIdentity) { $expectedCount++ }
    if ($current.Count -ne $expectedCount) { throw 'The partition set changed unexpectedly.' }
    foreach ($identity in $script:originalIdentities) {
        if ($script:oldDeleted -and $identity.Offset -eq $script:oldIdentity.Offset) { continue }
        $allowSize = $AllowCGrowth -and $identity.Offset -eq $script:cIdentity.Offset
        $p = Get-CurrentPartition $identity -AllowSizeChange:$allowSize
        $before = @($script:originalParts | Where-Object Offset -eq $identity.Offset)[0]
        if ([string]$p.GptType -ine [string]$before.GptType -or [int]$p.MbrType -ne [int]$before.MbrType -or
            $p.IsBoot -ne $before.IsBoot -or $p.IsSystem -ne $before.IsSystem -or $p.IsActive -ne $before.IsActive) {
            throw 'An original partition type or boot/system flag changed unexpectedly.'
        }
    }
    if ($null -ne $script:newIdentity) { Get-CurrentPartition $script:newIdentity | Out-Null }
}

function Assert-WinREOnIdentity {
    param($Identity)
    $p = Get-CurrentPartition $Identity
    $info = Invoke-NativeChecked $script:reagentc @('/info')
    $location = Get-WinRELocation $info
    if ($null -eq $location -or $location.DiskNumber -ne $p.DiskNumber -or
        $location.PartitionNumber -ne $p.PartitionNumber) {
        throw 'WinRE is not registered on the intended physical partition.'
    }
    $info
}

function Get-VolumeEncryptionState {
    param([string]$VolumePath, [switch]$RequireReported)
    $available = $true
    try {
        $all = @(Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftVolumeEncryption' `
            -ClassName Win32_EncryptableVolume -ErrorAction Stop)
    } catch [Microsoft.Management.Infrastructure.CimException] {
        if ([string]$_.Exception.StatusCode -notin @('InvalidNamespace', 'InvalidClass')) { throw }
        $available = $false; $all = @()
    }
    $matches = @($all | Where-Object { ([string]$_.DeviceID).TrimEnd('\') -ieq $VolumePath.TrimEnd('\') })
    if ($matches.Count -gt 1 -or ($available -and $RequireReported -and $matches.Count -ne 1)) {
        throw 'Cannot establish a unique BitLocker state for the target volume.'
    }
    $conversion = 0; $protection = 0; $volume = $null
    if ($matches.Count -eq 1) {
        $volume = $matches[0]
        $conversion = [int](Invoke-BitLockerMethod $volume 'GetConversionStatus' @{PrecisionFactor = [uint32]0}).ConversionStatus
        $protection = [int](Invoke-BitLockerMethod $volume 'GetProtectionStatus').ProtectionStatus
        if ($conversion -notin @(0, 1) -or $protection -notin @(0, 1)) {
            throw 'BitLocker conversion is in progress/paused or its state is unknown. No online relocation will be attempted.'
        }
    }
    [pscustomobject]@{ ProviderAvailable = $available; Reported = ($matches.Count -eq 1)
        Volume = $volume; ConversionStatus = $conversion; ProtectionStatus = $protection }
}

function Get-PendingFileOperationAssessment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SessionManager,
        [Parameter(Mandatory)][string]$WindowsDirectory,
        [AllowEmptyCollection()][string[]]$ProgramFilesDirectories = @()
    )
    # This is a narrow path policy, not evidence that an installer has finished.
    # Preserve the native strings and empty destinations; never edit either queue.
    $operations = New-Object 'System.Collections.Generic.List[object]'
    $guidPattern = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    $printPattern = '\A' + [regex]::Escape($WindowsDirectory.TrimEnd('\')) +
        '\\System32\\spool\\V4Dirs\\' + $guidPattern + '(?:\\(?:[0-9a-f]+\.(?:bud|gpd)|pdc\.xml))?\z'
    $edgePatterns = @()
    foreach ($directory in $ProgramFilesDirectories) {
        if (-not [string]::IsNullOrWhiteSpace($directory)) {
            $edgePatterns += '\A' + [regex]::Escape($directory.TrimEnd('\')) +
                '\\Microsoft\\Edge\\Temp(?:\\(?:scoped_dir)?[0-9]+_[0-9]+(?:\\old_msedge\.exe)?)?\z'
        }
    }
    foreach ($valueName in @('PendingFileRenameOperations', 'PendingFileRenameOperations2')) {
        $property = $SessionManager.PSObject.Properties[$valueName]
        if ($null -eq $property) { continue }
        $raw = $property.Value
        if ($raw -isnot [Array] -or $raw.Rank -ne 1 -or ($raw.Count % 2) -ne 0) {
            $operations.Add([pscustomobject]@{
                ValueName = $valueName; PairIndex = -1; Source = $null; Destination = $null
                Category = 'Unrecognized'; AllowedCleanup = $false
                Reason = 'Expected an even-length array of source/destination strings.'
            })
            continue
        }
        for ($i = 0; $i -lt $raw.Count; $i += 2) {
            $source = $raw[$i]; $destination = $raw[$i + 1]
            $category = 'Unrecognized'; $reason = ''
            if ($source -isnot [string] -or $destination -isnot [string]) {
                $reason = 'Source and destination must both be strings; null is not an empty destination.'
            } elseif ([string]::IsNullOrWhiteSpace($source)) {
                $reason = 'The source is empty or whitespace.'
            } elseif ($destination.Length -ne 0) {
                $reason = 'A nonempty destination denotes a rename/replacement, not an allowed deletion.'
            } else {
                # *1 and *2 are observed opaque markers, not interpreted opcodes.
                $match = [regex]::Match($source, '\A(?:\*[12])?\\\?\?\\(?<Path>[A-Za-z]:\\.+)\z')
                if (-not $match.Success) {
                    $reason = 'Unrecognized source prefix or nonlocal path.'
                } else {
                    $path = $match.Groups['Path'].Value
                    $tail = $path.Substring(3)
                    $components = @($tail -split '\\')
                    if ($tail -match '[\x00-\x1f\x7f<>:"/|?*]' -or
                        @($components | Where-Object { $_.Length -eq 0 -or $_ -in @('.', '..') -or $_ -match '[ .]\z' }).Count -gt 0) {
                        $reason = 'Unsafe or ambiguous path components.'
                    } elseif ($path -imatch $printPattern) {
                        $category = 'PrintDriverCleanup'
                    } elseif ($path -imatch '\A[A-Za-z]:\\Config\.Msi\\[0-9a-f]+\.rbf\z') {
                        $category = 'InstallerRollbackCleanup'
                    } else {
                        foreach ($pattern in $edgePatterns) {
                            if ($path -imatch $pattern) { $category = 'EdgeCleanup'; break }
                        }
                        if ($category -eq 'Unrecognized') { $reason = 'Path is outside the restricted cleanup patterns.' }
                    }
                }
            }
            $operations.Add([pscustomobject]@{
                ValueName = $valueName; PairIndex = [int]($i / 2); Source = $source; Destination = $destination
                Category = $category; AllowedCleanup = ($category -ne 'Unrecognized'); Reason = $reason
            })
        }
    }
    $allowed = @($operations | Where-Object AllowedCleanup).Count
    [pscustomobject]@{
        OperationCount = $operations.Count; AllowedCleanupCount = $allowed
        BlockedCount = $operations.Count - $allowed
        CanAllowCleanup = ($operations.Count -gt 0 -and $allowed -eq $operations.Count)
        Operations = @($operations.ToArray())
    }
}

function Assert-NoPendingMaintenance {
    [CmdletBinding()]
    param([switch]$AllowPendingCleanup)
    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
        if (Test-Path -LiteralPath $key -ErrorAction Stop) { throw 'Windows reports a pending servicing restart. This tool will not reboot or continue through it.' }
    }
    $sessionKey = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
    $programDirectories = @($env:ProgramFiles, ${env:ProgramFiles(x86)})
    $assessment = Get-PendingFileOperationAssessment -SessionManager $sessionKey -WindowsDirectory $env:SystemRoot -ProgramFilesDirectories $programDirectories
    if ($assessment.OperationCount -eq 0) { return }
    if ($assessment.BlockedCount -gt 0) {
        $first = @($assessment.Operations | Where-Object { -not $_.AllowedCleanup })[0]
        throw ('Pending file operations include {0} entry/entries outside the cleanup exception. {1}, pair {2}: {3} Source: {4} Destination: {5}' -f
            $assessment.BlockedCount, $first.ValueName, $first.PairIndex, $first.Reason, $first.Source, $first.Destination)
    }
    if (-not $AllowPendingCleanup) {
        throw ('Windows has {0} pending file deletion(s) matching restricted cleanup patterns. Review the queue and rerun with -AllowPendingCleanup to explicitly permit these entries without changing the queue.' -f $assessment.OperationCount)
    }
    $categories = @($assessment.Operations | Group-Object Category | ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }) -join ', '
    Write-Warning ('AllowPendingCleanup accepted {0} recognized deletion-only entries ({1}). The registry queue and queued files are preserved. This does not certify that all maintenance has finished.' -f $assessment.OperationCount, $categories)
}

function Assert-BackupVolume {
    $v = @(Get-Volume -DriveLetter $script:backupLetter -ErrorAction Stop)
    if ($v.Count -ne 1 -or $v[0].Path -ine $script:backupVolume.Path -or
        $v[0].FileSystem -ne 'NTFS' -or [string]$v[0].HealthStatus -ne 'Healthy') {
        throw 'The backup volume identity or health changed.'
    }
    $v[0]
}

function Write-OperationState {
    if ($null -eq $script:workDir) { return }
    Assert-BackupVolume | Out-Null
    $script:state.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    $temporary = Join-Path $script:workDir 'State.json.tmp'
    $script:state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination (Join-Path $script:workDir 'State.json') -Force
}

function Set-OperationStage {
    param([string]$Stage)
    $script:stage = $Stage
    $script:state.Stage = $Stage
    Write-Host "[$Stage]"
    Write-OperationState
}

function Copy-RecoveryPayload {
    param([string]$Source, [string]$Destination, [object[]]$Manifest)
    foreach ($entry in @($Manifest | Sort-Object @{E={$_.RelativePath.Length}}, RelativePath)) {
        $from = Join-RecoveryPath $Source $entry.RelativePath
        $to = Join-RecoveryPath $Destination $entry.RelativePath
        $current = Get-RecoveryFileItem -LiteralPath $from
        if ($current.Attributes -band [IO.FileAttributes]::ReparsePoint -or
            $current.Attributes -band [IO.FileAttributes]::Encrypted) { throw 'Recovery source changed to an unsupported entry.' }
        if ($entry.IsDirectory) { New-RecoveryDirectory -LiteralPath $to }
        else { Copy-RecoveryFile -LiteralPath $from -Destination $to }
    }
}

function Get-FreeTemporaryLetter {
    $used = @((Get-PSDrive -PSProvider FileSystem).Name) + @((Get-Volume).DriveLetter)
    $letters = @('ZYXWVUTSRQPONMLKJIHGFED'.ToCharArray() | Where-Object { [string]$_ -notin $used })
    if ($letters.Count -eq 0) { throw 'No temporary drive letter is available.' }
    [char]$letters[0]
}

function Set-NewRecoveryType {
    $p = Get-CurrentPartition $script:newIdentity
    $commands = @("select disk $($p.DiskNumber)", "select partition $($p.PartitionNumber)")
    if ([string]$script:disk.PartitionStyle -eq 'GPT') {
        $commands += @('set id=de94bba4-06d1-4d40-a16a-bfd50179d6ac override', 'gpt attributes=0x8000000000000001', 'detail partition')
    } else { $commands += @('set id=27 override', 'detail partition') }
    $detail = Invoke-DiskPartChecked $commands
    Update-HostStorageCache
    $p = Get-CurrentPartition $script:newIdentity
    if ([string]$script:disk.PartitionStyle -eq 'GPT') {
        if (([string]$p.GptType).Trim('{}') -ine 'de94bba4-06d1-4d40-a16a-bfd50179d6ac' -or
            $detail -notmatch '(?im)^\s*[^:\r\n]+:\s*0x8000000000000001\s*$') { throw 'GPT recovery type/attributes were not applied.' }
    } elseif ([int]$p.MbrType -ne 0x27) { throw 'MBR recovery type 0x27 was not applied.' }
}

function Remove-NewTemporaryAccess {
    if ($null -eq $script:newIdentity -or $null -eq $script:temporaryLetter) { return }
    $p = Get-CurrentPartition $script:newIdentity
    $path = '{0}:\' -f $script:temporaryLetter
    if ($p.AccessPaths -contains $path) {
        Remove-PartitionAccessPath -DiskNumber $p.DiskNumber -PartitionNumber $p.PartitionNumber -AccessPath $path -ErrorAction Stop
    }
}

function Restore-OriginalWinRE {
    # This is used only before old-partition deletion and before a confirmed handover.
    $old = Get-CurrentPartition $script:oldIdentity
    $root = [string](Get-SinglePartitionVolume $old).Path
    $dir = Join-RecoveryPath $root 'Recovery\WindowsRE'
    $wim = Join-RecoveryPath $dir 'Winre.wim'
    try {
        $existingInfo = Assert-WinREOnIdentity $script:oldIdentity
        $existingWim = Get-RecoveryFileItem -LiteralPath $wim -AllowMissing
        if ($null -ne $existingWim -and -not $existingWim.PSIsContainer -and
            (Get-RecoveryFileHash -LiteralPath $wim) -eq $script:wimHash) {
            Write-Host $existingInfo
            Write-Host 'Original WinRE remains correctly registered with the verified image.'
            $script:state.OriginalWinRERestored = $true
            return
        }
    } catch { Write-Host 'Restoring the original WinRE registration explicitly.' }
    New-RecoveryDirectory -LiteralPath $dir
    Copy-RecoveryFile -LiteralPath $script:backupWim -Destination $wim
    if ((Get-RecoveryFileHash -LiteralPath $wim) -ne $script:wimHash) { throw 'Original WinRE image restore failed verification.' }
    # An earlier failed enable may have left a different location active.
    Write-Host (Invoke-NativeChecked $script:reagentc @('/disable'))
    # Disable can move the image again; restore it after disabling as well.
    Copy-RecoveryFile -LiteralPath $script:backupWim -Destination $wim
    Write-Host (Invoke-NativeChecked $script:reagentc @('/setreimage', '/path', $dir))
    Write-Host (Invoke-NativeChecked $script:reagentc @('/enable'))
    Write-Host (Assert-WinREOnIdentity $script:oldIdentity)
    $script:state.OriginalWinRERestored = $true
}

if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
    throw 'Run this in 64-bit Windows PowerShell 5.1 as Administrator on the target Windows machine.'
}
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Use Windows PowerShell (powershell.exe), not PowerShell 7 (pwsh.exe), for the Windows operation.' }
if ($env:SystemDrive -ine 'C:') { throw 'This version supports the running Windows installation on C:.' }
Import-Module Storage -ErrorAction Stop
$script:reagentc = Join-Path $env:SystemRoot 'System32\reagentc.exe'
$script:diskpart = Join-Path $env:SystemRoot 'System32\diskpart.exe'
$dism = Join-Path $env:SystemRoot 'System32\dism.exe'
$bcdedit = Join-Path $env:SystemRoot 'System32\bcdedit.exe'
$localWim = Join-Path $env:SystemRoot 'System32\Recovery\Winre.wim'
$reagentXml = Join-Path $env:SystemRoot 'System32\Recovery\ReAgent.xml'
$script:lastDiskPart = [DateTime]::MinValue
$script:workDir = $null; $script:newIdentity = $null; $script:oldDeleted = $false
$script:temporaryLetter = $null; $script:backupWim = $null; $script:wimHash = $null
$script:stage = 'preflight'; $transcribing = $false; $suspendedBitLocker = $false
$disableAttempted = $false; $newWinREVerified = $false; $creationAttempted = $false
$deletionAttempted = $false; $resizeAttempted = $false; $failure = $null; $finished = $false
$mutex = $null; $mutexOwned = $false; $bitLockerVolume = $null; $finalC = $null
$script:state = [ordered]@{
    ToolVersion = '3.0.2'; ComputerName = $env:COMPUTERNAME; StartedUtc = [DateTime]::UtcNow.ToString('o')
    AllowPendingCleanupRequested = [bool]$AllowPendingCleanup
    UpdatedUtc = ''; Stage = 'preflight'; Result = 'InProgress'; RequestedPlacement = $Placement
    Plan = $null; OriginalC = $null; OriginalRecovery = $null; NewRecovery = $null
    CreationAttempted = $false; NewWinREVerified = $false; OldDeletionAttempted = $false; OldDeleted = $false
    ResizeAttempted = $false; OriginalWinRERestored = $false; BitLockerSuspendedByTool = $false
    BitLockerResumed = $false; Failure = $null; FinalCSize = $null
}

try {
    foreach ($exe in @($script:reagentc, $script:diskpart, $dism, $bcdedit)) {
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Required Windows tool is missing: $exe" }
    }
    if ($Apply) {
        $mutex = New-Object System.Threading.Mutex($false, 'Global\WinRE-Relocator-v3')
        try { $mutexOwned = $mutex.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] {
            $mutexOwned = $true
            throw 'A previous relocation process ended unexpectedly. Inspect its State.json and current partitions before another attempt.'
        }
        if (-not $mutexOwned) { throw 'Another instance of this tool is applying changes.' }
    }
    $cs = @(Get-Partition -DriveLetter C -ErrorAction Stop)
    if ($cs.Count -ne 1) { throw 'The running C: partition is not unique.' }
    $c = $cs[0]
    $script:disk = Get-Disk -Number $c.DiskNumber -ErrorAction Stop
    $script:originalParts = @(Get-Partition -DiskNumber $script:disk.Number | Sort-Object Offset)
    $cVolume = Get-SinglePartitionVolume $c
    if (-not $c.IsBoot -or $script:disk.IsOffline -or $script:disk.IsReadOnly -or
        [string]$script:disk.HealthStatus -ne 'Healthy' -or [string]$cVolume.HealthStatus -ne 'Healthy' -or
        $cVolume.FileSystem -ne 'NTFS') { throw 'C: must be the running healthy NTFS Windows volume on an online writable disk.' }
    if ($script:disk.PSObject.Properties['IsClustered'] -and $script:disk.IsClustered) { throw 'Clustered/shared disks are not supported.' }
    if ([string]$script:disk.BusType -eq 'Spaces') { throw 'Storage Spaces disks are outside this tool''s supported scope.' }
    $script:cIdentity = New-PartitionIdentity $script:disk $c ([string]$cVolume.Path)
    $info = Invoke-NativeChecked $script:reagentc @('/info')
    $location = Get-WinRELocation $info
    if ($null -eq $location) { throw 'Enabled WinRE with a standard \Recovery\WindowsRE path is required. This tool will not guess which partition to delete.' }
    $sourceCandidates = @($script:originalParts | Where-Object {
        $_.DiskNumber -eq $location.DiskNumber -and $_.PartitionNumber -eq $location.PartitionNumber })
    if ($sourceCandidates.Count -ne 1) { throw 'Registered WinRE is not a unique partition on the Windows disk.' }
    $oldRecovery = $sourceCandidates[0]
    $oldVolume = Get-SinglePartitionVolume $oldRecovery
    if ($oldVolume.FileSystem -ne 'NTFS' -or [string]$oldVolume.HealthStatus -ne 'Healthy') { throw 'Registered recovery must be healthy NTFS.' }
    $script:oldIdentity = New-PartitionIdentity $script:disk $oldRecovery ([string]$oldVolume.Path)
    $oldRoot = [string]$oldVolume.Path
    $sourceWim = Join-RecoveryPath $oldRoot 'Recovery\WindowsRE\Winre.wim'
    $sourceWimItem = Get-RecoveryFileItem -LiteralPath $sourceWim -AllowMissing
    if ($null -eq $sourceWimItem -or $sourceWimItem.PSIsContainer) { throw 'The registered recovery image cannot be read. Nothing will be deleted.' }
    $wimBytes = [long]$sourceWimItem.Length
    $inventory = @(Get-RecoveryManifest -Root $oldRoot)
    $payloadBytes = [long]0
    foreach ($entry in $inventory) { if (-not $entry.IsDirectory) { $payloadBytes += $entry.Length } }
    $recoveryBytes = Get-RecoverySize $wimBytes ($payloadBytes - $wimBytes) $MinimumRecoverySizeMB
    $plan = Get-LayoutPlan $script:disk $c $script:originalParts $location $recoveryBytes -Placement $Placement
    $script:state.Plan = $plan | Select-Object Action, SelectedPlacement, RecoveryOffset, RecoverySize, CGrowthLimit, ExpectedCSize, GainBytes, PlacementReason
    $script:state.OriginalC = $script:cIdentity; $script:state.OriginalRecovery = $script:oldIdentity
    Write-Host "`nWinRE Relocator 3.0.2 - $(if ($Apply) {'APPLY'} else {'PREVIEW'})" -ForegroundColor Cyan
    Write-Host "Disk $($script:disk.Number) ($($script:disk.PartitionStyle)); requested placement: $Placement"
    $script:originalParts | Format-Table PartitionNumber, DriveLetter, Type,
        @{N='MiB';E={[Math]::Round($_.Size / 1MB, 1)}}, Offset -AutoSize | Out-Host
    Write-Host $info
    Write-Host ('Action: {0}; selected placement: {1}; recovery: {2:N0} MiB.' -f $plan.Action, $plan.SelectedPlacement, ($plan.RecoverySize / 1MB))
    Write-Host ('C: {0:N2} -> approximately {1:N2} GiB; planned gain {2:N2} GiB.' -f ($c.Size / 1GB), ($plan.ExpectedCSize / 1GB), ($plan.GainBytes / 1GB))
    Write-Host $plan.PlacementReason
    if ($plan.Action -eq 'NoChange') {
        Write-Host 'No changes required. WinRE remains on its registered partition.' -ForegroundColor Green
        if ($PassThru) { [pscustomobject]@{ Status = 'NoChange'; Plan = $script:state.Plan; RebootInitiated = $false; BootTested = $false } }
        return
    }
    $script:backupLetter = [char]$BackupDrive.ToUpperInvariant()
    $backupCandidates = @(Get-Volume -DriveLetter $script:backupLetter -ErrorAction Stop)
    if ($backupCandidates.Count -ne 1) { throw 'Choose a separate accessible fixed NTFS backup volume with -BackupDrive.' }
    $script:backupVolume = $backupCandidates[0]
    if ($script:backupVolume.FileSystem -ne 'NTFS' -or [string]$script:backupVolume.HealthStatus -ne 'Healthy' -or
        [string]$script:backupVolume.DriveType -ne 'Fixed' -or [string]::IsNullOrWhiteSpace([string]$script:backupVolume.Path) -or
        $script:backupVolume.Path -ieq $cVolume.Path -or $script:backupVolume.Path -ieq $oldVolume.Path) {
        throw 'The backup destination must be a separate healthy fixed NTFS data volume, not C: or recovery.'
    }
    if ($plan.Action -eq 'RelocateAndExtend') {
        $spacePlan = Get-StagingSpacePlan $wimBytes $oldRecovery.Size $cVolume.SizeRemaining $script:backupVolume.SizeRemaining
    } else {
        $requiredBackup = 2 * [long]$oldRecovery.Size + 256MB
        if ($script:backupVolume.SizeRemaining -lt $requiredBackup) { throw 'The backup volume lacks the required recovery-backup working space.' }
        $spacePlan = [pscustomobject]@{ RequiredCBytes = [long]0; RequiredBackupBytes = $requiredBackup }
    }
    Assert-NoPendingMaintenance -AllowPendingCleanup:$AllowPendingCleanup
    $osEncryption = Get-VolumeEncryptionState ([string]$cVolume.Path) -RequireReported
    $oldEncryption = Get-VolumeEncryptionState $oldRoot
    if ($oldEncryption.Reported -and $oldEncryption.ConversionStatus -ne 0) { throw 'The registered recovery volume must be fully decrypted.' }
    $bitLockerVolume = $osEncryption.Volume
    $protectionWasOn = $osEncryption.ProtectionStatus -eq 1
    if ($plan.Action -eq 'RelocateAndExtend') { $script:temporaryLetter = Get-FreeTemporaryLetter }
    Write-Host ('Backup: {0}:; C: needs {1:N1} MiB free (currently {2:N1}); backup needs {3:N1} MiB (currently {4:N1}).' -f
        $script:backupLetter, ($spacePlan.RequiredCBytes / 1MB), ($cVolume.SizeRemaining / 1MB),
        ($spacePlan.RequiredBackupBytes / 1MB), ($script:backupVolume.SizeRemaining / 1MB))
    Write-Host 'No reboot will be initiated or scheduled. Recovery bootability is not tested by this operation.'
    if (-not $Apply) {
        Write-Host 'Preview only: no backup was created and no partition, WinRE configuration or BitLocker changes were requested. Add -Apply to execute.' -ForegroundColor Yellow
        if ($PassThru) { [pscustomobject]@{ Status = 'Preview'; Plan = $script:state.Plan; Space = $spacePlan; RebootInitiated = $false; BootTested = $false } }
        return
    }

    $script:originalIdentities = @()
    foreach ($p in $script:originalParts) {
        $path = ''
        if ($p.Offset -eq $c.Offset) { $path = [string]$cVolume.Path }
        if ($p.Offset -eq $oldRecovery.Offset) { $path = [string]$oldVolume.Path }
        $script:originalIdentities += New-PartitionIdentity $script:disk $p $path
    }
    Assert-BackupVolume | Out-Null
    $script:workDir = Join-Path ('{0}:\' -f $script:backupLetter) ('WinRE-Relocation-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $script:workDir | Out-Null
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $script:workDir -AclObject $acl
    Start-Transcript -Path (Join-Path $script:workDir 'Operation.log') | Out-Null
    $transcribing = $true
    Set-OperationStage 'Back up and verify original recovery'
    $script:originalParts | Export-Clixml -LiteralPath (Join-Path $script:workDir 'Partitions-before.xml')
    $info | Set-Content -LiteralPath (Join-Path $script:workDir 'WinRE-before.txt') -Encoding UTF8
    Write-Host (Invoke-NativeChecked $bcdedit @('/export', (Join-Path $script:workDir 'BCD-before')))
    if (Test-Path -LiteralPath $reagentXml) { Copy-Item -LiteralPath $reagentXml -Destination (Join-Path $script:workDir 'ReAgent-before.xml') -Force }
    $manifest = @(Get-RecoveryManifest -Root $oldRoot -WithHash)
    Assert-RecoveryManifest $inventory $manifest -IgnoreHashes
    $payload = Join-Path $script:workDir 'OldPartition'
    New-Item -ItemType Directory -Path $payload | Out-Null
    Copy-RecoveryPayload $oldRoot $payload $manifest
    Assert-RecoveryManifest $manifest @(Get-RecoveryManifest -Root $payload -WithHash)
    Assert-RecoveryManifest $manifest @(Get-RecoveryManifest -Root $oldRoot -WithHash)
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $script:workDir 'Payload-manifest.json') -Encoding UTF8
    $script:backupWim = Join-Path $script:workDir 'Winre.wim'
    Copy-Item -LiteralPath (Join-Path $payload 'Recovery\WindowsRE\Winre.wim') -Destination $script:backupWim -Force
    $script:wimHash = (Get-FileHash -LiteralPath $script:backupWim -Algorithm SHA256).Hash
    if ($script:wimHash -ne (Get-RecoveryFileHash -LiteralPath $sourceWim)) { throw 'Recovery image backup hash mismatch.' }
    $script:wimHash | Set-Content -LiteralPath (Join-Path $script:workDir 'Winre.sha256.txt') -Encoding ASCII
    $scratch = Join-Path $script:workDir 'DISM-Scratch'
    New-Item -ItemType Directory -Path $scratch | Out-Null
    Write-Host (Invoke-NativeChecked $dism @('/English', '/Get-WimInfo', "/WimFile:$script:backupWim", '/Index:1',
        "/LogPath:$(Join-Path $script:workDir 'DISM-WimInfo.log')", "/ScratchDir:$scratch"))

    Set-OperationStage 'Revalidate before partition changes'
    Assert-NoPendingMaintenance -AllowPendingCleanup:$AllowPendingCleanup
    Assert-CurrentLayout
    Write-Host (Assert-WinREOnIdentity $script:oldIdentity)
    $freshC = Get-CurrentPartition $script:cIdentity
    $freshOld = Get-CurrentPartition $script:oldIdentity
    $freshDisk = Get-Disk -Number $script:disk.Number
    $freshParts = @(Get-Partition -DiskNumber $script:disk.Number | Sort-Object Offset)
    $freshLocation = [pscustomobject]@{ DiskNumber = $freshOld.DiskNumber; PartitionNumber = $freshOld.PartitionNumber }
    # Lock in the previously previewed choice; never switch Auto placement after preparation.
    $freshPlan = Get-LayoutPlan $freshDisk $freshC $freshParts $freshLocation $recoveryBytes -Placement $plan.SelectedPlacement
    foreach ($field in @('Action', 'SelectedPlacement', 'RecoveryOffset', 'RecoverySize', 'CGrowthLimit', 'ExpectedCSize')) {
        if ($freshPlan.$field -ne $plan.$field) { throw 'The plan changed during preparation. No partition change was made.' }
    }
    if ((Get-SinglePartitionVolume $freshC).SizeRemaining -lt $spacePlan.RequiredCBytes) { throw 'C: no longer has the required WinRE staging space.' }
    Assert-BackupVolume | Out-Null
    $freshEncryption = Get-VolumeEncryptionState ([string]$cVolume.Path) -RequireReported
    if ($freshEncryption.ConversionStatus -ne $osEncryption.ConversionStatus -or
        $freshEncryption.ProtectionStatus -ne $osEncryption.ProtectionStatus) { throw 'BitLocker state changed during preparation.' }
    if ($protectionWasOn) {
        $suspendedBitLocker = $true
        $script:state.BitLockerSuspendedByTool = $true
        Write-OperationState
        Invoke-BitLockerMethod $bitLockerVolume 'DisableKeyProtectors' @{DisableCount = [uint32]1} | Out-Null
        if ((Invoke-BitLockerMethod $bitLockerVolume 'GetProtectionStatus').ProtectionStatus -ne 0) { throw 'BitLocker did not suspend.' }
    }

    if ($plan.Action -eq 'RelocateAndExtend') {
        Set-OperationStage 'Create replacement while original recovery remains intact'
        $script:temporaryLetter = Get-FreeTemporaryLetter
        $newParameters = @{ DiskNumber = $script:disk.Number; Offset = $plan.RecoveryOffset; Size = $plan.RecoverySize; DriveLetter = $script:temporaryLetter }
        if ([string]$script:disk.PartitionStyle -eq 'GPT') { $newParameters.GptType = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' }
        else { $newParameters.MbrType = 'IFS' }
        $creationAttempted = $true; $script:state.CreationAttempted = $true
        Write-OperationState
        $created = @(New-Partition @newParameters -ErrorAction Stop)
        if ($created.Count -ne 1 -or $created[0].DiskNumber -ne $script:disk.Number -or
            $created[0].Offset -ne $plan.RecoveryOffset -or $created[0].Size -ne $plan.RecoverySize) {
            throw 'The newly created partition does not match the planned extent. It will not be formatted.'
        }
        $script:newIdentity = New-PartitionIdentity $freshDisk $created[0]
        $script:state.NewRecovery = $script:newIdentity
        Write-OperationState
        Assert-CurrentLayout
        $newPartition = Get-CurrentPartition $script:newIdentity
        if ($newPartition.IsBoot -or $newPartition.IsSystem -or $newPartition.IsActive) { throw 'The new partition has a protected boot/system flag; formatting refused.' }
        Format-Volume -Partition $newPartition -FileSystem NTFS -NewFileSystemLabel 'Windows RE tools' -Confirm:$false -ErrorAction Stop | Out-Null
        $newPartition = Get-CurrentPartition $script:newIdentity
        $newVolume = Get-SinglePartitionVolume $newPartition
        if ($newVolume.FileSystem -ne 'NTFS' -or [string]$newVolume.HealthStatus -ne 'Healthy') { throw 'The newly formatted recovery volume is not healthy NTFS.' }
        $script:newIdentity.VolumePath = [string]$newVolume.Path
        $mapped = @(Get-Partition -DriveLetter $script:temporaryLetter)
        if ($mapped.Count -ne 1) { throw 'Temporary drive letter is ambiguous.' }
        Assert-PartitionIdentity $script:newIdentity (Get-Disk -Number $script:disk.Number) $mapped[0] ([string](Get-SinglePartitionVolume $mapped[0]).Path)
        $newEncryption = Get-VolumeEncryptionState ([string]$newVolume.Path) -RequireReported
        if ($newEncryption.ConversionStatus -ne 0) { throw 'The new recovery volume is not fully decrypted. The original recovery will be retained.' }
        $newRoot = '{0}:\' -f $script:temporaryLetter
        Copy-RecoveryPayload $payload $newRoot $manifest
        Assert-RecoveryManifest $manifest @(Get-RecoveryManifest -Root $newRoot -WithHash)
        $newReDir = Join-Path $newRoot 'Recovery\WindowsRE'
        $newXml = Join-Path $newReDir 'ReAgent.xml'
        if (Test-Path -LiteralPath $newXml) { Remove-Item -LiteralPath $newXml -Force }
        if ((Get-SinglePartitionVolume (Get-CurrentPartition $script:newIdentity)).SizeRemaining -lt 250MB) { throw 'New recovery lacks 250 MiB of servicing space.' }

        Set-OperationStage 'Switch WinRE to the verified replacement'
        Assert-CurrentLayout
        Write-Host (Assert-WinREOnIdentity $script:oldIdentity)
        Assert-RecoveryManifest $manifest @(Get-RecoveryManifest -Root $oldRoot -WithHash)
        if ((Get-SinglePartitionVolume (Get-CurrentPartition $script:cIdentity)).SizeRemaining -lt $spacePlan.RequiredCBytes) {
            throw 'C: free space fell below the image size plus 256 MiB before WinRE staging.'
        }
        $newEncryption = Get-VolumeEncryptionState ([string]$newVolume.Path) -RequireReported
        if ($newEncryption.ConversionStatus -ne 0) { throw 'Encryption started on the replacement volume; WinRE will not be switched.' }
        $disableAttempted = $true
        Write-Host (Invoke-NativeChecked $script:reagentc @('/disable'))
        $disabledInfo = Invoke-NativeChecked $script:reagentc @('/info')
        if ($null -ne (Get-WinRELocation $disabledInfo) -or $disabledInfo -match '(?i)GLOBALROOT') { throw 'WinRE still reports a registered path after disable.' }
        if (-not (Test-Path -LiteralPath $localWim -PathType Leaf) -or
            (Get-FileHash -LiteralPath $localWim -Algorithm SHA256).Hash -ne $script:wimHash) {
            throw 'The WinRE image staged on C: is absent or differs from the verified backup.'
        }
        Write-Host (Invoke-NativeChecked $script:reagentc @('/setreimage', '/path', $newReDir))
        Set-NewRecoveryType
        Write-Host (Invoke-NativeChecked $script:reagentc @('/enable'))
        Write-Host (Assert-WinREOnIdentity $script:newIdentity)
        Remove-NewTemporaryAccess
        Write-Host (Assert-WinREOnIdentity $script:newIdentity)
        $newWim = Join-RecoveryPath $script:newIdentity.VolumePath 'Recovery\WindowsRE\Winre.wim'
        if ((Get-RecoveryFileHash -LiteralPath $newWim) -ne $script:wimHash) { throw 'The enabled replacement WinRE image differs from the backup.' }
        $newWinREVerified = $true; $script:state.NewWinREVerified = $true
        Write-OperationState

        Set-OperationStage 'Delete old recovery after verified handover'
        Assert-CurrentLayout
        Write-Host (Assert-WinREOnIdentity $script:newIdentity)
        $source = Get-CurrentPartition $script:oldIdentity
        if ($source.IsBoot -or $source.IsSystem -or $source.IsActive -or ([string]$source.DriveLetter -match '[A-Za-z]')) {
            throw 'The original recovery partition became protected or mounted; deletion refused.'
        }
        $deletionAttempted = $true; $script:state.OldDeletionAttempted = $true
        Write-OperationState
        Invoke-DiskPartChecked -PrepareCommands {
            Assert-CurrentLayout
            Assert-WinREOnIdentity $script:newIdentity | Out-Null
            $selectedSource = Get-CurrentPartition $script:oldIdentity
            if ($selectedSource.IsBoot -or $selectedSource.IsSystem -or $selectedSource.IsActive -or
                ([string]$selectedSource.DriveLetter -match '[A-Za-z]')) { throw 'Source protection changed; deletion refused.' }
            @("select disk $($selectedSource.DiskNumber)", "select partition $($selectedSource.PartitionNumber)", 'delete partition override')
        } | Out-Null
        Update-HostStorageCache
        if (@(Get-Partition -DiskNumber $script:disk.Number | Where-Object Offset -eq $script:oldIdentity.Offset).Count -ne 0) {
            throw 'The old recovery partition was not removed.'
        }
        $script:oldDeleted = $true; $script:state.OldDeleted = $true
        Write-OperationState
        Assert-CurrentLayout
        Write-Host (Assert-WinREOnIdentity $script:newIdentity)
        $activeRecovery = $script:newIdentity
    } else { $activeRecovery = $script:oldIdentity }

    Set-OperationStage 'Extend C within the planned contiguous boundary'
    Assert-CurrentLayout
    $currentC = Get-CurrentPartition $script:cIdentity
    $supported = Get-PartitionSupportedSize -DriveLetter C -ErrorAction Stop
    $target = Get-CGrowthTarget $currentC $supported.SizeMax $plan.CGrowthLimit
    if ($target -lt $plan.ExpectedCSize) { Write-Warning 'Windows allows less growth than the geometric preview. The supported safe size will be used.' }
    $resizeAttempted = $true; $script:state.ResizeAttempted = $true
    Write-OperationState
    Resize-Partition -DriveLetter C -Size $target -ErrorAction Stop
    $finalC = Get-CurrentPartition $script:cIdentity -AllowSizeChange
    if ($finalC.Size -ne $target) { throw 'C: did not reach the requested supported size.' }
    Assert-CurrentLayout -AllowCGrowth
    Write-Host (Assert-WinREOnIdentity $activeRecovery)
    $finalRecovery = Get-CurrentPartition $activeRecovery
    if ([string]$finalRecovery.DriveLetter -match '[A-Za-z]') { throw 'Recovery still has an unexpected drive letter.' }
    $script:state.FinalCSize = [uint64]$finalC.Size
    $finished = $true
} catch {
    $failure = $_
    Write-Warning "Stopped during $script:stage. $($_.Exception.Message)"
    if ($disableAttempted -and -not $newWinREVerified -and -not $deletionAttempted) {
        try { Restore-OriginalWinRE }
        catch { Write-Warning "Original WinRE could not be restored automatically: $($_.Exception.Message)" }
    }
    if ($newWinREVerified) { Write-Warning 'The verified replacement recovery is being preserved. C: may not yet have been extended.' }
    if ($creationAttempted -or $deletionAttempted -or $resizeAttempted) {
        Write-Warning 'Partial disk changes may remain. Do not blindly rerun or delete any partition; inspect State.json and Operation.log.'
    }
} finally {
    # Each cleanup action is isolated so a log/letter error cannot prevent protection resumption.
    try { Remove-NewTemporaryAccess }
    catch {
        Write-Warning "Temporary drive-letter cleanup failed: $($_.Exception.Message)"
        if ($null -eq $failure) { $failure = $_ }
    }
    if ($suspendedBitLocker) {
        try {
            Invoke-BitLockerMethod $bitLockerVolume 'EnableKeyProtectors' | Out-Null
            if ((Invoke-BitLockerMethod $bitLockerVolume 'GetProtectionStatus').ProtectionStatus -ne 1) { throw 'BitLocker protection is not On.' }
            $script:state.BitLockerResumed = $true
            Write-Host 'Original BitLocker protection restored.'
        } catch {
            Write-Warning "BitLocker protection could not be resumed: $($_.Exception.Message)"
            if ($null -eq $failure) { $failure = $_ }
        }
    }
    if ($null -ne $script:workDir) {
        if ($null -ne $failure) {
            $script:state.Result = 'Stopped'
            if ($creationAttempted -or $deletionAttempted -or $resizeAttempted) { $script:state.Result = 'StoppedWithChanges' }
            $script:state.Failure = $failure.Exception.Message
        } elseif ($finished) { $script:state.Result = 'Complete' }
        try { Write-OperationState }
        catch {
            Write-Warning "Could not write final state: $($_.Exception.Message)"
            if ($null -eq $failure) { $failure = $_ }
        }
        Write-Host "Keep the recovery backup and operation log: $script:workDir"
    }
    if ($transcribing) {
        try { Stop-Transcript | Out-Null }
        catch { if ($null -eq $failure) { $failure = $_ } }
    }
    if ($mutexOwned -and $null -ne $mutex) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
if ($null -ne $failure) { throw $failure }
if ($finished) {
    Write-Host ('COMPLETE: C: {0:N2} GiB; gained {1:N2} GiB; WinRE configuration verified. No reboot initiated.' -f
        ($finalC.Size / 1GB), (($finalC.Size - $script:cIdentity.Size) / 1GB)) -ForegroundColor Green
    Write-Host 'WinRE bootability has not been tested. Keep the backup until a planned recovery boot test succeeds.'
    Get-Partition -DiskNumber $script:disk.Number | Sort-Object Offset |
        Format-Table PartitionNumber, DriveLetter, Type, @{N='GiB';E={[Math]::Round($_.Size / 1GB, 3)}}, Offset -AutoSize | Out-Host
    if ($PassThru) {
        [pscustomobject]@{ Status = 'Complete'; Placement = $plan.SelectedPlacement; CSizeBytes = [uint64]$finalC.Size
            GainedBytes = [uint64]($finalC.Size - $script:cIdentity.Size); BackupDirectory = $script:workDir
            WinREConfigurationVerified = $true; RebootInitiated = $false; BootTested = $false }
    }
}
