# Repository Administration

This guide describes the recommended GitHub settings for the central Repository Quality Gates repository. It complements the checks deployed by RQG and does not replace them.

## Established Configuration

The following settings were verified through the GitHub API on 20 September 2026:

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
| Workflow Retention | Artifacts and logs retained for 30 days |
| Fork Workflows | Approval required for all external contributors |
| Pull Requests | Merge commits, squash merging, and rebase merging enabled; auto-merge disabled |
| Branch Cleanup | Head branches automatically deleted after merge |
| Main History | Active `Protect Main History` branch ruleset targets the default branch and blocks deletion and force pushes, with no bypass actors |
| Release Tags | Active `Protect Release Tags` tag ruleset targets `v*` and blocks update, deletion, and force pushes, with no bypass actors |
| Releases | Release immutability enabled |
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
| Main Branch | Block force pushes and deletions immediately | Preserve published history without interfering with normal reconciliation |
| Main Branch | Require pull requests, required checks, conversation resolution, and an approval after reconciliation is PR-based | Protect reviewed changes while retaining functioning automation |
| Release Tags | Protect tags matching `v*` from update and deletion | Keep released versions immutable |
| Community | Add contribution guidance, a code of conduct, issue forms, a pull-request template, CODEOWNERS, and support guidance as participation grows | Set clear expectations and improve GitHub's community profile |

## Self-Reconciliation Compatibility

The central `.github/workflows/quality-module-drift.yml` workflow currently normalizes managed files and pushes the resulting commit directly to the triggering branch. A `main` ruleset that requires a pull request or required checks for every update can reject that push.

Use this order:

1. Enable secret scanning, push protection, Dependabot, SHA pinning, restricted Actions, read-only default permissions, merged-branch cleanup, and tag protection.
2. Add a `main` ruleset that blocks force pushes and deletions.
3. Change central self-reconciliation to create a short-lived pull request, or approve a narrowly scoped GitHub App as a ruleset bypass actor.
4. Require pull requests, the applicable quality checks, resolved conversations, and the chosen number of approvals on `main`.
5. Verify one complete reconciliation before treating the stronger ruleset as established.

Downstream fleet updates already use short-lived pull requests and can operate under pull-request protection when their required checks and App permissions are configured correctly.

## Settings Not Currently Required

Environments, deploy keys, webhooks, and GitHub Pages are not required by the present design. Add them only when a documented deployment, external integration, or hosted documentation need exists.

CodeQL does not analyze PowerShell. Native secret scanning, dependency security, strict Actions controls, RQG's Gitleaks checks, parser validation, and synthetic regression tests provide the relevant baseline for this repository.

## Review After Changes

After changing repository settings:

1. Run or re-run all applicable RQG workflows.
2. Confirm the Module Drift workflow can complete its intended reconciliation path.
3. Confirm temporary update branches are removed after merge.
4. Confirm a test pull request cannot merge until every required check passes.
5. Record the final settings and validation evidence in the project record.

## Remaining Settings Work

The stronger `main` protection described above remains intentionally deferred until central self-reconciliation creates a temporary pull request instead of pushing its generated commit directly.

## GitHub References

- [About Rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets)
- [Available Rules For Rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets)
- [Managing GitHub Actions Settings For A Repository](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository)
- [About Secret Scanning](https://docs.github.com/en/code-security/concepts/secret-security/secret-scanning)
- [About Push Protection](https://docs.github.com/en/code-security/concepts/secret-security/push-protection)
