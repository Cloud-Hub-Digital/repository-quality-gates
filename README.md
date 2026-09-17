# Repository Quality Gates

Repository Quality Gates is a preview-first PowerShell deployment tool for adding a consistent validation baseline to Git repositories. It inspects a target repository, selects only the applicable modules, reports every proposed file operation, and can then apply, validate, commit, and push the reviewed result in separate controlled stages.

The current template version written to managed state is `0.1.0-dev`. It is development source and has not yet been published as a formal release.

## What It Provides

Every target repository receives the universal secret-scanning module. Additional modules are selected from the repository's tracked and unignored source files:

| Module | Selected When | Main GitHub Actions Gate |
|---|---|---|
| Secret Scanning | Always | Full-history Gitleaks scan and synthetic policy tests |
| PowerShell | A `.ps1`, `.psm1`, or `.psd1` file exists | PowerShell parser validation |
| .NET | A `.sln`, `.slnx`, `.csproj`, `.fsproj`, or `.vbproj` file exists | Restore, Release build, and headless tests |
| Node | `package.json` or a `.js`, `.mjs`, or `.cjs` file exists | JavaScript syntax; reproducible npm checks when packaged; dependency-free `tests/test.js` when present |
| Python | A Python project marker or `.py` file exists | Dependency/project installation, bytecode compilation, and tests when a `tests` directory exists |
| PHP | `composer.json` or a `.php` file exists | PHP syntax, Composer validation/install, and optional Composer tests |
| Shell | A `.sh` or `.bash` file exists | `bash -n` syntax validation |
| PlatformIO | `platformio.ini` exists | Pinned PlatformIO firmware build |
| Documentation | A `.md` or `.markdown` file exists | Markdown trailing-whitespace check |

See [Quality Gates](docs/quality-gates.md) for the exact selection rules, commands, runners, triggers, permissions, exclusions, and limitations for every module.

See [Automation Costs And Release Strategy](docs/automation-costs-and-releases.md) for current GitHub Actions cost boundaries and the recommended staged approach to automated builds and releases.

## Start Here

1. Read the [Deployment Guide](docs/deployment-guide.md).
2. Run a preview against the target repository:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Invoke-RepositoryQualityGates.ps1" -RepositoryPath "C:\Path\To\Repository"
   ```

3. Review the selected modules, planned actions, conflicts, existing-workflow overlaps, and `.gitignore` changes.
4. Apply the reviewed plan and configure the local private policy:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Invoke-RepositoryQualityGates.ps1" -RepositoryPath "C:\Path\To\Repository" -Apply -ConfigureLocalHooks -PrivateConfigPath "C:\Protected\publication-safety.toml"
   ```

5. Run the target repository's project tests and review the complete Git diff.
6. Use `-Commit` and `-Push` only after the exact outgoing change has been reviewed and authorized.

The deployment guide includes complete commands for preview, JSON review, apply-only rollout, local hook configuration, conflict recovery, preserving existing checks, managed pruning, commit, push, updates, and troubleshooting.

## Safety Model

- Preview is the default and changes nothing.
- Apply stops on unmanaged target-path conflicts by default.
- Existing managed files are updated only when their recorded hash proves they were not changed locally.
- Replacements and removals are copied beneath the target repository's private Git directory before mutation.
- Existing workflows that appear to duplicate a selected module block apply until reviewed.
- Commit and push require a clean repository before deployment, preventing unrelated work from entering the generated commit.
- Commit stages only the deployment plan and managed-state file, then runs the staged secret scan.
- Push fetches the remote, rejects a branch that is behind, scans the exact outgoing commit range, and never force-pushes.
- Private identifier policies stay outside every repository and are referenced only through local Git configuration.

See [Module System](docs/module-system.md) for state tracking, file classification, conflict behavior, recovery copies, preservation, pruning, and push safeguards.

## Repository Contents

| Path | Purpose |
|---|---|
| `scripts/Invoke-RepositoryQualityGates.ps1` | Preview-first detector and deployment entry point |
| `modules/catalog.json` | Module definitions, detection rules, payload sources, and overlap markers |
| `modules/*/payload` | Module-specific files copied into applicable repositories |
| `template` | Universal secret-scanning module |
| `tests/Invoke-RepositoryQualityGates.Tests.ps1` | Synthetic regression suite for selection, deployment, conflict, recovery, preservation, and idempotence behavior |
| `docs/quality-gates.md` | Detailed gate and module-selection reference |
| `docs/deployment-guide.md` | End-to-end operator instructions |
| `docs/module-system.md` | Architecture and managed-file lifecycle reference |
| `docs/automation-costs-and-releases.md` | GitHub Actions cost boundary and recommended build/release automation controls |

## Private Policy Boundary

The universal module deploys only public, portable rules. Personal identifiers, private domains, internal paths, hostnames, and other private publication rules must remain in a protected file outside every repository.

Never add a private identifier source file or generated private policy to repository files, Git history, GitHub Actions secrets, variables, artifacts, caches, or logs. Local scripts obtain the policy path from the `publicationSafety.privateConfig` repository-local Git setting.

## Validation

Run the template regression suite from this repository:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\tests\Invoke-RepositoryQualityGates.Tests.ps1"
```

The current suite contains 58 assertions and uses generated synthetic repositories only. It does not use real credentials or private identifier values.
