# Repository Ruleset Engine

The ruleset engine audits the effective default-branch rules & merge settings for a supplied repository list. It derives required check names from each repository's deployed Repository Quality Gates modules.

Audit mode is the default & performs no mutation:

```powershell
./scripts/Invoke-RepositoryRulesetEngine.ps1 -Repository 'owner/repository' -OutputFormat Json
```

Apply mode creates or updates the managed `Repository Standards - Default Branch` ruleset, applies the approved merge settings, & then reads the effective rules back. The caller must supply a GitHub App installation token or another short-lived credential with repository administration write access through `GH_TOKEN`:

```powershell
./scripts/Invoke-RepositoryRulesetEngine.ps1 -Repository 'owner/repository' -Apply -OutputFormat Json
```

The engine never changes repository visibility. If GitHub rejects native rules for a private repository because of the current plan, it records `RQG-PRIVATE-PLAN-001` & takes no mutation. When the repository later becomes public, a subsequent apply run creates the active ruleset. This provides reconciliation after a visibility change; it cannot protect an unsupported private repository before GitHub makes the feature available.

The `Reconcile Repository Rulesets` workflow performs a daily fleet audit. Apply is deliberately available only through an explicit manual workflow run. It uses short-lived installation tokens from the existing Repository Quality Gates GitHub App. Audit requires repository metadata & rules read access; apply additionally requires repository administration write access. The workflow's own `GITHUB_TOKEN` remains read-only.

`terryrogers/DCC_LabStation_LS8` retains its approved milestone merge-commit exception. Every other governed repository remains squash-only by default.
