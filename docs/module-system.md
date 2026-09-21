# Module System

`Invoke-RepositoryQualityGates.ps1` detects repository contents, selects applicable quality-gate modules, and prepares a deterministic deployment plan.

For operator instructions, see [Deployment Guide](deployment-guide.md). For the exact selection rules and workflow commands, see [Quality Gates](quality-gates.md).

## Included Modules

| Module | Detection | Deployed Check |
|---|---|---|
| `licensing` | Every Git repository | Installs the MIT notice for the RQG-managed components without changing the repository's own licence |
| `secret-scanning` | Every Git repository | Local hooks, verified Gitleaks scripts, portable policy, and GitHub Actions history scan |
| `module-drift` | Every Git repository | Automatic addition of missing modules and removal of unchanged obsolete modules on trusted writable branches |
| `powershell` | `.ps1`, `.psm1`, or `.psd1` | Parser validation on Windows |
| `dotnet` | `.sln`, `.slnx`, `.csproj`, `.fsproj`, or `.vbproj` | Restore, Release build, and headless tests on Windows |
| `node` | `package.json`, `.js`, `.mjs`, or `.cjs` | JavaScript syntax; reproducible npm checks when packaged; dependency-free `tests/test.js` when present |
| `python` | Python source, packaging, or runtime/development dependency file | Installation when configured, bytecode compilation, and pytest or unittest discovery when a test directory exists |
| `php` | PHP source or `composer.json` | PHP syntax validation plus Composer validation, installation, and tests when configured |
| `shell` | `.sh` or `.bash` | Bash syntax validation on tracked shell scripts |
| `platformio` | `platformio.ini` | Pinned PlatformIO firmware build |
| `go` | `go.mod` or `go.work` | Formatting, `go vet`, tests, and package builds |
| `documentation` | Markdown files | Trailing-whitespace hygiene check |

The table is a summary. `modules/catalog.json` is authoritative for detection and overlap markers, while each module payload is authoritative for its deployed workflow.

Detection ignores generated dependency and build directories. The catalog is stored in `modules/catalog.json`; each module has an isolated `payload` directory whose contents map to repository-relative target paths.

## Safe Execution Stages

Preview is the default and does not modify the target:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-RepositoryQualityGates.ps1 -RepositoryPath "C:\Path\To\Repository"
```

Apply the reviewed plan:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-RepositoryQualityGates.ps1 -RepositoryPath "C:\Path\To\Repository" -Apply
```

Apply and commit after validation and the staged secret scan:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-RepositoryQualityGates.ps1 -RepositoryPath "C:\Path\To\Repository" -Apply -Commit
```

Apply, commit, scan the exact outgoing range, and push without force:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-RepositoryQualityGates.ps1 -RepositoryPath "C:\Path\To\Repository" -Apply -Commit -Push
```

Use `-OutputFormat Json` to obtain a machine-readable plan or result.

## Existing Repository Protection

The script classifies every target path before applying changes:

- `Add`: the target does not exist.
- `Unchanged`: the deployed content already matches.
- `Update`: the state file proves the existing managed file has not been changed locally.
- `Merge`: required ignore entries are missing and will be appended without replacing the file.
- `Conflict`: an unmanaged file exists at the target path or a managed file was modified locally.
- `Retain`: a previously managed file belongs to a module that is no longer detected and remains tracked until reviewed pruning.
- `Remove`: an unchanged, previously managed file is obsolete and `-PruneManaged` was explicitly supplied.

Conflicts stop deployment by default. After reviewing the JSON plan, `-ConflictAction BackupAndReplace` stores recovery copies beneath the target repository's private Git directory before replacement. These copies are local Git metadata and are not staged.

The script also reports workflows at other paths whose content appears to duplicate a selected module. Deployment stops until the overlap is resolved or `-AcknowledgeOverlap` is supplied. Existing files are never removed merely because an overlap was detected.

If a repository already has a reviewed implementation of a detected module, preserve it in the downstream repository's committed rules file instead of changing an RQG-managed file:

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

Preservation is allowed only for non-universal modules when an existing workflow contains a catalog overlap marker for that module. The universal `licensing`, `secret-scanning`, and `module-drift` modules always remain RQG-managed. Other existing module files remain unmanaged and unchanged, and the matching evidence appears in the JSON preview. `.repository-quality-gates.local.json` remains owned by the downstream repository and is never copied or replaced by RQG. The managed `.repository-quality-gates.json` file records the resolved snapshot for drift checking.

The `licensing` module writes `LICENSES/Repository-Quality-Gates-MIT.txt`. It attributes only the RQG files copied into the repository and does not select, replace, or modify the downstream project's own licence.

If an existing `.gitignore` pattern matches a required managed file, the preview reports an exact negation such as `!/scripts/Test-Secrets.ps1`. Apply merges only those exact exceptions and then verifies every managed file is visible to Git. Deployment stops if a parent-directory rule still prevents a required file from being tracked.

`.repository-quality-gates.json` records only module identifiers, managed paths, and content hashes. It contains no personal policy data. Repository-specific public secret patterns belong in a separate committed TOML file named by `secretScanning.additionalConfigFiles`; private identifier policies remain outside the repository.

## Automatic Module Reconciliation

Every managed repository receives `Quality Gate Module Drift`, a self-contained copy of the deployment engine, and every module payload. It does not need access to the private central template repository. On each push, pull request, or manual run, it uses the same shared detector and catalog as the deployment tool to compare:

- modules required by the repository's current tracked and unignored files; and
- modules recorded as managed in `.repository-quality-gates.json` or declared repository-owned in `.repository-quality-gates.local.json`.

A pull request performs a report-only comparison and does not fail merely because modules differ. The corresponding branch push performs reconciliation when GitHub supplies a trusted writable token.

Reconciliation adds every newly required module and removes every unchanged managed file belonging to an obsolete module. It runs the public working-tree, staged, and synthetic secret-policy checks, creates a `chore: reconcile repository quality gates` commit as `github-actions[bot]`, and pushes it to the same branch. It then dispatches the managed workflows against that reconciled branch. For example, a Python-to-PHP conversion adds the PHP workflow and removes the unchanged Python workflow automatically.

The workflow never overwrites a locally modified managed file and never removes unmanaged files. Such a conflict stops reconciliation for review. Explicitly preserved external module implementations remain unmanaged and unchanged. Pull requests from forks and Dependabot normally receive a read-only token; they report drift, and reconciliation occurs after the change reaches a writable branch. Repository branch protection must permit the GitHub Actions token to push the generated reconciliation commit.

## Dirty Working Trees

Preview works with any working tree. Apply requires a clean tree unless `-AllowDirtyWorkingTree` is supplied. Commit and push always require that the repository was clean before deployment, preventing unrelated work from entering the generated commit.

## Local Private Policy And Hooks

Deploying files does not expose or copy the private publication-safety policy. Configure the private local policy and enable hooks with:

```powershell
pwsh -NoProfile -File .\scripts\Invoke-RepositoryQualityGates.ps1 -RepositoryPath "C:\Path\To\Repository" -Apply -ConfigureLocalHooks -PrivateConfigPath "C:\Protected\publication-safety.toml"
```

Hook configuration stops if another hooks path or active unmanaged Git hook already exists. Integrate the existing hooks deliberately before retrying.

## Managed Pruning

Without `-PruneManaged`, obsolete managed files and their state entries are retained and reported as stale. With `-PruneManaged`, an unchanged obsolete managed file is backed up and removed. A locally modified obsolete file becomes a conflict and is retained. Unmanaged files are never pruned.

## Push Safeguards

Push requires an existing named remote, a branch checkout, a successful fetch, no remote commits missing locally, a verified scanner installation, a staged scan before commit, and an outgoing-range scan before push. The command never force-pushes.
