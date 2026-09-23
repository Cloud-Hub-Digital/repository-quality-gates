# Changelog

## 1.5.0 - 2026-09-23

### Added

- Added opt-in Windows and Linux self-hosted runner routing through GitHub Actions configuration variables, with GitHub-hosted fallbacks.

### Security

- Forced pull requests from forks onto GitHub-hosted runners so untrusted fork code cannot execute on privately operated machines.
- Forced public repositories onto GitHub-hosted runners even when a self-hosted routing variable is present.
- Documented organization and personal-account runner boundaries, repository-specific label requirements, variable formats, and least-privilege operating guidance.

### Fixed

- Allowed managed-state refreshes on filesystems that represent the dot-prefixed state file with a hidden attribute, while preserving that attribute.
- Treated repository locations as literal paths during layered secret scans so folder names containing wildcard characters remain supported.

## 1.4.1 - 2026-09-21

### Changed

- Continue processing later GitHub App installations when one installation fails, then fail the completed fleet run with an aggregate installation count.
- Defer empty GitHub repositories until their first commit makes a default branch available.

### Fixed

- Treat an empty GitHub CLI pull-request lookup as no matching pull request instead of calling a method on a null value.
- Migrate legacy repository-owned secret-scanning modules only when their historical RQG files match verified release hashes.
- Preserve a customized root `.gitleaks.toml` as a repository-owned path during legacy migration when it continues to extend the central portable policy, while returning the remaining secret-scanning payload to central management.

### Security

- Restrict historical managed-file adoption to exact known SHA-256 hashes and fail closed for unknown or modified legacy files.

## 1.4.0 - 2026-09-21

### Changed

- Require PowerShell 7 and use `pwsh` consistently in GitHub Actions, generated Git hooks, deployment and reconciliation child processes, regression tests, and documented commands.
- Remove the Windows PowerShell 5.1 fallback from the supported deployment and automatic update path so local and hosted execution use the same PowerShell edition.

### Fixed

- Resolve the selected GitHub Release against the explicit central repository so a dispatched fleet run does not depend on a local checkout that has not happened yet.
- Preserve the command-scoped execution-policy override in generated `pwsh` Git hooks so secret checks run when a trusted repository is reached through a Windows network mapping.

## 1.3.1 - 2026-09-21

### Fixed

- Supply each short-lived GitHub App installation token to Git through an installation-specific HTTPS authorization header so prepared update branches can be fetched, pushed, and cleaned up without an interactive credential prompt.
- Explicitly dispatch the downstream fleet workflow after automatic release creation because GitHub suppresses most workflow events created by `GITHUB_TOKEN`.
- Bind release-triggered fleet runs to the exact published stable tag, while retaining latest-release resolution for scheduled and unpinned manual recovery runs.
- Normalize release-check JSON arrays when running under Windows PowerShell 5.1 so valid workflow results are evaluated individually.

### Security

- Pass the Git authorization header through temporary process environment configuration instead of command-line arguments, mask the token and header in Actions logs, isolate credentials per installation, and restore the caller's Git environment after the run.

## 1.3.0 - 2026-09-21

### Added

- Added central automatic stable release creation for the exact current `main` commit after all five required RQG workflows succeed.
- Added deterministic release planning and regression coverage for version consistency, changelog presence, stale commits, failed checks, existing releases, recoverable missing releases, and tag collisions.

### Changed

- Stable `main` versions now create an annotated semantic-version tag and immutable GitHub Release automatically; publishing that release starts the existing downstream fleet update.
- Corrected GitHub App installation discovery so PowerShell normalizes a top-level JSON array before processing each installation separately.
- Corrected push-event source resolution so only manual API lookups evaluate an external-process exit status.
- Reset the release-planning step's process result after expected missing-tag and missing-release probes so a valid new release plan can continue.

### Security

- Release automation uses only `actions: read` and `contents: write`, binds every required result to its exact workflow path and display name, rechecks the remote `main` commit immediately before tagging, and refuses to move or reuse an existing version tag.

## 1.2.0 - 2026-09-20

### Added

- Added a repository-administration guide covering GitHub secret protection, dependency security, Actions restrictions, branch and tag rulesets, community files, and automation compatibility.
- Added weekly grouped Dependabot updates for GitHub Actions, limited to two open pull requests.

### Changed

- Clarified that the downstream MIT notice applies only to `.repository-quality-gates.json` and the RQG-managed files recorded in its `files` array.
- Clarified that licensing, secret scanning, and module drift are the three universal modules installed in every managed repository.
- Recorded the GitHub settings established for the central repository, including Actions restrictions, 30-day retention, merged-branch cleanup, immutable releases, and active branch and release-tag rulesets.

### Security

- Documented a staged settings baseline that improves repository protection without blocking the current direct-push self-reconciliation workflow.

## 1.2.0-dev.3 - 2026-09-20

### Added

- Added the MIT license and a root security policy with private reporting guidance, threat boundaries, security invariants, reportable findings, exclusions, and safe-testing expectations.
- Added an always-selected licensing module that installs `LICENSES/Repository-Quality-Gates-MIT.txt` in downstream repositories without changing the downstream project's own licence.
- Added SPDX MIT identifiers to Repository Quality Gates PowerShell source and test files.

### Security

- Documented installation-token isolation, credential and private-policy handling, repository opt-out, open-pull-request deferral, path containment, fail-closed conflicts, required checks, and temporary-branch cleanup as security invariants.

## 1.2.0-dev.2 - 2026-09-20

### Added

- Added a privacy-preserving cross-owner wrapper that discovers every installation of the RQG GitHub App and dispatches the existing fleet updater for each installation.
- Added synthetic RS256 JWT, installation-token isolation, repository-scope, and argument-forwarding coverage.

### Changed

- The central fleet workflow now manages all App installations rather than limiting discovery to the central repository owner.
- Explicit repository lists can be processed without resolving a user identity from the GitHub API.

### Security

- Each App installation receives a separate short-lived token that is revoked after use and cannot access another installation's repositories.
- Discovered owner and full repository names are masked before repository processing emits workflow log output.
- No personal owner identifier or cross-account repository inventory is stored in public source, Actions variables, or secrets.

## 1.2.0-dev.1 - 2026-09-20

- Added automatic enrolment for unmanaged repositories visible to the scoped GitHub App.
- Added the repository-owned `automaticEnrollment: false` opt-out in `.repository-quality-gates.local.json`; absence defaults to enrolment.
- Reused the temporary branch, open-pull-request deferral, validation, auto-merge, and cleanup controls for initial enrolment.
- Require exact branch, base, repository-origin, and provenance-marker evidence before expired RQG pull requests are removed.
- Reject repository-owned replacement of the universal secret-scanning and module-drift modules.
- Added an explicit `-Enroll` mode to the single-repository updater while preserving the default skip for unmanaged repositories.
- Prevented unattended initial enrolment from silently accepting undeclared workflow overlaps.
- Enabled the daily fleet workflow to discover and enrol new repositories automatically unless they explicitly opt out.
- Updated the authoritative product-repository link after ownership transferred to the Cloud Hub organization.

## 1.1.0 - 2026-09-20

### Added

- A scoped GitHub App can distribute each stable RQG release to its selected managed repositories.
- Committed downstream rules preserve repository-owned module substitutions, forced modules, and repository-specific Gitleaks policy layers outside RQG management.
- Validated downstream updates can use required-check-gated auto-merge from temporary versioned branches.

### Changed

- Repositories with any open pull request are deferred until the next daily or manual fleet run.
- Temporary RQG branches are deleted after merge or setup failure and expire after 24 hours when unresolved.

### Security

- Cross-repository access uses a short-lived, narrowly scoped GitHub App installation token.
- The updater checks pull-request eligibility before preparation and immediately before its first push.
- Modified managed files, invalid downstream rules, conflicts, failed checks, and missing merge safeguards stop automatic completion.

## 1.1.0-dev.3 - 2026-09-20

### Changed

- The fleet updater defers an outdated downstream repository whenever any pull request is open in that repository.
- Deferred repositories are checked again by the daily fallback or a manual fleet run after every pull request is closed or merged.
- Temporary RQG branches are deleted after successful merge, removed immediately after post-push setup failures, and expire with their RQG pull request after 24 hours.

### Security

- RQG does not create, update, push, or auto-merge an update branch while another pull request is open.
- The updater checks again immediately before its first push so a pull request opened during preparation does not leave a remote RQG branch.
- Fleet results identify the blocking pull requests so deferred repositories remain visible without competing with active development.

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
