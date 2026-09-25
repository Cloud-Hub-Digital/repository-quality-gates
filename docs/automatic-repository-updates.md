# Automatic Repository Updates

Repository Quality Gates can enrol unmanaged repositories and update its managed template across every account or organization where its GitHub App is installed, without storing a personal access token or publishing an owner inventory. The central workflow runs when a stable release is published, once each day, or when started manually. Every unmanaged repository visible to any installation is eligible unless its repository-owned rules file explicitly opts out. A downstream repository is changed only when it has no open pull requests. Each enrolment or update uses its own pull request so the downstream repository's required checks remain the merge gate, then GitHub merges the pull request automatically when those requirements pass.

The central `.github/workflows/automatic-release.yml` workflow creates that stable release from `main`. It waits for Documentation Quality, Fleet Update Quality, Quality Gate Module Drift, Secret Scanning, and PowerShell Quality on the exact commit. It then confirms the commit is still current, verifies one stable semantic version across the deployment engine, managed state, and changelog, creates an annotated `v<VERSION>` tag, publishes the immutable GitHub Release, and explicitly dispatches the fleet workflow described below. The explicit dispatch is required because GitHub suppresses most new workflow events created by the repository's own `GITHUB_TOKEN`.

The release workflow binds every required result to both its exact workflow path and expected display name. It does nothing when the canonical version is unchanged and the matching release already exists. It skips prerelease versions and commits superseded on `main`. It fails closed when a required workflow fails, is missing, or is replaced by a same-name workflow at another path; when version metadata disagrees; when the changelog entry is missing; or when the version tag already identifies another commit. If tag creation succeeded but release creation was interrupted, a manual rerun can create the missing release only when the tag still identifies the exact validated commit.

## What The Automation Does

1. Resolves the latest published Repository Quality Gates release.
2. Creates a short-lived GitHub App JSON Web Token used only to list the App's installations and request installation tokens.
3. Enumerates every account or organization where the App is installed.
4. Creates a separate short-lived token for one installation at a time.
5. Enumerates only the repositories selected for that installation and masks each owner and full repository name before downstream processing writes to the public workflow log.
6. Revokes that installation token after its repositories have been processed, then repeats the process for the next installation. If one installation fails, the wrapper records that failure, continues through every remaining installation, and fails the completed run with an aggregate installation count.
7. Skips the central template repository.
8. Treats a repository containing `.repository-quality-gates.json` as managed.
9. Treats an unmanaged repository as eligible for initial enrolment unless `.repository-quality-gates.local.json` sets `automaticEnrollment` to `false`.
10. Skips managed repositories already on the target version and refuses to downgrade a newer version.
11. Removes an RQG-marked pull request and branch that have remained open for 24 hours only when the exact temporary-branch pattern, expected base branch, same-repository head, and RQG provenance marker all match, then checks eligibility again.
12. Defers an eligible repository when any pull request is open and reports every blocking pull request.
13. Defers an empty repository until its first commit creates a usable default branch.
14. Clones the repository's default branch into a temporary runner folder.
15. Reads the downstream repository's optional `.repository-quality-gates.local.json` rules.
16. Detects repository contents and selects only applicable modules during initial enrolment, or applies the released template with managed pruning during an update.
17. Stops if an initial enrolment finds an undeclared overlapping workflow, a managed file was changed, or another deployment conflict is found.
18. Runs the public working-tree, detection-policy, module-drift, and staged secret checks.
19. Checks for open pull requests and the repository-owned enrolment opt-out again immediately before publishing the temporary branch.
20. Pushes `rqg/update-v<VERSION>` and opens an RQG-marked pull request.
21. Enables squash auto-merge and branch deletion for that pull request.

GitHub completes the merge only after the downstream repository's branch rules and required checks allow it. A failed check, conflict, missing prerequisite, or unavailable auto-merge leaves the pull request open and reports the repository as failed. While that RQG pull request remains open, later fleet runs defer the repository like any other repository with an open pull request.

The `rqg/update-v<VERSION>` namespace is reserved for temporary branches created by this automation. Each automation-created pull request carries an internal provenance marker. Expiry cleanup requires that marker, an exact versioned branch name, the expected base branch, and a same-repository head before it can close the pull request or request branch deletion. A successful squash merge deletes the branch immediately. A failure after publishing the branch causes the updater to close its pull request and delete its branch during the same run. If required checks leave an auto-merge pull request open, the next daily run removes it after 24 hours. This retains a short inspection window without accumulating long-lived update branches.

## Automatic Enrolment

Automatic enrolment is the default for every unmanaged repository visible to any installation of the scoped RQG GitHub App. The combined App installations therefore define the fleet. The next daily, release-triggered, or manual run detects a repository without managed state and prepares its first RQG deployment.

The enrolment process detects repository contents, selects the universal modules and applicable language or application modules, reads any committed `.repository-quality-gates.local.json` adjustments, validates the complete result, and uses the same temporary pull-request lifecycle as a normal update. After the pull request merges, `.repository-quality-gates.json` marks the repository as managed and future releases update it normally.

To exclude one repository before its first enrolment, commit this repository-owned file on its default branch:

```json
{
  "schemaVersion": 1,
  "automaticEnrollment": false
}
```

The property is optional and defaults to `true` when absent. The updater checks it during discovery and again immediately before publishing the first enrolment branch, so an opt-out added during preparation cancels publication. The opt-out affects only an unmanaged repository. After enrolment, `.repository-quality-gates.json` becomes the durable managed-state record and normal RQG updates continue. Open-pull-request checks, workflow-overlap checks, publication-safety scans, repository rules, required checks, and auto-merge requirements still apply to every eligible repository.

## Downstream Repository Rules

A downstream repository may contain `.repository-quality-gates.local.json`. The file belongs to that repository, is committed there, and is never copied from or overwritten by the central RQG template. Committing it is essential because the GitHub-hosted fleet updater cannot see an untracked file that exists only on a workstation.

```json
{
  "schemaVersion": 1,
  "automaticEnrollment": true,
  "modules": {
    "include": [],
    "repositoryOwned": []
  },
  "paths": {
    "repositoryOwned": []
  },
  "secretScanning": {
    "additionalConfigFiles": []
  },
  "pullRequest": {
    "references": ["OP#PROJECT-123"]
  }
}
```

| Setting | Purpose |
|---|---|
| `automaticEnrollment` | Optional Boolean. Set to `false` to keep an unmanaged repository outside automatic enrolment; absence defaults to `true` |
| `modules.include` | Install a named RQG module even when normal file detection does not select it |
| `modules.repositoryOwned` | Keep a repository's existing verified implementation of a detected or explicitly included module instead of deploying the RQG payload |
| `paths.repositoryOwned` | Preserve specific existing repository-relative files outside RQG managed state; every listed path must already be a regular file and cannot be the managed-state or local-rules file |
| `secretScanning.additionalConfigFiles` | Run additional committed repository-specific Gitleaks TOML policies as separate scan layers |
| `pullRequest.references` | Add one or more OpenProject work-package references to automated RQG pull requests; the project identifier also prefixes the pull-request title |

The file is declarative. It cannot run commands, change GitHub permissions, disable the universal secret-scanning or module-drift modules, or override managed files. Module IDs must exist in the released catalogue. A repository-owned module must still have matching workflow evidence, and each additional secret policy must be a contained repository-relative TOML file that does not traverse a symbolic link or junction. Pull-request references must use `OP#PROJECT-123`, must be unique, and must all belong to one OpenProject project. Omit `pullRequest` when the repository has no OpenProject mapping.

Older managed state that records preserved modules is migrated into this file during its first successful update. Legacy secret-scanning files return to central management only when each file matches a verified hash from a published RQG release. A customized root `.gitleaks.toml` may instead be recorded under `paths.repositoryOwned` when it still extends `security/gitleaks-portable.toml`; unknown or modified legacy files stop the update for review. After migration, the repository-owned file is the source of truth and the managed state contains only the resolved snapshot used for drift reporting.

## One-Time GitHub App Setup

Create a private GitHub App and install that same App on every account or organization whose selected repositories RQG may manage. The App owner does not need to be the owner of every downstream repository.

Use these repository permissions:

| Permission | Access | Purpose |
|---|---:|---|
| Contents | Read And Write | Read managed state and push the update branch |
| Pull Requests | Read And Write | Find or create the update pull request |
| Workflows | Read And Write | Add and update the GitHub Actions workflow files deployed by RQG |
| Checks | Read | Wait for and inspect every downstream pull-request quality check before merging |
| Metadata | Read | Required GitHub App repository metadata |

The app does not need issue, administration, secrets, Actions administration, deployment, package, or organization permissions. GitHub reports pull-request check-rollup data through the Checks permission, so omitting that read-only permission prevents the updater from verifying private-repository checks.

Install the App only on repositories that Repository Quality Gates may manage. The combined installations form the outer fleet allow-list. Within that scope, an existing managed-state file authorizes updates and an unmanaged repository is automatically eligible unless its committed repository rules opt out. The workflow discovers installations at runtime, so no owner names or repository inventory need to be stored in source, variables, or secrets.

If the App is installed for **All Repositories**, every newly created repository becomes eligible automatically. Commit the opt-out file before the next fleet run when a repository must remain unmanaged. If the App is installed for **Only Select Repositories**, adding a repository to the App installation makes it eligible unless it already contains the opt-out file.

For each selected downstream repository, enable **Allow Auto-Merge** and configure its default-branch rules so every required quality, build, and test check must pass before merging. This is a one-time repository-administration setting; the narrowly scoped updater App does not receive Administration permission to weaken or create those rules.

In the central `repository-quality-gates` repository:

1. Open **Settings** → **Secrets And Variables** → **Actions**.
2. Under **Variables**, create `RQG_APP_ID` containing the GitHub App ID.
3. Under **Secrets**, create `RQG_APP_PRIVATE_KEY` containing the complete private key generated for the app.
4. To receive a report after every rollout, create the `RQG_REPORT_EMAIL_ENABLED` variable with value `true`, the `RQG_REPORT_SMTP_HOST` and `RQG_REPORT_SMTP_PORT` variables, and the `RQG_REPORT_SMTP_USERNAME`, `RQG_REPORT_SMTP_PASSWORD`, `RQG_REPORT_FROM`, and `RQG_REPORT_TO` secrets.
5. Keep the private key and email credentials out of files, commits, workflow logs, and pull-request content.

The workflow exchanges these values for a short-lived App JWT, then creates a separate short-lived installation token for each installation. It never reuses one installation's token for another installation, copies no token or private key into a managed repository, masks discovered owner and full repository names before downstream log output, and requests revocation of each installation token when processing finishes.

## Workflow Triggers

The central `.github/workflows/automatic-release.yml` workflow runs on every push to `main` and can also be started manually. Only a stable `MAJOR.MINOR.PATCH` version can be published. Every release therefore requires a deliberate version and changelog update in the source commit, while publication itself occurs automatically after the required quality workflows pass.

The central `.github/workflows/update-managed-repositories.yml` workflow runs:

- immediately after the automatic release workflow explicitly dispatches it;
- after a stable GitHub Release is published by an external authorized actor;
- daily at its documented UTC schedule; and
- on a manual `workflow_dispatch` request.

The rollout job has a 120-minute overall limit. Each downstream pull request may wait up to 45 minutes for reported checks to finish, after allowing up to four minutes for the first check to appear. When email reporting is enabled, the workflow sends a final success or failure report after the rollout step, including the selected release, workflow-run link, and a Repository, Status, and Comment table. A failed row identifies the failing stage, captured cause, target version, pull request and temporary branch context when available, cleanup outcome, and a stage-specific investigation action. The repository-named JSON used to compose that table remains only in the rollout job workspace and is never uploaded. Every value registered with GitHub's masking controls is replaced before the separate diagnostic report artifact is persisted, and that sanitized artifact expires after one day. A rollout failure remains a workflow failure after the report is sent.

The automatic release passes its exact stable tag to the fleet workflow, and an externally published release supplies its event tag. Scheduled runs and manual runs without a tag resolve the latest published release. Every path verifies that the selected tag is a published, non-draft, non-prerelease stable semantic version and checks out that immutable tag before updating repositories. Development work on `main` therefore cannot be distributed before it becomes a release, and a release-triggered rollout cannot drift to a different release.

If a release-triggered run finds an open pull request, it records `DeferredOpenPullRequests` and does not clone, create a branch, push, or create an RQG pull request for that repository. The updater checks again immediately before its first push so a pull request opened during local preparation also causes deferral without a remote branch. The daily fallback checks again automatically. Once every pull request is closed or merged, the next run builds the update from the then-current default branch.

## Local Preview

Preview one repository without changing it:

```powershell
pwsh -NoProfile -File ".\scripts\Update-RepositoryQualityGates.ps1" -RepositoryPath "<REPOSITORY_PATH>"
```

Apply an update locally after reviewing the preview:

```powershell
pwsh -NoProfile -File ".\scripts\Update-RepositoryQualityGates.ps1" -RepositoryPath "<REPOSITORY_PATH>" -Apply
```

The local command changes files but does not commit, push, create a pull request, or merge.

## Conflict And Recovery Behavior

- A file whose current hash matches the previously recorded managed hash may be updated.
- A modified managed file stops the update and is preserved.
- Repository-owned files are not replaced.
- Files listed under `paths.repositoryOwned` are not added to managed state, overwritten, or pruned.
- Historical RQG files are adopted only when their content matches an exact verified release hash.
- `.repository-quality-gates.local.json` and every policy it names remain repository-owned and unmanaged.
- A repository on a newer template version is never downgraded.
- Unmanaged repositories are enrolled when the fleet workflow enables automatic enrolment, unless their committed repository rules set `automaticEnrollment` to `false`.
- Repositories with any open pull request are deferred without a branch, commit, push, or RQG pull request change.
- Successful RQG pull requests delete their temporary branch immediately after merge.
- Failed post-push preparation removes the RQG pull request and temporary branch in the same run.
- An RQG-marked auto-merge pull request still open after 24 hours is closed and its reserved temporary branch is deleted by the next daily run only when all provenance checks match.
- Temporary clones are deleted when the fleet run finishes.
- A failed repository is reported without preventing the updater from assessing the remaining repositories.

Move any intentional downstream customization out of an RQG-managed file and into the repository-owned rules, workflow, or additional policy file. Restore the managed file to its recorded RQG version, then rerun the central workflow. Do not force replacement until the repository-specific change has been reviewed and a recovery copy exists.

## Separate Dependency Updates

This workflow updates Repository Quality Gates itself. Package updates for npm, Python, .NET, PHP, Go, Docker, GitHub Actions, and other ecosystems are a separate capability. Those can be added through ecosystem-specific Dependabot configuration after their grouping, schedule, and compatibility rules are defined.
