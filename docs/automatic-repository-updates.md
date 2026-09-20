# Automatic Repository Updates

Repository Quality Gates can update its managed template across selected repositories without storing a personal access token. The central workflow runs when a stable release is published, once each day, or when started manually. A downstream repository is updated only when it has no open pull requests. Each update uses its own pull request so the downstream repository's required checks remain the merge gate, then GitHub merges the pull request automatically when those requirements pass.

## What The Automation Does

1. Resolves the latest published Repository Quality Gates release.
2. Creates a short-lived GitHub App installation token.
3. Enumerates only repositories selected for that GitHub App installation.
4. Skips the central template repository and repositories without `.repository-quality-gates.json`.
5. Skips repositories already on the target version and refuses to downgrade a newer version.
6. Removes an RQG-created pull request and branch that have remained open for 24 hours, then checks eligibility again.
7. Defers an outdated repository when any pull request is open and reports every blocking pull request.
8. Clones each eligible outdated repository from its default branch into a temporary runner folder.
9. Reads the downstream repository's optional `.repository-quality-gates.local.json` rules.
10. Applies the released template with managed pruning and the repository-owned adjustments.
11. Stops if a managed file was changed by the repository or another deployment conflict is found.
12. Runs the public working-tree, detection-policy, module-drift, and staged secret checks.
13. Checks for open pull requests again immediately before publishing the temporary branch.
14. Pushes `rqg/update-v<VERSION>` and opens a pull request.
15. Enables squash auto-merge and branch deletion for that pull request.

GitHub completes the merge only after the downstream repository's branch rules and required checks allow it. A failed check, conflict, missing prerequisite, or unavailable auto-merge leaves the pull request open and reports the repository as failed. While that RQG pull request remains open, later fleet runs defer the repository like any other repository with an open pull request.

The `rqg/update-v<VERSION>` namespace is reserved for temporary branches created by this automation. A successful squash merge deletes the branch immediately. A failure after publishing the branch causes the updater to close its pull request and delete its branch during the same run. If required checks leave an auto-merge pull request open, the next daily run removes it after 24 hours. This retains a short inspection window without accumulating long-lived update branches.

## Downstream Repository Rules

A downstream repository may contain `.repository-quality-gates.local.json`. The file belongs to that repository, is committed there, and is never copied from or overwritten by the central RQG template. Committing it is essential because the GitHub-hosted fleet updater cannot see an untracked file that exists only on a workstation.

```json
{
  "schemaVersion": 1,
  "modules": {
    "include": [],
    "repositoryOwned": []
  },
  "secretScanning": {
    "additionalConfigFiles": []
  }
}
```

| Setting | Purpose |
|---|---|
| `modules.include` | Install a named RQG module even when normal file detection does not select it |
| `modules.repositoryOwned` | Keep a repository's existing verified implementation of a detected or explicitly included module instead of deploying the RQG payload |
| `secretScanning.additionalConfigFiles` | Run additional committed repository-specific Gitleaks TOML policies as separate scan layers |

The file is declarative. It cannot run commands, change GitHub permissions, disable the universal secret-scanning or module-drift modules, or override managed files. Module IDs must exist in the released catalogue. A repository-owned module must still have matching workflow evidence, and each additional secret policy must be a contained repository-relative TOML file that does not traverse a symbolic link or junction.

Older managed state that records preserved modules is migrated into this file during its first successful update. After migration, the repository-owned file is the source of truth and the managed state contains only the resolved snapshot used for drift reporting.

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

For each selected downstream repository, enable **Allow Auto-Merge** and configure its default-branch rules so every required quality, build, and test check must pass before merging. This is a one-time repository-administration setting; the narrowly scoped updater App does not receive Administration permission to weaken or create those rules.

In the central `repository-quality-gates` repository:

1. Open **Settings** → **Secrets And Variables** → **Actions**.
2. Under **Variables**, create `RQG_APP_ID` containing the GitHub App ID.
3. Under **Secrets**, create `RQG_APP_PRIVATE_KEY` containing the complete private key generated for the app.
4. Keep the private key out of files, commits, workflow logs, and pull-request content.

The workflow exchanges these values for a short-lived installation token at runtime. It does not copy the private key or installation token into a managed repository.

## Workflow Triggers

The central `.github/workflows/update-managed-repositories.yml` workflow runs:

- immediately after a stable GitHub Release is published;
- daily at its documented UTC schedule; and
- on a manual `workflow_dispatch` request.

Every run resolves the latest published release and checks out that immutable tag before updating repositories. Development work on `main` therefore cannot be distributed before it becomes a release.

If a release-triggered run finds an open pull request, it records `DeferredOpenPullRequests` and does not clone, create a branch, push, or create an RQG pull request for that repository. The updater checks again immediately before its first push so a pull request opened during local preparation also causes deferral without a remote branch. The daily fallback checks again automatically. Once every pull request is closed or merged, the next run builds the update from the then-current default branch.

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
- `.repository-quality-gates.local.json` and every policy it names remain repository-owned and unmanaged.
- A repository on a newer template version is never downgraded.
- Unmanaged repositories are skipped.
- Repositories with any open pull request are deferred without a branch, commit, push, or RQG pull request change.
- Successful RQG pull requests delete their temporary branch immediately after merge.
- Failed post-push preparation removes the RQG pull request and temporary branch in the same run.
- An RQG auto-merge pull request still open after 24 hours is closed and its reserved temporary branch is deleted by the next daily run.
- Temporary clones are deleted when the fleet run finishes.
- A failed repository is reported without preventing the updater from assessing the remaining repositories.

Move any intentional downstream customization out of an RQG-managed file and into the repository-owned rules, workflow, or additional policy file. Restore the managed file to its recorded RQG version, then rerun the central workflow. Do not force replacement until the repository-specific change has been reviewed and a recovery copy exists.

## Separate Dependency Updates

This workflow updates Repository Quality Gates itself. Package updates for npm, Python, .NET, PHP, Go, Docker, GitHub Actions, and other ecosystems are a separate capability. Those can be added through ecosystem-specific Dependabot configuration after their grouping, schedule, and compatibility rules are defined.
