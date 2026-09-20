# Automatic Repository Updates

Repository Quality Gates can update its managed template across selected repositories without storing a personal access token. The central workflow runs when a stable release is published, once each week, or when started manually.

## What The Automation Does

1. Resolves the latest published Repository Quality Gates release.
2. Creates a short-lived GitHub App installation token.
3. Enumerates only repositories selected for that GitHub App installation.
4. Skips the central template repository and repositories without `.repository-quality-gates.json`.
5. Skips repositories already on the target version and refuses to downgrade a newer version.
6. Clones each outdated repository from its default branch into a temporary runner folder.
7. Applies the released template with managed pruning and preserved-module settings.
8. Stops if a managed file was changed by the repository or another deployment conflict is found.
9. Runs the public working-tree, detection-policy, module-drift, and staged secret checks.
10. Pushes `rqg/update-v<VERSION>` and opens or refreshes a pull request.

The automation never merges a pull request. Repository-specific checks and review remain the merge gate.

## One-Time GitHub App Setup

Create a private GitHub App owned by the same account as the repositories.

Use these repository permissions:

| Permission | Access | Purpose |
|---|---:|---|
| Contents | Read And Write | Read managed state and push the update branch |
| Pull Requests | Read And Write | Find or create the update pull request |
| Metadata | Read | Required GitHub App repository metadata |

The app does not need issue, administration, secrets, Actions, deployment, package, or organization permissions.

Install the app only on repositories that Repository Quality Gates may update. Repository selection is the fleet allow-list; the script also requires the managed state file before it will act.

In the central `repository-quality-gates` repository:

1. Open **Settings** → **Secrets And Variables** → **Actions**.
2. Under **Variables**, create `RQG_APP_ID` containing the GitHub App ID.
3. Under **Secrets**, create `RQG_APP_PRIVATE_KEY` containing the complete private key generated for the app.
4. Keep the private key out of files, commits, workflow logs, and pull-request content.

The workflow exchanges these values for a short-lived installation token at runtime. It does not copy the private key or installation token into a managed repository.

## Workflow Triggers

The central `.github/workflows/update-managed-repositories.yml` workflow runs:

- immediately after a stable GitHub Release is published;
- weekly at its documented UTC schedule; and
- on a manual `workflow_dispatch` request.

Every run resolves the latest published release and checks out that immutable tag before updating repositories. Development work on `main` therefore cannot be distributed before it becomes a release.

## Local Preview

Preview one repository without changing it:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Update-RepositoryQualityGates.ps1" -RepositoryPath "<REPOSITORY_PATH>"
```

Apply an update locally after reviewing the preview:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Update-RepositoryQualityGates.ps1" -RepositoryPath "<REPOSITORY_PATH>" -Apply
```

The local command changes files but does not commit, push, create a pull request, or merge.

## Conflict And Recovery Behavior

- A file whose current hash matches the previously recorded managed hash may be updated.
- A modified managed file stops the update and is preserved.
- Repository-owned files are not replaced.
- A repository on a newer template version is never downgraded.
- Unmanaged repositories are skipped.
- Temporary clones are deleted when the fleet run finishes.
- A failed repository is reported without preventing the updater from assessing the remaining repositories.

Resolve a reported conflict in the repository's own project, then rerun the central workflow. Do not force replacement until the repository-specific change has been reviewed and a recovery copy exists.

## Separate Dependency Updates

This workflow updates Repository Quality Gates itself. Package updates for npm, Python, .NET, PHP, Go, Docker, GitHub Actions, and other ecosystems are a separate capability. Those can be added through ecosystem-specific Dependabot configuration after their grouping, schedule, and compatibility rules are defined.
