# Repository Ruleset & Feature Engine

The engine audits effective default-branch rules, merge settings, live repository features, repository-local feature exceptions, & required issue forms for a supplied repository list. It derives required check names from each repository's deployed Repository Quality Gates modules.

Audit mode is the default & performs no mutation:

```powershell
./scripts/Invoke-RepositoryRulesetEngine.ps1 -Repository 'owner/repository' -OutputFormat Json
```

Apply mode creates or updates the managed `Repository Standards - Default Branch` ruleset, applies the approved merge settings, enables Issues, disables Discussions & Wikis, disables Pages when required, & then reads the effective state back. The caller must supply a GitHub App installation token or another short-lived credential with repository administration write access through `GH_TOKEN`:

```powershell
./scripts/Invoke-RepositoryRulesetEngine.ps1 -Repository 'owner/repository' -Apply -OutputFormat Json
```

The engine never changes repository visibility. If GitHub rejects native rules for a private repository because of the current plan, it records `RQG-PRIVATE-PLAN-001` & takes no mutation. When the repository later becomes public, a subsequent apply run creates the active ruleset. This provides reconciliation after a visibility change; it cannot protect an unsupported private repository before GitHub makes the feature available.

The fixed feature baseline is Issues enabled with local `bug_report.yml`, `feature_request.yml`, `question.yml`, & `config.yml` files, and Discussions, Wikis, & Pages disabled. A deviation is accepted only when `.repository-standards.json` supplies one complete approved `featureExceptions` entry for that feature. Missing forms remain a repository-content update rather than a direct administration mutation; the universal documentation module delivers them through the ordinary reviewed RQG update path.

An exception that enables Pages is audited but is not provisioned automatically because a Pages publication route requires its own approved source, build, & ownership configuration. The engine can disable an unapproved Pages site, but it does not invent or publish one.

The `Reconcile Repository Rulesets` workflow performs a daily fleet audit. Apply is deliberately available only through an explicit manual workflow run. It uses short-lived installation tokens from the existing Repository Quality Gates GitHub App. Audit requires repository metadata & rules read access; apply additionally requires repository administration write access. The workflow's own `GITHUB_TOKEN` remains read-only.

`terryrogers/DCC_LabStation_LS8` retains its approved milestone merge-commit exception. Every other governed repository remains squash-only by default.
