# Changelog

## 1.0.1 - 2026-09-19

### Fixed

- Automatic module reconciliation now runs only for branch references.
- Tag pushes no longer start a reconciliation job that could attempt to commit and push against an immutable release tag.
- A second branch-reference condition protects manually evaluated reconciliation jobs from mutating tag checkouts.
- Post-reconciliation validation no longer redispatches the Module Drift workflow itself.
- Validation workflows are dispatched only when a non-empty reconciliation change set was committed and pushed.

## 1.0.0 - 2026-09-19

### Added

- Automatic repository-content detection on pushes and manual workflow runs.
- Self-contained deployment engine and module catalogue in every managed repository.
- Automatic installation of newly required language modules.
- Automatic removal of unchanged obsolete modules.
- Pull-request reporting that shows module changes without mutating contributor branches.
- Regression coverage for Python-to-PHP transitions and repository reparse-point containment.

### Changed

- Module detection is shared by central deployment, local drift reporting, and automatic reconciliation.
- Reconciled commits dispatch the repository's validation workflows for the generated revision.
- PowerShell helper discovery prefers PowerShell 7 and falls back to Windows PowerShell.
- Documentation now separates read-only validation permissions from the privileged reconciliation job.

### Security

- Managed paths now reject symbolic links, junctions, and other reparse points before reading, writing, backing up, or pruning files.
- Automatic reconciliation still stops when a managed file was modified locally or another conflict requires review.
