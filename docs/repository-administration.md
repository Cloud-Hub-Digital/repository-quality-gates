# Repository Administration

This guide records the verified GitHub settings for the central Repository Quality Gates repository & the governed settings contract applied across managed repositories. It complements the checks deployed by RQG and does not replace them.

## Established Configuration

The following central-repository settings were freshly verified through the GitHub API on 6 October 2026:

| Area | Established Setting |
|---|---|
| Repository | Public repository with `main` as the default branch |
| Secret Security | Secret scanning and push protection enabled |
| Secret Security | Non-provider patterns and validity checks disabled because GitHub does not currently expose them as active for this repository |
| Dependency Security | Dependency graph, Dependabot alerts, malware alerts, security updates, and grouped security updates enabled |
| Vulnerability Reporting | Private vulnerability reporting enabled |
| Code Scanning | CodeQL not configured because GitHub CodeQL does not analyze PowerShell |
| Actions Sources | Only actions from Cloud-Hub-Digital and GitHub are allowed; verified third-party creators and additional patterns are not allowed |
| Actions Integrity | Every action must be pinned to a full-length commit SHA |
| Workflow Token | Read-only repository contents and packages by default; GitHub Actions cannot create or approve pull requests |
| Release Workflow | The central automatic-release job requests `actions: write` to dispatch the fleet workflow and `contents: write` to create the tag and release |
| Workflow Retention | Artifacts and logs retained for 30 days |
| Fork Workflows | Approval required for all external contributors |
| Pull Requests | Squash merging enabled; merge commits, rebase merging, & auto-merge disabled |
| Branch Cleanup | Head branches automatically deleted after merge |
| Main History | Active `Protect Main History` branch ruleset targets the default branch and blocks deletion and force pushes, with no bypass actors |
| Release Tags | Active `Protect Release Tags` tag ruleset targets `v*` and blocks update, deletion, and force pushes, with no bypass actors |
| Releases | Release immutability enabled |
| Issues | Enabled with local bug-report, feature-request, question, & picker configuration files in the 3.2.0 candidate |
| Discussions | Disabled |
| Wiki | Disabled |
| Pages | Disabled; no Pages site is configured |
| Commit Signoff | Web-based commit signoff not required |

The repository contains a weekly Dependabot configuration for GitHub Actions. It groups action updates into one pull request and limits Dependabot to two open pull requests.

## Recommended Baseline

| Area | Recommended Setting | Reason |
|---|---|---|
| Secret Security | Enable secret scanning, push protection, non-provider patterns, and validity checks where GitHub makes them available | Detect supported credentials in repository history and block supported secrets before they are pushed |
| Dependency Security | Enable Dependabot alerts and security updates; retain the weekly `.github/dependabot.yml` entry for GitHub Actions | Report vulnerable dependencies and propose safe action-version updates |
| Actions | Require actions to be pinned to a full-length commit SHA | Prevent a mutable tag from silently changing the code executed by a workflow |
| Actions | Allow GitHub-authored actions plus an explicit allowlist of approved third-party actions | Reduce the set of external workflow code that can execute |
| Actions | Keep default workflow permissions read-only and keep pull-request approval disabled | Make elevated permissions an explicit job-level decision |
| Pull Requests | Delete head branches automatically after merge | Remove temporary RQG update branches promptly |
| Pull Requests | Enable squash only unless an approved repository exception applies | Keep one reviewed commit on the default branch while retaining the approved exceptional workflow |
| Main Branch | Block force pushes and deletions immediately | Preserve published history without interfering with normal reconciliation |
| Main Branch | Require pull requests, current required checks, conversation resolution, & last-push approval | Protect reviewed changes while retaining functioning automation |
| Release Tags | Protect tags matching `v*` from update and deletion | Keep released versions immutable |
| Issues | Enable Issues & keep local bug, feature, question, & picker configuration files | Provide one consistent intake & support route |
| Optional Features | Disable Discussions, Wikis, & Pages unless `.repository-standards.json` contains a complete approved exception | Avoid unmanaged or duplicate publishing & support surfaces |
| Community | Maintain contribution guidance, a code of conduct, pull-request template, CODEOWNERS, security policy, & support guidance | Set clear expectations & preserve the repository standard |

## Repository Feature Contract

The live setting & the repository content are independently verified. Issues must be enabled, `supportRoute` must be `github-issues`, & all four local files beneath `.github/ISSUE_TEMPLATE` must exist. Discussions, Wikis, & Pages are disabled by default. Only those three optional features can deviate through one complete approved local `featureExceptions` entry per feature; Issues cannot be disabled by exception.

The administration engine can reconcile the supported live settings. The ordinary RQG update path deploys the forms & profile migration through a reviewable pull request. Enabling Pages is never automated because its publication source & build configuration require separate approval.

## Self-Reconciliation Compatibility

The central `.github/workflows/quality-module-drift.yml` workflow currently normalizes managed files and pushes the resulting commit directly to the triggering branch. A `main` ruleset that requires a pull request or required checks for every update can reject that push.

Use this order:

1. Enable secret scanning, push protection, Dependabot, SHA pinning, restricted Actions, read-only default permissions, merged-branch cleanup, and tag protection.
2. Add a `main` ruleset that blocks force pushes and deletions.
3. Change central self-reconciliation to create a short-lived pull request, or approve a narrowly scoped GitHub App as a ruleset bypass actor.
4. Require pull requests, the applicable current quality checks, resolved conversations, & last-push approval on `main`.
5. Verify one complete reconciliation before treating the stronger ruleset as established.

Downstream fleet updates already use short-lived pull requests and can operate under pull-request protection when their required checks and App permissions are configured correctly.

## Automatic Stable Releases

The central `automatic-release.yml` workflow is repository-specific. The distinct universal `release-governance` module supplies `managed-automatic-release.yml` to downstream repositories using their committed release contract. The central stable release requires matching canonical version, managed state & changelog plus successful required workflows on the exact commit. It verifies remote `main`, creates the annotated immutable tag & GitHub Release, then dispatches fleet deployment. Existing matching releases are a clean no-op; conflicting tags block publication.

The repository must continue allowing workflow-level `contents: write` permission because the default token remains read-only. The active `v*` ruleset must permit new tags while continuing to block tag updates, deletion, and force pushes. Immutable Releases must remain enabled. Do not add an environment approval to this workflow unless the automatic publication policy is intentionally changed back to a manual gate.

## Settings Not Currently Required

Environments, deploy keys, & webhooks are not required by the present design. GitHub Pages, Discussions, & Wikis remain disabled unless a separately approved local exception records their purpose, owner, & review condition.

CodeQL does not analyze PowerShell. Native secret scanning, dependency security, strict Actions controls, RQG's Gitleaks checks, parser validation, and synthetic regression tests provide the relevant baseline for this repository.

## Review After Changes

After changing repository settings:

1. Run or re-run all applicable RQG workflows.
2. Confirm the Module Drift workflow can complete its intended reconciliation path.
3. Confirm temporary update branches are removed after merge.
4. Confirm a test pull request cannot merge until every required check passes.
5. Confirm Issues is enabled, all four local issue files exist, & the support route is `github-issues`.
6. Confirm Discussions, Wikis, & Pages match the approved baseline or recorded exceptions.
7. Record the final settings & validation evidence in the project record.

## Remaining Settings Work

The 3.2.0 candidate adds the managed `Repository Standards - Default Branch` ruleset reconciler. The separate daily administration workflow remains audit-only. An authorized fleet apply reconciles supported settings after verifying content & the exact checked revision; manual apply remains a diagnosis or recovery route. Administration write permission, initial protection readiness & all independent requirements must be verified before production use. These candidate features do not claim that live settings have already changed.

## GitHub References

- [About Rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets)
- [Available Rules For Rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets)
- [Managing GitHub Actions Settings For A Repository](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository)
- [About Secret Scanning](https://docs.github.com/en/code-security/concepts/secret-security/secret-scanning)
- [About Push Protection](https://docs.github.com/en/code-security/concepts/secret-security/push-protection)
