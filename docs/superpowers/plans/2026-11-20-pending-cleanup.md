# Pending cleanup exception implementation plan

> **For agentic workers:** Use the executing-plans or subagent-driven-development workflow. Steps use checkboxes to track verification.

**Goal:** Permit an explicit exception for recognized queued deletions without weakening unrelated maintenance gates.

**Architecture:** Add a pure queue classifier and call it from the existing maintenance guard. Keep mutation code unchanged and pass the new switch on both guard invocations.

**Tech Stack:** Standalone Windows PowerShell 5.1; existing Linux/Windows GitHub Actions helper suites.

**Spec:** ../specs/2026-11-20-pending-cleanup.md

## Global constraints

- Preview is read-only; no queue edits, file deletions, or reboot.
- Default remains strict; -AllowPendingCleanup is explicit.
- Preserve Windows PowerShell 5.1 syntax and the single-file script distribution.
- Preserve all partition identities and the create-before-delete workflow.

## Review focus

- Empty destinations must remain present during pairing.
- Unknown * prefixes, malformed raw types and odd arrays must fail closed.
- A familiar parent path must not accept traversal, ADS or lookalike directories.
- A changed queue at the second gate must be evaluated afresh.
- Clearing CBS/WU flags alone must not imply machine health.

## Task 1: Classifier and integration

Files: Move-WinRE-ExtendC.ps1; qa/Test-WinREPendingMaintenance.ps1; qa/Run-Tests.ps1.

- [ ] Write and observe a failing opt-in cleanup gate test against v3.0.1.
- [ ] Implement Get-PendingFileOperationAssessment with the documented return contract.
- [ ] Add AllowPendingCleanup to the public parameters and both gate calls.
- [ ] Test accepted categories, mixed queues, malformed values, unknown prefixes,
      unsafe paths, replacements, default refusal, hard servicing blockers and rechecks.
- [ ] Run the complete existing suite plus the new suite locally and on Windows PowerShell 5.1.
- [ ] Review the implementation independently.

## Task 2: Documentation and delivery

Files: README.md; RELEASE_NOTES.md; docs/OPERATIONS.txt; docs/VALIDATION.txt.

- [ ] Document explicit preview/apply commands, path boundaries and remaining validation limits.
- [ ] Record actual CI results, publish the tested commit and tag v3.0.2.
- [ ] Attach standalone script, full ZIP and SHA256SUMS.txt to the release.
- [ ] Verify GitHub asset digests and provide the corrected download link.
