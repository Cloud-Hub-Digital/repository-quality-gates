# Module System

`Invoke-RepositoryQualityGates.ps1` detects repository contents, selects applicable quality-gate modules, and prepares a deterministic deployment plan.

For operator instructions, see [Deployment Guide](deployment-guide.md). For the exact selection rules and workflow commands, see [Quality Gates](quality-gates.md).

## Included Modules

| Module | Detection | Deployed Check |
|---|---|---|
| `secret-scanning` | Every Git repository | Local hooks, verified Gitleaks scripts, portable policy, and GitHub Actions history scan |
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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-RepositoryQualityGates.ps1 -RepositoryPath "C:\Path\To\Repository"
```

Apply the reviewed plan:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-RepositoryQualityGates.ps1 -RepositoryPath "C:\Path\To\Repository" -Apply
```

Apply and commit after validation and the staged secret scan:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-RepositoryQualityGates.ps1 -RepositoryPath "C:\Path\To\Repository" -Apply -Commit
```

Apply, commit, scan the exact outgoing range, and push without force:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-RepositoryQualityGates.ps1 -RepositoryPath "C:\Path\To\Repository" -Apply -Commit -Push
```

Use `-OutputFormat Json` to obtain a machine-readable plan or result.

## Existing Repository Protection

The script classifies every target path before applying changes:

- `Add`: the target does not exist.
- `Unchanged`: the deployed content already matches.
- `Update`: the state file proves the existing managed file has not been changed locally.
- `Merge`: required ignore entries are missing and will be appended without replacing the file.
- `Conflict`: an unmanaged file exists at the target path or a managed file was modified locally.
- `Remove`: an unchanged, previously managed file is obsolete and `-PruneManaged` was explicitly supplied.

Conflicts stop deployment by default. After reviewing the JSON plan, `-ConflictAction BackupAndReplace` stores recovery copies beneath the target repository's private Git directory before replacement. These copies are local Git metadata and are not staged.

The script also reports workflows at other paths whose content appears to duplicate a selected module. Deployment stops until the overlap is resolved or `-AcknowledgeOverlap` is supplied. Existing files are never removed merely because an overlap was detected.

If a repository already has a reviewed implementation of a detected module, preserve it explicitly instead of replacing it:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-RepositoryQualityGates.ps1 -RepositoryPath "C:\Path\To\Repository" -PreserveExistingModule secret-scanning -Apply
```

Preservation is allowed only when an existing workflow contains a catalog overlap marker for that module. The existing files remain unmanaged and unchanged, the matching evidence appears in the JSON preview, and the decision is recorded in `.repository-quality-gates.json`. Reuse `-PreserveExistingModule` on later template runs.

If an existing `.gitignore` pattern matches a required managed file, the preview reports an exact negation such as `!/scripts/Test-Secrets.ps1`. Apply merges only those exact exceptions and then verifies every managed file is visible to Git. Deployment stops if a parent-directory rule still prevents a required file from being tracked.

`.repository-quality-gates.json` records only module identifiers, managed paths, and content hashes. It contains no personal policy data.

## Dirty Working Trees

Preview works with any working tree. Apply requires a clean tree unless `-AllowDirtyWorkingTree` is supplied. Commit and push always require that the repository was clean before deployment, preventing unrelated work from entering the generated commit.

## Local Private Policy And Hooks

Deploying files does not expose or copy the private publication-safety policy. Configure the private local policy and enable hooks with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-RepositoryQualityGates.ps1 -RepositoryPath "C:\Path\To\Repository" -Apply -ConfigureLocalHooks -PrivateConfigPath "C:\Protected\publication-safety.toml"
```

Hook configuration stops if another hooks path or active unmanaged Git hook already exists. Integrate the existing hooks deliberately before retrying.

## Managed Pruning

`-PruneManaged` considers only files listed in the previous state file. An unchanged obsolete managed file is backed up and removed. A locally modified obsolete file becomes a conflict and is retained. Unmanaged files are never pruned.

## Push Safeguards

Push requires an existing named remote, a branch checkout, a successful fetch, no remote commits missing locally, a verified scanner installation, a staged scan before commit, and an outgoing-range scan before push. The command never force-pushes.
