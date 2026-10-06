# Repository Ruleset & Feature Engine

The engine audits effective default-branch rules, merge settings, live repository features, repository-local feature exceptions, & required issue forms for a supplied repository list. It derives required check names from each repository's deployed Repository Quality Gates modules. Audit is always the default; mutation requires an explicit apply request.

## Fixed Repository Contract

| Area | Required State |
|---|---|
| Default Branch | `main` |
| Pull Requests | Required with current required checks & resolved conversations |
| History Safety | Branch deletion & force pushes blocked; no bypass actors |
| Merge Methods | Squash enabled; merge commits & rebase disabled unless an approved repository exception applies |
| Branch Cleanup | Merged head branches deleted automatically |
| Issues | Enabled; cannot be disabled by exception |
| Discussions | Disabled unless an approved local exception enables it |
| Wiki | Disabled unless an approved local exception enables it |
| Pages | Disabled unless an approved local exception enables it |
| Issue Intake | Local bug-report, feature-request, question, & picker configuration files required |
| Support Route | `.repository-standards.json` must use `github-issues` |

The policy source is `policy/repository-ruleset-policy.json`. The engine validates that file before it reads or changes a repository, so a weakened default, an unknown exception, or an incomplete required-template list fails closed.

## Repository Content & Administration State

RQG deliberately treats these as two separate change paths:

- The universal documentation module delivers `.github/ISSUE_TEMPLATE/bug_report.yml`, `feature_request.yml`, `question.yml`, & `config.yml`, updates the managed-state hashes, & migrates `supportRoute` from `github-discussions` to `github-issues`. These are repository-content changes and use the ordinary reviewed RQG pull-request path.
- The ruleset engine reads & optionally reconciles GitHub-hosted rules, merge methods, branch cleanup, Issues, Discussions, Wikis, & Pages. These are administration changes and are never hidden inside a content commit.

The engine reports missing issue-form files but does not create them through the GitHub administration API. Conversely, deploying the four files does not claim that the live Issues setting is enabled.

## Feature Exceptions

Issues remain mandatory. Only `discussions`, `wiki`, or `pages` may have one repository-local exception each. An exception belongs in `.repository-standards.json` & must differ from the fixed baseline:

```json
{
  "featureExceptions": [
    {
      "id": "EXAMPLE-DISCUSSIONS",
      "feature": "discussions",
      "enabled": true,
      "owner": "Repository Owner",
      "reason": "The repository operates a moderated community forum.",
      "approvalStatus": "approved",
      "reviewCondition": "Review annually or when the forum is retired."
    }
  ]
}
```

The identifier must use uppercase letters, digits, dots, underscores, or hyphens. The owner, reason, & review condition must be non-empty; `approvalStatus` must be exactly `approved`; `enabled` must be Boolean; duplicate exceptions for one feature are rejected. Omitting `featureExceptions` or supplying an empty array means that no feature exception applies.

An exception that enables Pages is audited but not provisioned automatically. A Pages site needs its own approved source, build, publication, & ownership configuration. Apply mode may disable an unapproved Pages site, but it never invents or publishes one.

## Audit Mode

Audit mode is the default & performs no mutation:

```powershell
./scripts/Invoke-RepositoryRulesetEngine.ps1 -Repository 'owner/repository' -OutputFormat Json
```

The structured result records repository identity, visibility, the calculated policy, exception IDs, required checks, missing or deferred controls, & the recommended action. A repository without managed RQG state is reported as an enrolment prerequisite because required check names cannot be guessed safely.

## Apply Mode

Apply mode creates or updates the managed `Repository Standards - Default Branch` ruleset, applies the approved merge settings, enables Issues, disables or preserves the optional features according to the approved profile, disables Pages when required, & then reads the complete effective state back. The caller must supply a GitHub App installation token or another short-lived credential with repository administration write access through `GH_TOKEN`:

```powershell
./scripts/Invoke-RepositoryRulesetEngine.ps1 -Repository 'owner/repository' -Apply -OutputFormat Json
```

Apply succeeds only when post-write readback matches the calculated policy. A missing setting, remaining ruleset drift, unexpected provider response, duplicate managed ruleset, unresolved profile, or unverifiable state fails the run. The engine never changes repository visibility, publishes repository content, merges a pull request, or creates a release.

## Private Repository Plan Boundary

If GitHub rejects native rules for a private repository because of the recognized current-plan limitation, the engine records `RQG-PRIVATE-PLAN-001` & takes no ruleset mutation. It does not claim that the branch is protected. The approved policy remains available, so a subsequent reviewed apply can create the active ruleset if the repository becomes public or the plan later supports native protection.

## Fleet Workflow & Credentials

The `Reconcile Repository Rulesets` workflow performs a daily fleet audit. Apply is deliberately available only through an explicit manual workflow run. It uses short-lived installation tokens from the existing Repository Quality Gates GitHub App. Audit requires repository metadata & rules read access; apply additionally requires repository administration write access. The workflow's own `GITHUB_TOKEN` remains read-only.

`terryrogers/DCC_LabStation_LS8` retains its approved milestone merge-commit exception. Every other governed repository remains squash-only by default.

The fleet wrapper isolates each installation token, masks it before use, processes only repositories visible to that installation, & clears the credential after the installation finishes. A failure for one repository is retained in the structured report without weakening another repository's validation.

## Safe Rollout Order

1. Release the exact tested RQG version.
2. Run the ordinary fleet update in preview mode so required content changes are reviewable.
3. Create & merge the generated repository pull requests only after their checks pass.
4. Run the ruleset workflow in audit mode & review every calculated change or deferral.
5. Run an explicitly authorized manual apply.
6. Verify the resulting rules, merge settings, features, forms, & support route through fresh readback.

No single step implies that a later step is authorized or complete.
