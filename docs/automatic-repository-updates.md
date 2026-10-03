# Automatic Repository Updates

Repository Quality Gates can enrol unmanaged repositories and update its managed template across every account or organization where its GitHub App is installed, without storing a personal access token or publishing an owner inventory. The central workflow runs when a stable release is published, once each day, or when started manually. Every unmanaged repository visible to any installation is eligible unless its repository-owned rules file explicitly opts out. A downstream repository is changed only when it has no open pull requests. Each enrolment or update uses its own pull request so the downstream repository's required checks remain the merge gate, then GitHub merges the pull request automatically when those requirements pass.

The central `.github/workflows/automatic-release.yml` workflow creates that stable release from `main`. It waits for Documentation Quality, Fleet Update Quality, Licence Quality, Quality Gate Module Drift, Secret Scanning, and PowerShell Quality on the exact commit. It then confirms the commit is still current, verifies one stable semantic version across the deployment engine, managed state, and changelog, creates an annotated `v<VERSION>` tag, publishes the immutable GitHub Release, and explicitly dispatches the fleet workflow described below. The explicit dispatch is required because GitHub suppresses most new workflow events created by the repository's own `GITHUB_TOKEN`.

When Module Drift creates a reconciliation commit, it explicitly dispatches its own `validation_only` mode alongside the other validators. That mode checks the dispatched revision with read-only repository permissions, runs reconciliation locally, and fails if any tracked or untracked change remains. It cannot commit, push, or dispatch another run. A failure to dispatch this required validation stops the originating run. The fleet updater and operator-selected clone probe are excluded from this validation dispatch.

The release workflow binds every required result to both its exact workflow path and expected display name. It does nothing when the canonical version is unchanged and the matching release already exists. It skips prerelease versions and commits superseded on `main`. It fails closed when a required workflow fails, is missing, or is replaced by a same-name workflow at another path; when version metadata disagrees; when the changelog entry is missing; or when the version tag already identifies another commit. If tag creation succeeded but release creation was interrupted, a manual rerun can create the missing release only when the tag still identifies the exact validated commit.

## What The Automation Does

### Preview & Controlled Waves

Manual dispatch defaults to `mode=preview`. This enumerates accessible installations & repository eligibility without creating branches, changing repository files, closing pull requests, or merging. It is an eligibility preview, not a substitute for checkout, licence, test, or required-check validation.

Use `mode=apply` only after reviewing readiness. `wave_count` defaults to `1` & `wave_index` to `0`. For controlled waves, keep the same count & process indexes from zero through count minus one. Membership uses a hash of each normalized repository name, so discovery order does not affect it & no repository inventory is embedded in the workflow. Each repository belongs to exactly one wave. An empty wave produces no repository changes. Repeat discovery before final acceptance to cover repositories added during the rollout. Previews & intermediate waves do not send email. After accepting every wave, run one full-fleet apply with `wave_count=1`, `wave_index=0`, & `send_email=true` to verify convergence & receive one consolidated report.

Set the repository variable `RQG_FLEET_AUTOMATION_PAUSED=true` during remediation. Scheduled runs, release events & the automatic release workflow's explicit fleet dispatch then remain paused; an authorized manual preview or selected wave can still run. Clear the variable after controlled acceptance to resume full-fleet automation. Pausing fleet automation does not disable downstream required checks or alter merge eligibility.

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

The `rqg/update-v<VERSION>` namespace is reserved for temporary branches created by this automation. Each automation-created pull request carries an internal provenance marker. Expiry cleanup requires that marker, an exact versioned branch name, the expected base branch, and a same-repository head before it can close the pull request or request branch deletion. After a successful squash merge, the updater requests branch deletion & verifies that the exact branch is absent. If GitHub already deleted it automatically, authenticated absence still counts as successful cleanup. A remaining reference, failed readback or malformed response fails closed. A failure after publishing the branch causes the updater to close its pull request and delete its branch during the same run. If required checks leave an auto-merge pull request open, the next daily run removes it after 24 hours. This retains a short inspection window without accumulating long-lived update branches.

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
    "references": ["OP#IVT_MCP-55", "[IVT_MCP-56]"]
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
| `pullRequest.references` | Add validated OpenProject work-package shorthand to automated RQG pull requests using either `OP#PROJECT-123` or `[PROJECT-123]` |

The file is declarative. It cannot run commands, change GitHub permissions, disable the universal secret-scanning, module-drift, or repository-standards/documentation modules, or override managed files. Module IDs must exist in the released catalogue. A repository-owned module must still have matching workflow evidence, and each additional secret policy must be a contained repository-relative TOML file that does not traverse a symbolic link or junction. Pull-request references must be valid work-package display IDs in one of the two approved shorthand forms, must be unique, and must all belong to one OpenProject project.

GitHub artifacts continue to use GitHub-native issue, discussion, pull-request, and commit references. The optional OpenProject shorthand is non-locating: an OpenProject hostname, URL, path, API endpoint, instruction, numeric API ID, or bare project identifier remains prohibited.

Older managed state that records preserved modules is migrated into this file during its first successful update. Legacy secret-scanning files return to central management only when each file matches a verified hash from a published RQG release. A customized root `.gitleaks.toml` may instead be recorded under `paths.repositoryOwned` when it still extends `security/gitleaks-portable.toml`; unknown or modified legacy files stop the update for review. After migration, the repository-owned file is the source of truth and the managed state contains only the resolved snapshot used for drift reporting.

## One-Time GitHub App Setup

Create a private GitHub App and install that same App on every account or organization whose selected repositories RQG may manage. The App owner does not need to be the owner of every downstream repository.

Use these repository permissions:

| Permission | Access | Purpose |
|---|---:|---|
| Actions | Read | Read workflow jobs so rollout reports can identify the repository-specific self-hosted runners actually used |
| Contents | Read And Write | Read managed state and push the update branch |
| Pull Requests | Read And Write | Find or create the update pull request |
| Workflows | Read And Write | Add and update the GitHub Actions workflow files deployed by RQG |
| Checks | Read | Wait for and inspect every downstream pull-request quality check before merging |
| Metadata | Read | Required GitHub App repository metadata |

The app does not need issue, administration, secrets, Actions write, deployment, package, or organization permissions. Checks read access verifies private-repository quality results. Actions read access is limited to workflow-run and job metadata used to name the actual downstream runners in the private rollout report; it does not grant access to Actions secrets or permit workflow administration.

Install the App only on repositories that Repository Quality Gates may manage. The combined installations form the outer fleet allow-list. Within that scope, an existing managed-state file authorizes updates and an unmanaged repository is automatically eligible unless its committed repository rules opt out. The workflow discovers installations at runtime, so no owner names or repository inventory need to be stored in source, variables, or secrets.

If the App is installed for **All Repositories**, every newly created repository becomes eligible automatically. Commit the opt-out file before the next fleet run when a repository must remain unmanaged. If the App is installed for **Only Select Repositories**, adding a repository to the App installation makes it eligible unless it already contains the opt-out file.

For each selected public downstream repository, configure active default-branch rules so every applicable RQG quality, build, and test check must pass before the branch can be updated. This is a one-time repository-administration setting; the narrowly scoped updater App does not receive Administration permission to weaken or create those rules. The updater reads the effective active branch rules through its Metadata permission immediately before publishing an update branch and again immediately before merge. A missing expected required check stops the repository before publication or merge with `RequiredChecksNotEnforced`.

Use `scripts/Get-RepositoryQualityGateRequiredCheckPlan.ps1` to produce a read-only JSON plan before changing repository rules. The planner accepts the dynamically discovered repository list, reads each repository's managed module set and active default-branch rules, and reports the exact expected, present, and missing checks. `ConfigureGitHubRules` identifies a public repository that needs an administration change. The planner never creates or changes a rule.

Private repositories use native GitHub required-check rules whenever GitHub exposes them. When the effective-rules endpoint returns the specifically recognized current-plan limitation for a private repository, policy exception `RQG-PRIVATE-PLAN-001` permits the RQG verified merge path. The exception requires all eight controls recorded in `policy/required-check-enforcement.json`: expected checks derived from deployed modules, every expected check observed, every observed execution accepted, a stable check set, exact head and base reverified, merge pinned to the verified head, default-branch version verified, and every unverified state failed closed. The updater records the control mode and exception identifier, then proves the same control again immediately before merge.

The exception does not accept an incomplete rule set, a generic permission or authentication failure, a missing check, a changed head or base, an unstable check set, or an unverifiable default-branch result. Public repositories cannot use it. The exception controls the RQG automation path; repository owners and other independently authorized writers remain able to make writes outside that path when the hosting plan cannot enforce branch rules. That residual platform limitation must remain explicit in private operational records.

In the central `repository-quality-gates` repository:

1. Open **Settings** → **Secrets And Variables** → **Actions**.
2. Under **Variables**, create `RQG_APP_ID` containing the GitHub App ID.
3. Under **Secrets**, create `RQG_APP_PRIVATE_KEY` containing the complete private key generated for the app.
4. To receive one consolidated report for each released version, create the `RQG_REPORT_EMAIL_ENABLED` variable with value `true`, the `RQG_REPORT_SMTP_HOST` and `RQG_REPORT_SMTP_PORT` variables, and the `RQG_REPORT_SMTP_USERNAME`, `RQG_REPORT_SMTP_PASSWORD`, `RQG_REPORT_FROM_EMAIL`, and `RQG_REPORT_TO_EMAIL` secrets. The optional `RQG_REPORT_FROM_NAME` and `RQG_REPORT_TO_NAME` secrets set the corresponding display names; when either is absent or empty, the workflow uses that mailbox's email address as its display name. Release-triggered full-fleet applies request the report automatically. Manual reporting additionally requires `mode=apply`, `wave_count=1`, `wave_index=0`, and `send_email=true`. Previews, scheduled checks, and intermediate waves remain silent.
5. Keep the private key and email credentials out of files, commits, workflow logs, and pull-request content.

The workflow exchanges these values for a short-lived App JWT, then creates a separate short-lived installation token for each installation. It never reuses one installation's token for another installation, copies no token or private key into a managed repository, masks discovered owner and full repository names before downstream log output, and requests revocation of each installation token when processing finishes.

## Read-Only GitHub App Clone Probe

The manual **GitHub App Clone Probe** workflow proves that the configured App can discover and clone one selected repository without starting a fleet update. To keep a private repository name out of workflow inputs and run metadata, the workflow accepts the lowercase SHA-256 of the lowercase `owner/repository` name rather than the name itself. The probe discovers the App installations, selects the one repository matching that digest, performs a temporary no-checkout clone with the short-lived installation token, verifies its `HEAD`, removes the clone, and revokes the token. It does not enrol, update, commit, push, create a pull request, merge, or send a fleet email.

Calculate the input locally:

```powershell
$Repository = '<owner>/<repository>'; $Bytes = [Text.Encoding]::UTF8.GetBytes($Repository.ToLowerInvariant()); $Hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant(); $Hash
```

Run the workflow only from an exact reviewed RQG revision. A missing digest match, App authentication failure, repository-discovery failure, clone failure, unverifiable `HEAD`, or cleanup failure stops the probe.

## Workflow Triggers

The central `.github/workflows/automatic-release.yml` workflow runs on every push to `main` and can also be started manually. Only a stable `MAJOR.MINOR.PATCH` version can be published. Every release therefore requires a deliberate version and changelog update in the source commit, while publication itself occurs automatically after the required quality workflows pass.

The central `.github/workflows/update-managed-repositories.yml` workflow runs:

- immediately after the automatic release workflow explicitly dispatches it;
- after a stable GitHub Release is published by an external authorized actor;
- daily at its documented UTC schedule; and
- on a manual `workflow_dispatch` request.

The rollout job has a 120-minute overall limit. Each downstream pull request may wait up to 45 minutes for reported checks to finish, after allowing up to four minutes for every expected check to appear and requiring a stable completed check set before merge. The updater also requires effective default-branch rules to name every expected check and pins the merge request to the exact verified head commit. When email reporting is enabled, one automatic release-triggered full-fleet apply sends the version's final success or failure report after the rollout step, including the selected release, workflow-run link, and Repository, Visibility, Runner, Status, and Comment columns. Preview, scheduled, and controlled-wave invocations do not send email. An authorized final manual full-fleet apply can send the consolidated report only when `send_email=true`. Each status identifies the actual terminal state instead of collapsing failures into a generic result. Examples include `UpdatedSuccessfully`, `RequiresLicenceDecision`, `FailedChecks`, `RequiredChecksNotEnforced`, `ManagedFileConflict`, `CloneFailed`, `CheckDiscoveryFailed`, `MergedWithFailedChecks`, `MergedCleanupRequired`, `DeferredOpenPullRequests`, and `Current`. A failed row identifies the failing stage, captured cause, target version, pull request and temporary branch context when available, cleanup outcome, and a stage-specific investigation action. The repository-named JSON used to compose that table remains only in the rollout job workspace and is never uploaded. Every value registered with GitHub's masking controls is replaced before the separate diagnostic report artifact is persisted, and that sanitized artifact expires after one day. A rollout failure remains a workflow failure after the report is sent.

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

### Preview & Apply Reports

The email renderer retains separate Fleet Preview & Fleet Rollout wording for regression coverage, but operational previews remain silent. Available means an update was detected, not installed. The automatic release-triggered full-fleet apply sends one Fleet Rollout report. Controlled waves remain silent, and a final manual convergence apply sends a report only when `send_email=true`; each row records its own verified result. A successful workflow is not a claim that every repository was updated.
