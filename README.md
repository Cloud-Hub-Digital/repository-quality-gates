# Repository Quality Gates

Repository Quality Gates is a preview-first PowerShell deployment tool for adding a consistent validation baseline to Git repositories. It inspects a target repository, selects only the applicable modules, reports every proposed file operation, and can then apply, validate, commit, and push the reviewed result in separate controlled stages.

The prepared template version written to managed state is `1.5.7`. The automatic release workflow publishes the matching immutable `v1.5.7` GitHub Release after the required checks pass for the release commit.

Version `1.5.7` refreshes GitHub App authentication before every installation so a long-running personal-repository rollout cannot prevent the later organization repositories from being reported. It retains the `1.5.6` repository-specific runner reporting, sanitized diagnostics, status-count summary, and fully bordered Repository, Visibility, Runner, Status, and Comment table. Comments remain short factual summaries; complete sanitized diagnostics remain in the private workspace report used to produce the email. The downloadable one-day diagnostic artifact remains separately sanitized and excludes repository identities. Public repositories and pull requests from forks continue to use GitHub-hosted runners. See [Automatic Repository Updates](docs/automatic-repository-updates.md) for the security model and one-time setup.

Downstream repositories can keep repository-specific module, path, secret-policy, enrolment, and OpenProject pull-request rules in their committed `.repository-quality-gates.local.json` file. RQG validates and reads that file but never copies it from or replaces it with the central template.

## Runtime Requirement

PowerShell 7 is required locally and in automation. The `pwsh` executable must be available on `PATH`. Repository Quality Gates no longer falls back to Windows PowerShell 5.1.

## What It Provides

Every target repository receives the universal licensing, secret-scanning, and module-drift modules. Additional modules are selected from the repository's tracked and unignored source files:

| Module | Selected When | Main GitHub Actions Gate |
|---|---|---|
| RQG Licensing | Always | Installs the RQG MIT attribution file alongside managed RQG components |
| Secret Scanning | Always | Full-history Gitleaks scan and synthetic policy tests |
| Automatic Reconciliation | Always | Re-detect required modules, add missing modules, remove unchanged obsolete modules, validate, commit, and push the managed result |
| PowerShell | A `.ps1`, `.psm1`, or `.psd1` file exists | PowerShell parser validation |
| .NET | A `.sln`, `.slnx`, `.csproj`, `.fsproj`, or `.vbproj` file exists | Restore, Release build, and headless tests |
| Node | `package.json` or a `.js`, `.mjs`, or `.cjs` file exists | JavaScript syntax; reproducible npm checks when packaged; dependency-free `tests/test.js` when present |
| Python | A Python project marker or `.py` file exists | Runtime and development dependency installation, bytecode compilation, and tests when a `tests` directory exists |
| PHP | `composer.json` or a `.php` file exists | PHP syntax, Composer validation/install, and optional Composer tests |
| Shell | A `.sh` or `.bash` file exists | `bash -n` syntax validation |
| PlatformIO | `platformio.ini` exists | Pinned PlatformIO firmware build |
| Go | `go.mod` or `go.work` exists | Formatting, vetting, tests, and package builds |
| Documentation | A `.md` or `.markdown` file exists | Markdown trailing-whitespace check |

See [Quality Gates](docs/quality-gates.md) for the exact selection rules, commands, runners, triggers, permissions, exclusions, and limitations for every module.

See [Automation Costs And Release Strategy](docs/automation-costs-and-releases.md) for current GitHub Actions cost boundaries and the recommended staged approach to automated builds and releases.

Workflow runner selection is configurable without changing managed workflow files. `RQG_WINDOWS_RUNS_ON` and `RQG_LINUX_RUNS_ON` may contain JSON runner-label arrays for private repositories. When either variable is absent, the matching GitHub-hosted runner remains the default. Public repositories and pull requests from forks always use GitHub-hosted runners, even when a self-hosted value is configured. Private values must include `rqg` and a neutral repository-specific label. See [Automation Costs And Release Strategy](docs/automation-costs-and-releases.md#self-hosted-runner-routing) for the exact values and account-boundary rules.

## Start Here

1. Read the [Deployment Guide](docs/deployment-guide.md).
2. Run a preview against the target repository:

   ```powershell
   pwsh -NoProfile -File ".\scripts\Invoke-RepositoryQualityGates.ps1" -RepositoryPath "C:\Path\To\Repository"
   ```

3. Review the selected modules, planned actions, conflicts, existing-workflow overlaps, and `.gitignore` changes.
4. Apply the reviewed plan and configure the local private policy:

   ```powershell
   pwsh -NoProfile -File ".\scripts\Invoke-RepositoryQualityGates.ps1" -RepositoryPath "C:\Path\To\Repository" -Apply -ConfigureLocalHooks -PrivateConfigPath "C:\Protected\publication-safety.toml"
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
- Pull requests report module drift without failing. Push and manual runs use the embedded deployment engine to add missing modules and remove unchanged obsolete modules automatically.
- Automatic reconciliation validates the public secret policy, commits only from a clean GitHub checkout, pushes with the repository token, then dispatches the managed workflows against the reconciled commit.
- Locally modified managed files still stop reconciliation instead of being overwritten. Preserved external implementations remain recorded and unchanged.
- Downstream-only module choices and additional public secret policies live in the committed `.repository-quality-gates.local.json` file, which RQG reads but never manages or overwrites.
- Commit and push require a clean repository before deployment, preventing unrelated work from entering the generated commit.
- Commit stages only the deployment plan and managed-state file, then runs the staged secret scan.
- Push fetches the remote, rejects a branch that is behind, scans the exact outgoing commit range, and never force-pushes.
- Private identifier policies stay outside every repository and are referenced only through local Git configuration.
- Each GitHub App installation is enumerated independently and receives its own short-lived token; owner and full repository names are masked before downstream processing writes to the public workflow log.
- The fleet workflow allows up to 120 minutes for a complete run and can send an authenticated SMTP success or failure report with the selected release, workflow link, and a fully bordered Repository, Status, and Comment table. Comments are concise factual summaries; complete sanitized diagnostics remain in the private workspace report. Repository names exist only in that email-only report; the downloadable one-day diagnostic artifact remains sanitized.

See [Module System](docs/module-system.md) for state tracking, file classification, conflict behavior, recovery copies, preservation, pruning, and push safeguards.

## Repository Contents

| Path | Purpose |
|---|---|
| `scripts/Invoke-RepositoryQualityGates.ps1` | Preview-first detector and deployment entry point |
| `modules/catalog.json` | Module definitions, detection rules, payload sources, and overlap markers |
| `modules/*/payload` | Module-specific files copied into applicable repositories |
| `template` | Universal secret-scanning payload retained for compatibility |
| `tests/Invoke-RepositoryQualityGates.Tests.ps1` | Synthetic regression suite for selection, deployment, conflict, recovery, preservation, and idempotence behavior |
| `tests/Update-RepositoryQualityGates.Tests.ps1` | Synthetic regression suite for version comparison, safe updates, skips, and managed-file conflicts |
| `tests/Invoke-RepositoryQualityGateFleetUpdate.Tests.ps1` | Synthetic fleet-discovery suite for automatic enrolment, repository opt-out, open-pull-request deferral, and workflow activation |
| `tests/Invoke-RepositoryQualityGateAppFleetUpdate.Tests.ps1` | Synthetic authentication suite for multi-installation discovery, token isolation, and cross-owner fleet dispatch |
| `tests/Get-RepositoryQualityGateReleasePlan.Tests.ps1` | Synthetic automatic-release suite for version, check, commit, tag, and release-state validation |
| `scripts/Update-RepositoryQualityGates.ps1` | Preview or apply a newer template to one managed repository |
| `scripts/Invoke-RepositoryQualityGateFleetUpdate.ps1` | Discover GitHub App repositories, open update pull requests, and enable required-check-gated auto-merge |
| `scripts/Invoke-RepositoryQualityGateAppFleetUpdate.ps1` | Enumerate every GitHub App installation, issue an isolated token for each, mask discovered identities, and run the fleet updater |
| `scripts/Get-RepositoryQualityGateReleasePlan.ps1` | Validate the central stable version and determine whether its immutable tag and release may be created or recovered |
| `docs/quality-gates.md` | Detailed gate and module-selection reference |
| `docs/deployment-guide.md` | End-to-end operator instructions |
| `docs/module-system.md` | Architecture and managed-file lifecycle reference |
| `docs/automation-costs-and-releases.md` | GitHub Actions cost boundary and recommended build/release automation controls |
| `docs/repository-administration.md` | Recommended GitHub repository settings and their compatibility with RQG automation |
| `.github/dependabot.yml` | Weekly grouped dependency updates for GitHub Actions |
| `LICENSE` | MIT license for this repository |
| `LICENSES/Repository-Quality-Gates-MIT.txt` | Managed downstream notice that scopes the RQG licence to RQG-managed files |
| `SECURITY.md` | Supported versions, reporting route, scope, invariants, and safe-testing policy |

Managed downstream repositories receive `LICENSES/Repository-Quality-Gates-MIT.txt`. Its MIT terms apply only to `.repository-quality-gates.json` and the files identified in that file's `files` array. It does not license any other downstream source, documentation, configuration, assets, or data, and it does not replace or change the downstream project's own licence.

## Recommended Repository Settings

RQG's workflows provide repository-level checks, and the central repository now also uses GitHub's native secret scanning and push protection, dependency alerts and security updates, SHA-pinned Actions, read-only default workflow permissions, 30-day workflow retention, automatic deletion of merged branches, immutable releases, and active rulesets protecting `main` and release tags. Weekly grouped Dependabot updates keep GitHub Actions references current for review.

Apply the controls in stages. RQG's current self-reconciliation workflow can commit a normalized managed state directly to its branch. A rule requiring every `main` change to arrive through a pull request would block that behavior until self-reconciliation is changed to use a temporary pull request or a narrowly scoped GitHub App bypass is approved.

See [Repository Administration](docs/repository-administration.md) for the verified settings, current compatibility constraints, and safe implementation order.

## Private Policy Boundary

The universal modules deploy only public, portable rules. Personal identifiers, private domains, internal paths, hostnames, and other private publication rules must remain in a protected file outside every repository.

Never add a private identifier source file or generated private policy to repository files, Git history, GitHub Actions secrets, variables, artifacts, caches, or logs. Local scripts obtain the policy path from the `publicationSafety.privateConfig` repository-local Git setting.

## Approved Markdown Attribution Exceptions

The reusable baseline supports a narrowly scoped product-attribution exception
for an exact approved name in the root `README.md` only. The name is permitted
only while the current Markdown section heading matches `licence`, `license`,
or `attribution`, including plural and combined headings such as `Licenses and
attribution`; matching is case-insensitive and accepts any Markdown heading
level. The section ends at the next heading. The year, copyright punctuation,
licence wording, and referenced licence filename are deliberately not matched.

Validate a protected approved name with:

```powershell
pwsh -NoProfile -File ".\scripts\Test-MarkdownAttribution.ps1" -RepositoryPath "C:\Path\To\Repository" -ApprovedName "<APPROVED_NAME>"
```

The approved name and the corresponding exact `README.md` allowlist remain in
the protected publication policy and the target project's public `.gitleaks.toml`.
The public RQG repository contains only this reusable structural validator and
never contains project-specific private identifier collections.

## License And Security

Repository Quality Gates is available under the [MIT License](LICENSE). Managed downstream repositories receive a separate notice whose MIT terms cover only the RQG managed-state file and the RQG-managed files it identifies; all other downstream content remains subject to the downstream project's own licensing terms.

See the [Security Policy](SECURITY.md) for supported versions, security boundaries, safe-testing expectations, and the private vulnerability-reporting route.

## Validation

Run the template and central automation regression suites from this repository:

```powershell
pwsh -NoProfile -File ".\tests\Invoke-RepositoryQualityGates.Tests.ps1"
pwsh -NoProfile -File ".\tests\Update-RepositoryQualityGates.Tests.ps1"
pwsh -NoProfile -File ".\tests\Invoke-RepositoryQualityGateFleetUpdate.Tests.ps1"
pwsh -NoProfile -File ".\tests\Invoke-RepositoryQualityGateAppFleetUpdate.Tests.ps1"
pwsh -NoProfile -File ".\tests\Get-RepositoryQualityGateReleasePlan.Tests.ps1"
```

The regression suite uses generated synthetic repositories only and includes automatic Python-to-PHP reconciliation. It does not use real credentials or private identifier values.
