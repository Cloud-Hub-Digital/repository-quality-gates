# Automation Costs And Release Strategy

This note records the cost boundary and recommended rollout for automated builds and releases. Pricing is a point-in-time summary checked on 16 September 2026; GitHub's current billing pages remain authoritative.

## Current Cost Boundary

For public repositories, standard GitHub-hosted runners are free and unlimited. RQG defaults to standard `ubuntu-latest` and `windows-2025` runners when no self-hosted runner variables are configured, so public repositories can retain the free hosted path.

For private repositories on GitHub Free, GitHub currently includes 2,000 Actions minutes per month, 500 MB of shared Actions artifact storage, and 10 GB of cache storage per repository. Usage beyond the included allowance is billed only when a valid payment method and spending allowance permit it; otherwise further workflow use is blocked.

Current baseline rates beyond an included allowance are USD $0.006 per minute for a standard two-core Linux runner and USD $0.010 per minute for a standard two-core Windows runner. macOS and larger runners cost more. Larger runners are always billable, including for public repositories.

GitHub Releases permits up to 1,000 assets per release, each smaller than 2 GiB, with no documented limit on total release size or bandwidth. Release assets are separate from temporary Actions artifacts. The workflow time used to build and upload a release still follows Actions billing rules.

Official references:

- [GitHub Actions Billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
- [Included GitHub Product Usage](https://docs.github.com/en/billing/reference/product-usage-included)
- [GitHub-Hosted Runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [Larger Runners](https://docs.github.com/en/actions/concepts/runners/larger-runners)
- [About GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)

## Recommended Rollout

Automated builds are a useful next module because they prove that a clean GitHub runner can reproduce the build. They should be enabled on pull requests and pushes using the applicable language module.

Release publishing for general downstream products should be a separate, opt-in module with these controls:

1. Trigger only from an explicitly approved semantic-version tag or a manual `workflow_dispatch` request containing the exact approved version.
2. Re-run the complete quality, test, secret, and publication checks before packaging.
3. Build in headless mode. Keep desktop UI tests in a separate isolated workflow so applications do not interrupt local work.
4. Produce deterministic packages, checksums, and a software bill of materials where supported.
5. Upload final packages directly to the GitHub Release. Use temporary Actions artifacts only when jobs must exchange files, and give them the shortest useful retention period.
6. Grant the release job `contents: write` only; keep all other jobs at `contents: read`.
7. Use GitHub Environments with a required approval before the publishing job when the repository and plan support that control.
8. Prevent concurrent publication of the same version and reject an existing tag or release instead of overwriting it.
9. Keep version creation, OpenProject version records, the Versions board, the Git tag, GitHub Release, and the packaged artifact on the same canonical version.

The recommended sequence is therefore:

1. Keep the current quality workflows on every pull request and push.
2. Add build-and-package validation without publishing.
3. Add a manually approved release workflow after each product's build outputs, version source, packaging method, and required platforms are documented.

## Cost Controls

- Use standard Linux runners where the product does not require Windows.
- Automatic reconciliation uses a standard Windows runner because it executes the verified Windows Gitleaks package before committing. It consumes included Actions minutes for private repositories and is free on standard runners for public repositories.
- Use standard Windows runners only for Windows-specific builds and tests.
- Do not use larger runners without an explicit cost decision.
- Add `concurrency` cancellation for superseded branch and pull-request runs.
- Keep timeouts finite and dependency caches narrowly keyed.
- Avoid uploading intermediate artifacts unless another job needs them.
- Set short retention periods for temporary artifacts.
- Configure a GitHub Actions spending limit before enabling paid overage on private repositories.

## Self-Hosted Runner Routing

Managed workflows choose their runner before repository files are checked out. Runner routing therefore cannot be read from `.repository-quality-gates.local.json`. Use GitHub Actions configuration variables at the organization or repository level:

| Variable | Hosted Default | Example Self-Hosted Value |
|---|---|---|
| `RQG_WINDOWS_RUNS_ON` | `["windows-2025"]` | `["self-hosted","Windows","X64","rqg","repository-slug"]` |
| `RQG_LINUX_RUNS_ON` | `["ubuntu-latest"]` | `["self-hosted","Linux","X64","rqg","repository-slug"]` |

Store each value as valid JSON. Organization variables apply only to repositories in that organization and only when their repository access includes the target repository. A runner registered to an organization cannot run jobs for a repository owned by a separate personal account. Personal-account repositories must either retain the hosted default, receive their own repository-level runner registration and matching variable, or move to the organization after a separate ownership decision.

Replace `repository-slug` with the neutral repository-specific label applied to both of that private repository's runners. Include `rqg` and the repository-specific label in every configured value. This keeps jobs scoped to the intended runner pair even when an account owns several runners.

Public repositories and pull requests from forks always use the matching GitHub-hosted runner, even if a self-hosted variable exists. This prevents public or untrusted fork code from executing on privately operated machines. Pushes, scheduled runs, manual runs, release runs, and pull requests whose branch belongs to the same private repository may use the configured self-hosted runner.

Runner labels and GitHub-visible runner names must contain no machine name or internal infrastructure identifier. Keep repository runners scoped to one private repository, keep organization runner groups restricted to explicitly approved private repositories, run services with the least practical privilege, do not expose a host Docker socket to job containers, and keep finite job timeouts. Do not configure these variables for a public repository.

## Current Template Status

The reusable downstream template deploys build and test gates for detected codebases, but it does not create downstream releases, tags, versions, or deployment artifacts. Release automation for downstream products still requires a separate module because package formats, signing requirements, version sources, target platforms, and release approval steps vary by project.

The central Repository Quality Gates repository is the documented exception. Its stable output is the repository itself, so `.github/workflows/automatic-release.yml` can create an annotated version tag and immutable GitHub Release after all central checks pass. It then explicitly dispatches downstream template distribution because GitHub does not recursively start most workflows from events created with `GITHUB_TOKEN`.
