# Pending cleanup exception design

The existing preflight treats every nonempty PendingFileRenameOperations value as
a blocker. A reported server has clear CBS and Windows Update restart indicators,
but queued deletions under Edge Temp, printer V4Dirs, and Config.Msi prevent an
otherwise supported relocation from reaching preview.

## Decision

Add the explicit switch -AllowPendingCleanup. The strict default remains.
The switch accepts only recognized deletion pairs in both PendingFileRenameOperations
and PendingFileRenameOperations2, while preserving both values and queued files.
The gate runs during preflight and again immediately before partition changes.
CBS/WU flags, malformed queues, unknown paths, and any nonempty destination remain
blocking. Raw *1/*2 markers are recognized as observed opaque prefixes only; the
tool does not execute or reinterpret their operating-system semantics.

## Approaches considered

- Unconditionally ignore the queue: too broad, loses evidence of unrelated updates.
- Remove queue entries: changes scheduled maintenance and is unnecessary.
- Opt into a narrow, read-only classification: selected implementation because it
  permits the reported cleanup case without changing the queue or the default.

## Accepted path shapes

Source uses the native prefix \??\ with optional leading *1 or *2.
After that prefix only absolute local drive paths are considered, with no dot
components, forward slashes, alternate streams, wildcard/control characters,
or trailing dots/spaces. Paths compare case-insensitively.

- EdgeCleanup: configured ProgramFiles root / Microsoft / Edge / Temp itself;
  its numeric_numeric or scoped_dirnumeric_numeric child; old_msedge.exe in that child.
- PrintDriverCleanup: configured Windows directory / System32 / spool / V4Dirs /
  canonical GUID directory itself; a direct hexadecimal-named .BUD/.gpd file; pdc.xml.
- InstallerRollbackCleanup: drive root / Config.Msi / hexadecimal-named .rbf file.

This recognizes the content of the queue, not overall machine health. It does not
prove that a driver update or installer has completed, promise recovery bootability,
or remove the need for the existing production backup and clone validation.

## Interfaces

Get-PendingFileOperationAssessment accepts SessionManager, WindowsDirectory, and
ProgramFilesDirectories. It returns OperationCount, AllowedCleanupCount, BlockedCount,
CanAllowCleanup, and Operations. Each operation retains ValueName, PairIndex, Source,
Destination, Category, AllowedCleanup, and Reason.

Assert-NoPendingMaintenance accepts AllowPendingCleanup and consumes this assessment.
Warnings identify accepted cleanup counts and explain that the queue is preserved.
Errors identify the offending value, pair and path with actionable reason.
