# Changelog

## 1.1.0-dev.2 - 2026-09-20

### Added

- A committed downstream `.repository-quality-gates.local.json` file can force applicable modules, preserve verified repository-owned module implementations, and add repository-specific Gitleaks policy layers.
- Legacy preserved-module settings migrate into the downstream-owned rules file on the first successful template update.
- Fleet update pull requests enable squash auto-merge and delete their version branch after downstream merge requirements pass.

### Changed

- Repository-owned adjustments are separated from RQG-managed files so later template versions can update without overwriting downstream rules.
- The central fleet workflow now requests automatic completion after every successful update preparation.

### Security

- Repository rules remain declarative and cannot execute commands or change GitHub permissions.
- Automatic merge remains governed by each downstream repository's required checks and branch rules.
- The GitHub App retains narrowly scoped Contents, Pull Requests, and Metadata permissions; Administration access is not required.

## 1.1.0-dev.1 - 2026-09-20

### Added

- A central fleet updater discovers repositories selected for a scoped GitHub App installation and opens update pull requests for outdated managed repositories.
- A single-repository updater previews or applies a newer template while preserving unmanaged files and stopping on modified managed files.
- Scheduled and release-triggered automation resolves the latest stable release before preparing repository updates.
- Synthetic update coverage verifies available, current, ahead, unmanaged, successful-update, and managed-conflict behavior.

### Security

- Cross-repository access uses a short-lived GitHub App installation token rather than a reusable personal access token.
- Automatic updates open pull requests and never merge them.
- The central fleet workflow is excluded from module-reconciliation redispatch.

## 1.0.1 - 2026-09-19

### Fixed

- Automatic module reconciliation now runs only for branch references.
- Tag pushes no longer start a reconciliation job that could attempt to commit and push against an immutable release tag.
- A second branch-reference condition protects manually evaluated reconciliation jobs from mutating tag checkouts.
- Post-reconciliation validation no longer redispatches the Module Drift workflow itself.
- Validation workflows are dispatched only when the staged Git index contains a reconciliation change set that was committed and pushed.

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
