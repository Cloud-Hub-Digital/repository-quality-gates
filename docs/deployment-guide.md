# Deployment Guide

This guide applies Repository Quality Gates to a new or existing local Git repository using the prepared PowerShell deployment script.

For GitHub-hosted repositories, version `1.4.0` supports unattended initial enrolment across every account or organization where the RQG GitHub App is installed. Every unmanaged repository visible to any installation is eligible by default. To exclude one, commit `.repository-quality-gates.local.json` with `automaticEnrollment` set to `false`. The central daily workflow detects eligible repository contents, selects applicable modules, installs the RQG attribution notice, and enrols them through checked temporary pull requests. See [Automatic Repository Updates](automatic-repository-updates.md).

## Prerequisites

- PowerShell 7, with `pwsh` available on `PATH`.
- Git available on `PATH`.
- A local target directory that is already inside a Git repository.
- A clean working tree for commit or push operations.
- Network access when the verified Gitleaks installer or Git remote is used.
- A private publication-safety TOML file stored outside the target repository when local private-identifier scanning is required.

Keep the Repository Quality Gates source checkout separate from the target repository. Run its deployment script directly; do not manually copy the `template` directory when using the automated deployment method.

## Define Reusable Paths

Open PowerShell and set these variables for the current session:

```powershell
$Tool = "C:\Path\To\Repository Quality Gates\Source\scripts\Invoke-RepositoryQualityGates.ps1"
$Repo = "C:\Path\To\Target Repository"
$Policy = "C:\Protected\publication-safety.toml"
```

`$Policy` is local configuration. It must resolve to an existing file outside `$Repo` and must never be committed.

## Step 1: Confirm The Target Repository

```powershell
git -C "$Repo" status --short --branch
```

For an existing repository, fetch its remote state before rollout:

```powershell
git -C "$Repo" fetch --all --prune
```

Resolve, commit, or stash unrelated changes before using `-Commit` or `-Push`. Apply-only work can use `-AllowDirtyWorkingTree`, but this should be reserved for a deliberately reviewed case.

## Step 2: Preview The Plan

```powershell
pwsh -NoProfile -File "$Tool" -RepositoryPath "$Repo"
```

Preview is read-only. Review:

- selected modules;
- each `Add`, `Unchanged`, `Update`, `Merge`, `Conflict`, `Retain`, or `Remove` action;
- target paths and reasons;
- existing-workflow overlap warnings;
- proposed `.gitignore` additions.

Use JSON when a complete machine-readable plan is easier to inspect:

```powershell
pwsh -NoProfile -File "$Tool" -RepositoryPath "$Repo" -OutputFormat Json
```

The JSON result contains the repository path, mode, detected modules, managed modules, preserved modules, preservation evidence, exact managed-file unignore rules, file plan, workflow overlaps, recovery path when created, commit ID when created, and push result.

## Step 3: Resolve Conflicts And Overlaps

### Unmanaged Or Locally Modified Target Files

The default `-ConflictAction Stop` blocks apply. Inspect the conflicting file and compare it with the proposed module payload.

After deciding that the template should replace it, apply with a recovery copy:

```powershell
pwsh -NoProfile -File "$Tool" -RepositoryPath "$Repo" -Apply -ConflictAction BackupAndReplace
```

The replaced file is copied beneath the target repository's private Git directory in `rqg-backups\<timestamp>`. This recovery directory is local Git metadata and is not staged.

### Existing Equivalent Module

If an existing workflow already provides a reviewed implementation, record that decision in the downstream repository's committed `.repository-quality-gates.local.json` file:

```json
{
  "schemaVersion": 1,
  "modules": {
    "include": [],
    "repositoryOwned": ["documentation"]
  },
  "secretScanning": {
    "additionalConfigFiles": []
  }
}
```

Replace `documentation` with the applicable non-universal module ID and commit the file to that downstream repository. The command succeeds only when the module is detected or included and an existing workflow contains matching catalog evidence. The universal `secret-scanning` and `module-drift` modules must remain centrally managed and cannot appear in `repositoryOwned`. The deployment tool still accepts `-PreserveExistingModule` for one-off and compatibility use, but automatic updates use the committed repository-owned file.

### Intentional Duplicate Workflows

When both the existing and template workflows should remain, acknowledge the reviewed overlap:

```powershell
pwsh -NoProfile -File "$Tool" -RepositoryPath "$Repo" -Apply -AcknowledgeOverlap
```

Do not use this switch merely to bypass an unexplained warning.

## Step 4: Apply And Configure Local Hooks

```powershell
pwsh -NoProfile -File "$Tool" -RepositoryPath "$Repo" -Apply -ConfigureLocalHooks -PrivateConfigPath "$Policy"
```

This command:

1. validates existing PowerShell source before mutation;
2. applies only the reviewed plan;
3. creates recovery copies when required;
4. merges required `.gitignore` lines without replacing the file;
5. verifies managed files are not still ignored;
6. writes `.repository-quality-gates.json` using UTF-8 without a BOM and LF line endings;
7. downloads and checksum-verifies the pinned Gitleaks binary;
8. stores the external policy path in local Git configuration;
9. checks for an existing hooks path or active unmanaged hooks;
10. runs the staged secret scan before setting `core.hooksPath=.githooks`;
11. runs a working-tree scan using both public and private policy layers.

The downloaded scanner is stored under `.tools` and excluded from Git. The private policy is referenced, never copied.

If another `core.hooksPath` or active unmanaged hook already exists, configuration stops. Integrate the existing and template hook behavior deliberately before retrying.

## Step 5: Run Baseline Validation

From the target repository, run:

```powershell
pwsh -NoProfile -File "$Repo\scripts\Test-Secrets.ps1" -Mode WorkingTree
```

```powershell
pwsh -NoProfile -File "$Repo\scripts\Test-Secrets.ps1" -Mode History
```

```powershell
pwsh -NoProfile -File "$Repo\scripts\Test-DetectionPolicy.ps1"
```

Then run the target repository's own build, tests, static analysis, packaging checks, and any required isolated UI or hardware tests. The deployed workflows establish a baseline; they do not replace product-specific validation.

The full-history scan requires a complete non-shallow repository. Fetch missing history before retrying.

## Step 6: Review The Applied Change

```powershell
git -C "$Repo" status --short
```

```powershell
git -C "$Repo" diff --check
```

```powershell
git -C "$Repo" diff --stat
```

```powershell
git -C "$Repo" diff
```

Confirm that only expected quality-gate files, the managed-state file, and the reviewed `.gitignore` additions are present. Confirm that no private policy file, scanner binary, recovery copy, unrelated source edit, personal identifier, internal path, credential, or generated output is included.

## Step 7: Commit Through The Deployment Script

The deployment script can apply and commit in one controlled operation, but commit requires the repository to have been clean before deployment. If Step 4 already applied changes, review and commit those changes manually or restore the clean baseline and rerun with `-Commit`; do not rerun `-Commit` over pre-existing deployment changes.

For a clean repository, preview first, then run:

```powershell
pwsh -NoProfile -File "$Tool" -RepositoryPath "$Repo" -Apply -ConfigureLocalHooks -PrivateConfigPath "$Policy" -Commit -CommitMessage "Add repository quality gates"
```

Before creating the commit, the script installs/verifies Gitleaks, stages only planned deployment paths plus `.repository-quality-gates.json`, runs the staged scan, rejects unexpected staged paths, and refuses an empty deployment commit.

## Step 8: Push Through The Deployment Script

Push is optional and consequential. Use it only after reviewing the exact commit and confirming the remote and branch.

For a clean repository where the deployment has not already been applied or committed:

```powershell
pwsh -NoProfile -File "$Tool" -RepositoryPath "$Repo" -Apply -ConfigureLocalHooks -PrivateConfigPath "$Policy" -Commit -Push -CommitMessage "Add repository quality gates" -Remote origin
```

The script requires a named remote and an attached branch, fetches and prunes the remote, refuses to push when the local branch is behind, scans the exact outgoing commit range, and uses a normal non-force push with upstream tracking.

## Step 9: Verify GitHub Actions

After push, confirm that every selected workflow completes successfully. The expected workflow names are listed in [Quality Gates](quality-gates.md).

Confirm that `Quality Gate Module Drift` reports the repository as current. Pull requests report detected differences without failing. A push or manual run automatically adds missing modules, removes unchanged obsolete modules, validates the result, creates a managed reconciliation commit when needed, pushes it, and dispatches the managed workflows against the reconciled branch.

Where repository rules are available, require the applicable checks before changes can enter the default branch. Use the job/check names shown by the first successful workflow runs.

## Updating A Managed Repository

Run preview again using the newer template checkout:

```powershell
pwsh -NoProfile -File "$Tool" -RepositoryPath "$Repo" -OutputFormat Json
```

The state file records managed modules, paths, and SHA-256 hashes:

- unchanged managed files can be updated safely;
- locally modified managed files become conflicts;
- unmanaged files are never silently replaced;
- local preview and apply retain obsolete modules unless pruning is explicitly requested;
- the GitHub reconciliation workflow automatically uses pruning on trusted writable branches;
- missing applicable modules are installed automatically by the GitHub reconciliation workflow.

Run the deployed checker locally at any time:

```powershell
pwsh -NoProfile -File "$Repo\scripts\Test-QualityGateModuleDrift.ps1" -RepositoryPath "$Repo"
```

Apply reviewed updates with the same apply, validate, review, commit, and push sequence used for initial deployment.

## Pruning Obsolete Managed Files

Preview pruning first:

```powershell
pwsh -NoProfile -File "$Tool" -RepositoryPath "$Repo" -PruneManaged -OutputFormat Json
```

Apply only after reviewing every `Remove` action:

```powershell
pwsh -NoProfile -File "$Tool" -RepositoryPath "$Repo" -Apply -PruneManaged
```

Only unchanged files recorded in the previous managed state can be removed. A modified obsolete file becomes a conflict and is retained. Every local removal is backed up beneath the private Git directory. The GitHub reconciliation workflow supplies `-PruneManaged` automatically from a clean checkout.

## Automatic Reconciliation Requirements

The deployed workflow requests `contents: write` only for its reconciliation job and `actions: write` only to dispatch validation workflows after a generated commit. Pull-request reporting retains read-only contents access.

The repository must permit GitHub Actions to write repository contents, and branch protection must allow the generated commit. Fork and Dependabot pull requests normally receive read-only tokens; they remain report-only until the change is pushed or merged onto a writable branch. If a managed file was edited outside the template, reconciliation stops rather than overwriting it.

## Parameter Reference

| Parameter | Purpose |
|---|---|
| `-RepositoryPath` | Required path inside the target Git repository |
| `-CatalogPath` | Optional alternate module catalog; defaults to this template's `modules/catalog.json` |
| `-Apply` | Execute the reviewed plan; omission means preview only |
| `-Commit` | Stage only deployment paths, scan staged content, and commit; requires `-Apply` |
| `-Push` | Scan and push the resulting commit; requires `-Commit` and `-Apply` |
| `-PruneManaged` | Plan removal of obsolete unchanged managed files |
| `-IncludeModule` | One-off inclusion of a catalogue module; use `.repository-quality-gates.local.json` for persistent automatic updates |
| `-PreserveExistingModule` | One-off preservation of a detected module's verified existing workflow; use `.repository-quality-gates.local.json` for persistent automatic updates |
| `-AllowDirtyWorkingTree` | Permit apply-only changes over a pre-existing dirty tree; never permits commit or push |
| `-AcknowledgeOverlap` | Permit reviewed existing and managed workflows to coexist |
| `-ConfigureLocalHooks` | Install/verify Gitleaks, record the private policy path, and enable repository hooks; requires `-Apply` and `-PrivateConfigPath` |
| `-PrivateConfigPath` | External private publication-safety TOML used by local scans |
| `-ConflictAction` | `Stop` by default; `BackupAndReplace` after reviewed replacement approval |
| `-CommitMessage` | Commit message used with `-Commit`; default is `chore: configure repository quality gates` |
| `-Remote` | Remote used with `-Push`; default is `origin` |
| `-OutputFormat` | `Text` or `Json` |

## Action Meanings

| Action | Meaning |
|---|---|
| `Add` | Target file does not exist |
| `Unchanged` | Target already matches the selected payload |
| `Update` | State proves the managed file is locally unchanged and a newer payload is available |
| `Merge` | Required `.gitignore` entries or exact unignore entries are missing |
| `Conflict` | An unmanaged target exists, a managed file was locally changed, or an obsolete managed file was changed |
| `Retain` | A previously managed module is no longer detected and remains tracked until reviewed pruning |
| `Remove` | `-PruneManaged` selected an unchanged obsolete managed file |

## Troubleshooting

### Repository Contains Pre-Existing Changes

Commit or stash unrelated work. `-AllowDirtyWorkingTree` is apply-only and still requires careful diff review.

### Required Managed Files Remain Ignored

The script adds exact `!/path` exceptions when possible. A parent-directory ignore rule may still prevent tracking. Adjust the repository's ignore rules deliberately and preview again.

### Existing Hooks Block Configuration

Inspect `git -C "$Repo" config --get core.hooksPath` and the repository's current Git hooks. Combine required behaviors rather than replacing an active hook without review.

### Full-History Scan Rejects A Shallow Repository

Fetch complete history from the correct remote, then rerun the history scan.

### Scanner Integrity Check Fails

Delete only the repository's `.tools\gitleaks` directory and rerun `scripts\Install-Gitleaks.ps1`. Do not bypass checksum verification.

### A Secret Scan Reports A Finding

Stop publication. Review the redacted rule, file, and line. Remove or rotate genuine credentials as appropriate. If the value exists in Git history, changing the current file is insufficient; history remediation requires a separate reviewed recovery plan.

### A Known Synthetic Fixture Is Detected

Add a narrowly reviewed project exception only when required. Bind it to the exact synthetic value and exact file. Never allowlist a real secret or broad path.
