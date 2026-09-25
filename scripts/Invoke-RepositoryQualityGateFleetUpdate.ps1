# SPDX-License-Identifier: MIT
[CmdletBinding()]
param(
    [string]$Owner,
    [string[]]$Repository = @(),
    [string]$TemplateRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$TargetVersion,
    [switch]$AutoEnroll,
    [switch]$Apply,
    [switch]$AutoMerge,
    [ValidateRange(1, 168)][int]$TemporaryBranchLifetimeHours = 24,
    [ValidateSet('Text', 'Json')][string]$OutputFormat = 'Text',
    [string]$ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI is required.' }
if (-not $env:GH_TOKEN) { throw 'GH_TOKEN must contain a GitHub App installation token.' }
$templateRootFull = [IO.Path]::GetFullPath($TemplateRoot)
$updateScript = Join-Path $templateRootFull 'scripts\Update-RepositoryQualityGates.ps1'
$deploymentTool = Join-Path $templateRootFull 'scripts\Invoke-RepositoryQualityGates.ps1'
if (-not (Test-Path -LiteralPath $updateScript -PathType Leaf)) { throw 'The repository updater is missing.' }

function Get-OpenPullRequests([string]$RepositoryName) {
    $output = @(& gh pr list --repo $RepositoryName --state open --limit 1000 --json number,title,url,headRefName,baseRefName,isCrossRepository,body,createdAt 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Unable to inspect open pull requests: $($output -join [Environment]::NewLine)" }
    $text = ($output -join [Environment]::NewLine).Trim()
    if (-not $text) { return @() }
    return @(($text | ConvertFrom-Json))
}

function Get-WorkflowRunnerNames([string]$RepositoryName, [object[]]$Checks) {
    $runIds = [Collections.Generic.HashSet[long]]::new()
    foreach ($check in @($Checks)) {
        $detailsUrl = if ($check.PSObject.Properties['details_url']) { [string]$check.details_url } else { '' }
        if ($detailsUrl -match '/actions/runs/(?<id>[1-9]\d*)(?:/|$)') { $null = $runIds.Add([long]$Matches.id) }
    }

    $runnerNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($runId in @($runIds | Sort-Object)) {
        $output = @(& gh api --paginate -H 'Accept: application/vnd.github+json' "repos/$RepositoryName/actions/runs/$runId/jobs?per_page=100" --jq '.jobs[] | .runner_name // empty' 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Unable to inspect workflow runner assignments: $($output -join [Environment]::NewLine)" }
        foreach ($runnerName in @($output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })) {
            $null = $runnerNames.Add($runnerName)
        }
    }
    $sortedRunnerNames = @($runnerNames | Sort-Object)
    foreach ($runnerName in $sortedRunnerNames) {
        Write-Host "::add-mask::$runnerName"
    }
    return $sortedRunnerNames
}

function Wait-PullRequestQualityChecks([string]$RepositoryName, [string]$PullRequestUrl) {
    if ($PullRequestUrl -notmatch '/pull/(?<number>\d+)(?:[/?#]|$)') { throw 'The pull-request URL does not contain a pull-request number.' }
    $pullRequestNumber = [int]$Matches.number
    $headOutput = @(& gh api "repos/$RepositoryName/pulls/$pullRequestNumber" --jq .head.sha 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Unable to inspect the pull-request head commit: $($headOutput -join [Environment]::NewLine)" }
    $headSha = ($headOutput -join [Environment]::NewLine).Trim()
    if ($headSha -notmatch '^[0-9a-fA-F]{40}$') { throw 'GitHub returned an invalid pull-request head commit.' }

    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(45)
    $discoveryDeadline = [DateTimeOffset]::UtcNow.AddMinutes(4)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        # Read the Checks API directly. GitHub's GraphQL rollup also expands
        # workflow-run metadata, which requires broader Actions access even
        # though RQG only needs each check's name, status, and conclusion.
        $output = @(& gh api --paginate -H 'Accept: application/vnd.github+json' "repos/$RepositoryName/commits/$headSha/check-runs?per_page=100" --jq '.check_runs[] | {name,status,conclusion,details_url}' 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Unable to inspect pull-request quality checks: $($output -join [Environment]::NewLine)" }
        $text = ($output -join [Environment]::NewLine).Trim()
        try { $checks = @($output | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) }
        catch { throw 'GitHub returned invalid pull-request quality-check data.' }
        if (-not $checks.Count) {
            if ([DateTimeOffset]::UtcNow -ge $discoveryDeadline) { throw 'No quality checks were reported for the update pull request.' }
            Start-Sleep -Seconds 5
            continue
        }

        $pending = [Collections.Generic.List[string]]::new()
        $failed = [Collections.Generic.List[string]]::new()
        foreach ($check in $checks) {
            $name = if ($check.PSObject.Properties['name']) { [string]$check.name } else { 'Unnamed Check' }
            if ([string]$check.status -ne 'completed') { $pending.Add($name); continue }
            if ([string]$check.conclusion -notin @('success', 'neutral', 'skipped')) { $failed.Add("$name ($($check.conclusion))") }
        }
        # Do not remove the temporary branch while another check is still
        # running. A workflow that is checking out that branch would then fail
        # for the wrong reason and hide the original result.
        if ($pending.Count) { Start-Sleep -Seconds 10; continue }
        $runnerNames = @(Get-WorkflowRunnerNames -RepositoryName $RepositoryName -Checks $checks)
        if ($failed.Count) {
            $exception = [InvalidOperationException]::new("Pull-request quality checks failed: $($failed -join ', ')")
            $exception.Data['RunnerNames'] = $runnerNames
            throw $exception
        }
        return [pscustomobject]@{ checkCount = $checks.Count; runnerNames = $runnerNames }
    }
    throw 'Timed out waiting for pull-request quality checks to complete.'
}

function Get-RemoteTextFile([string]$RepositoryName, [string]$DefaultBranch, [string]$RelativePath) {
    $output = @(& gh api "repos/$RepositoryName/contents/$RelativePath`?ref=$DefaultBranch" --jq .content 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $errorText = ($output -join [Environment]::NewLine)
        if ($errorText -match '(?i)HTTP\s+404') { return [pscustomobject]@{ exists = $false; content = $null } }
        throw "Unable to inspect repository file '$RelativePath'."
    }
    $encoded = (($output -join '') -replace '\s', '')
    if (-not $encoded) { throw "Repository file '$RelativePath' returned no content." }
    try { $content = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) }
    catch { throw "Repository file '$RelativePath' is not valid base64 content." }
    return [pscustomobject]@{ exists = $true; content = $content }
}

function Test-AutomaticEnrollmentEnabled([string]$RepositoryName, [string]$DefaultBranch) {
    $rulesFile = Get-RemoteTextFile $RepositoryName $DefaultBranch '.repository-quality-gates.local.json'
    if (-not $rulesFile.exists) { return $true }
    try { $remoteRules = $rulesFile.content | ConvertFrom-Json }
    catch { throw 'The downstream repository rules file is not valid JSON.' }
    if (-not $remoteRules.PSObject.Properties['automaticEnrollment']) { return $true }
    if ($remoteRules.automaticEnrollment -isnot [bool]) { throw 'The downstream automaticEnrollment rule must be true or false.' }
    return [bool]$remoteRules.automaticEnrollment
}

function Get-PullRequestReferences([string]$RepositoryPath) {
    $rulesPath = Join-Path $RepositoryPath '.repository-quality-gates.local.json'
    if (-not (Test-Path -LiteralPath $rulesPath -PathType Leaf)) { return @() }
    try { $rules = Get-Content -LiteralPath $rulesPath -Raw | ConvertFrom-Json }
    catch { throw 'The downstream repository rules file is not valid JSON.' }
    if (-not $rules.PSObject.Properties['pullRequest']) { return @() }
    $pullRequestRules = $rules.pullRequest
    foreach ($property in @($pullRequestRules.PSObject.Properties.Name)) {
        if ($property -ne 'references') { throw "Unsupported downstream pullRequest rule: $property" }
    }
    if (-not $pullRequestRules.PSObject.Properties['references'] -or $null -eq $pullRequestRules.references) { return @() }
    if ($pullRequestRules.references -is [string] -or $pullRequestRules.references -isnot [Collections.IEnumerable]) {
        throw 'The downstream pullRequest.references rule must be an array of OpenProject references.'
    }
    $references = @($pullRequestRules.references | ForEach-Object {
        if ($_ -isnot [string] -or $_ -notmatch '^OP#[A-Z][A-Z0-9_]{1,31}-[1-9][0-9]*$') {
            throw 'Each downstream pullRequest reference must use the form OP#PROJECT-123.'
        }
        $_
    })
    if (@($references | Sort-Object -Unique).Count -ne $references.Count) { throw 'The downstream pullRequest references contain duplicates.' }
    $projectIdentifiers = @($references | ForEach-Object { ($_ -replace '^OP#', '') -replace '-[1-9][0-9]*$', '' } | Sort-Object -Unique)
    if ($projectIdentifiers.Count -gt 1) { throw 'All downstream pullRequest references must belong to the same OpenProject project.' }
    return @($references)
}

function Get-RqgInvestigationAction([string]$Stage) {
    switch -Regex ($Stage) {
        '^Repository metadata' { return 'Confirm the repository has a readable default branch and that the GitHub App has Metadata and Contents read access.' }
        '^Managed-state inspection' { return 'Inspect .repository-quality-gates.json and .repository-quality-gates.local.json on the default branch, correct invalid JSON or unsupported values, then rerun the rollout.' }
        '^Open pull-request inspection' { return 'Review the repository pull-request list, merge or close blocking work, and rerun the rollout after the repository is clear.' }
        '^Repository clone' { return 'Confirm the default branch exists and the GitHub App can read repository contents, then retry the clone with the App installation permissions.' }
        '^Managed-file update' { return 'Run the RQG updater in preview mode for this repository, review every reported managed-path conflict or repository-owned override, resolve the conflict deliberately, and rerun the rollout.' }
        '^Publication-safety scan' { return 'Inspect the staged secret-scan finding without copying sensitive values into logs or email, remove or explicitly govern the offending content, and rerun the rollout.' }
        '^Update commit' { return 'Inspect the staged RQG changes and local Git error, correct the repository-specific commit blocker, and rerun the rollout.' }
        '^Update branch push' { return 'Verify Contents write access, branch rules, and any existing RQG update branch; remove an obsolete branch only after confirming it is RQG-owned, then rerun.' }
        '^Update pull-request creation' { return 'Verify Pull requests write access and branch-policy requirements, inspect any existing RQG pull request, and rerun after resolving the conflict.' }
        '^Pull-request quality-check discovery' { return 'Open the update pull request and its Checks tab, confirm the expected workflows are enabled and triggered for the update branch, then rerun after check runs appear.' }
        '^Pull-request quality checks' { return 'Open the update pull request Checks tab, inspect each named failing check and its job log, correct the downstream repository failure, then rerun the rollout.' }
        '^Verified pull-request merge' { return 'Inspect branch protection, required reviews, mergeability, and the GitHub App Pull requests and Contents permissions; resolve the reported merge blocker and rerun.' }
        '^Temporary branch cleanup' { return 'The update merged. Remove the identified RQG-owned temporary branch after confirming the merge, then verify the repository reports the target RQG version.' }
        default { return 'Review the reported cause and the repository Actions and pull-request history, correct the repository-specific blocker, and rerun the rollout.' }
    }
}

function New-RqgFailureComment {
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Cause,
        [Parameter(Mandatory)][string]$Version,
        [string]$PullRequestUrl,
        [string]$UpdateBranch,
        [string]$Cleanup
    )

    $context = "Target RQG version: $Version."
    if (-not [string]::IsNullOrWhiteSpace($PullRequestUrl)) { $context += " Pull request: $PullRequestUrl." }
    if (-not [string]::IsNullOrWhiteSpace($UpdateBranch)) { $context += " Update branch: $UpdateBranch." }
    $cleanupText = if ([string]::IsNullOrWhiteSpace($Cleanup)) { 'Cleanup: No temporary RQG resource required cleanup.' } else { "Cleanup: $Cleanup" }
    return "Stage: $Stage. Cause: $Cause Context: $context $cleanupText Investigation: $(Get-RqgInvestigationAction $Stage)"
}

if (-not $TargetVersion) {
    $versionOutput = @(& $deploymentTool -Version)
    $TargetVersion = ([string]$versionOutput[0] -replace '^Repository Quality Gates\s+', '').Trim()
}
if (-not $Repository.Count) {
    $Repository = @(& gh api --paginate /installation/repositories --jq '.repositories[].full_name' | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate repositories installed for the GitHub App.' }
}
if (-not $Owner -and -not $Repository.Count) { throw 'No repositories are available to update.' }
$sourceRemote = (& git -C $templateRootFull config --get remote.origin.url 2>$null)
$sourceName = if ($sourceRemote -match 'github\.com[:/](?<name>[^/]+/[^/.]+)(?:\.git)?$') { $Matches.name } else { $null }
$branchName = "rqg/update-v$TargetVersion"
$rqgBranchPattern = '^rqg/update-v(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$'
$rqgPullRequestMarker = '<!-- repository-quality-gates-fleet-update -->'
$results = [Collections.Generic.List[object]]::new()
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('rqg-fleet-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
    foreach ($fullName in @($Repository | Sort-Object -Unique)) {
        $entry = [ordered]@{ repository = $fullName; status = 'Skipped'; enrolment = $false; pullRequest = $null; autoMerge = $false; runners = @(); blockingPullRequests = @(); cleanedPullRequests = @(); detail = $null }
        $clonePath = $null
        $pushedUpdateBranch = $false
        $failureStage = 'Repository metadata and eligibility inspection'
        try {
            if ($sourceName -and $fullName -ieq $sourceName) { $entry.detail = 'Central template repository.'; $results.Add([pscustomobject]$entry); continue }
            if ($fullName -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw "Invalid repository name: $fullName" }
            if ($Owner -and ($fullName -split '/')[0] -ine $Owner) { $entry.detail = 'Repository is outside the selected owner.'; $results.Add([pscustomobject]$entry); continue }

            $failureStage = 'Repository metadata inspection'
            $metadataText = @(& gh api "repos/$fullName" --jq '{defaultBranch:.default_branch,size:.size}' 2>$null) -join [Environment]::NewLine
            if ($LASTEXITCODE -ne 0 -or -not $metadataText) { throw 'Unable to read repository metadata.' }
            try { $metadata = $metadataText | ConvertFrom-Json }
            catch { throw 'GitHub returned invalid repository metadata.' }
            $defaultBranch = ([string]$metadata.defaultBranch).Trim()
            if ([long]$metadata.size -eq 0) {
                $entry.status = 'EmptyRepository'
                $entry.detail = 'The repository has no commits. Automatic enrolment will be retried after its first commit.'
                $results.Add([pscustomobject]$entry)
                continue
            }
            if (-not $defaultBranch) { throw 'The repository does not identify a default branch.' }
            $failureStage = 'Managed-state inspection'
            $stateFile = Get-RemoteTextFile $fullName $defaultBranch '.repository-quality-gates.json'
            $isManaged = [bool]$stateFile.exists
            $remoteState = $null
            if ($isManaged) {
                try { $remoteState = $stateFile.content | ConvertFrom-Json }
                catch { throw 'The remote managed-state file is not valid JSON.' }
                if ([string]$remoteState.templateVersion -eq $TargetVersion) { $entry.status = 'Current'; $results.Add([pscustomobject]$entry); continue }
            } else {
                if (-not $AutoEnroll) { $entry.detail = 'Repository is not managed by Repository Quality Gates.'; $results.Add([pscustomobject]$entry); continue }
                if (-not (Test-AutomaticEnrollmentEnabled $fullName $defaultBranch)) {
                    $entry.status = 'EnrollmentOptOut'
                    $entry.detail = 'The downstream repository rules file opts out of automatic enrolment.'
                    $results.Add([pscustomobject]$entry)
                    continue
                }
                $entry.enrolment = $true
            }

            $failureStage = 'Open pull-request inspection'
            $openPullRequests = @(Get-OpenPullRequests $fullName)
            if ($Apply -and $openPullRequests.Count) {
                $expiry = [DateTimeOffset]::UtcNow.AddHours(-$TemporaryBranchLifetimeHours)
                $expiredRqgPullRequests = @($openPullRequests | Where-Object {
                    ([string]$_.headRefName) -match $rqgBranchPattern -and
                    ([string]$_.baseRefName) -eq $defaultBranch -and
                    -not [bool]$_.isCrossRepository -and
                    ([string]$_.body).IndexOf($rqgPullRequestMarker, [StringComparison]::Ordinal) -ge 0 -and
                    [DateTimeOffset]::Parse([string]$_.createdAt) -le $expiry
                })
                foreach ($expired in $expiredRqgPullRequests) {
                    $closeOutput = @(& gh pr close ([string]$expired.url) --repo $fullName --delete-branch 2>&1)
                    if ($LASTEXITCODE -ne 0) { throw "Unable to remove expired RQG pull request #$($expired.number): $($closeOutput -join [Environment]::NewLine)" }
                    $entry.cleanedPullRequests += [pscustomobject]@{ number = [int]$expired.number; url = [string]$expired.url }
                }
                if ($expiredRqgPullRequests.Count) { $openPullRequests = @(Get-OpenPullRequests $fullName) }
            }
            if ($openPullRequests.Count) {
                $entry.status = 'DeferredOpenPullRequests'
                $entry.blockingPullRequests = @($openPullRequests | ForEach-Object {
                    [pscustomobject]@{ number = [int]$_.number; title = [string]$_.title; url = [string]$_.url }
                })
                $entry.detail = "$($openPullRequests.Count) open pull request(s) must be closed or merged before Repository Quality Gates can update this repository."
                $results.Add([pscustomobject]$entry)
                continue
            }

            if (-not $Apply) {
                $entry.status = if ($entry.enrolment) { 'EnrollmentAvailable' } else { 'Available' }
                $entry.detail = if ($entry.enrolment) { 'Repository is eligible for automatic enrolment.' } else { "Current version: $($remoteState.templateVersion)" }
                $results.Add([pscustomobject]$entry)
                continue
            }

            $failureStage = 'Repository clone'
            $clonePath = Join-Path $tempRoot (($fullName -replace '/', '-') + '-' + [guid]::NewGuid().ToString('N'))
            $null = @(& gh repo clone $fullName $clonePath -- --branch $defaultBranch --single-branch 2>&1)
            if ($LASTEXITCODE -ne 0) { throw 'Unable to clone the repository.' }
            & git -C $clonePath checkout -B $branchName | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Unable to create the update branch.' }

            $updateArguments = @{
                RepositoryPath = $clonePath
                TemplateRoot = $templateRootFull
                TargetVersion = $TargetVersion
                Apply = $true
                OutputFormat = 'Json'
            }
            if ($entry.enrolment) { $updateArguments.Enroll = $true }
            $failureStage = 'Managed-file update'
            $updateText = @(& $updateScript @updateArguments) -join [Environment]::NewLine
            $update = $updateText | ConvertFrom-Json
            if ($update.status -notin @('Updated', 'Enrolled')) { $entry.status = [string]$update.status; $results.Add([pscustomobject]$entry); continue }

            & git -C $clonePath add -A
            if ($LASTEXITCODE -ne 0) { throw 'Unable to stage the update.' }
            $stagedPaths = @(& git -C $clonePath diff --cached --name-only --diff-filter=ACDMRTUXB | Where-Object { $_ })
            if (-not $stagedPaths.Count) { $entry.status = 'Current'; $results.Add([pscustomobject]$entry); continue }
            $failureStage = 'Publication-safety scan'
            $null = @(& pwsh -NoLogo -NoProfile -File (Join-Path $clonePath 'scripts\Test-Secrets.ps1') -Mode Staged -Repository $clonePath 2>&1)
            if ($LASTEXITCODE -ne 0) { throw 'The staged publication-safety scan failed.' }
            & git -C $clonePath config user.name 'github-actions[bot]'
            & git -C $clonePath config user.email '41898282+github-actions[bot]@users.noreply.github.com'
            $commitMessage = if ($entry.enrolment) { "chore: enrol in Repository Quality Gates $TargetVersion" } else { "chore: update Repository Quality Gates to $TargetVersion" }
            $failureStage = 'Update commit'
            & git -C $clonePath commit -m $commitMessage | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Unable to commit the update.' }

            $failureStage = 'Open pull-request inspection after update preparation'
            $lateOpenPullRequests = @(Get-OpenPullRequests $fullName)
            if ($lateOpenPullRequests.Count) {
                $entry.status = 'DeferredOpenPullRequests'
                $entry.blockingPullRequests = @($lateOpenPullRequests | ForEach-Object {
                    [pscustomobject]@{ number = [int]$_.number; title = [string]$_.title; url = [string]$_.url }
                })
                $entry.detail = "$($lateOpenPullRequests.Count) pull request(s) opened while the update was being prepared. No RQG branch was pushed."
                $results.Add([pscustomobject]$entry)
                continue
            }

            if ($entry.enrolment -and -not (Test-AutomaticEnrollmentEnabled $fullName $defaultBranch)) {
                $entry.status = 'EnrollmentOptOut'
                $entry.detail = 'The downstream repository opted out while automatic enrolment was being prepared. No RQG branch was pushed.'
                $results.Add([pscustomobject]$entry)
                continue
            }

            $failureStage = 'Update branch push'
            & git -C $clonePath fetch origin "+refs/heads/$branchName`:refs/remotes/origin/$branchName" 2>$null
            $remoteUpdate = (& git -C $clonePath rev-parse --verify "refs/remotes/origin/$branchName" 2>$null)
            if ($LASTEXITCODE -eq 0 -and $remoteUpdate) {
                & git -C $clonePath push "--force-with-lease=refs/heads/$branchName`:$($remoteUpdate.Trim())" origin "HEAD:refs/heads/$branchName" | Out-Null
            } else {
                & git -C $clonePath push origin "HEAD:refs/heads/$branchName" | Out-Null
            }
            if ($LASTEXITCODE -ne 0) { throw 'Unable to push the update branch.' }
            $pushedUpdateBranch = $true

            $failureStage = 'Update pull-request creation'
            $existingPrOutput = @(& gh pr list --repo $fullName --state open --head $branchName --base $defaultBranch --json number,url --jq '.[0].url // empty')
            $existingPr = ($existingPrOutput -join [Environment]::NewLine).Trim()
            if ($LASTEXITCODE -ne 0) { throw 'Unable to check for an existing update pull request.' }
            if ($existingPr) { $entry.pullRequest = $existingPr }
            else {
                $bodyPath = Join-Path $clonePath 'rqg-pr-body.md'
                $pullRequestReferences = @(Get-PullRequestReferences $clonePath)
                $referenceText = if ($pullRequestReferences.Count) { "`nOpenProject: $($pullRequestReferences -join ', ')`n" } else { '' }
                $body = if ($entry.enrolment) {
                    "$rqgPullRequestMarker`n$referenceText`nEnrols this repository in Repository Quality Gates $TargetVersion under the central automatic-enrolment policy.`n`nThe enrolment detected the repository contents, selected only applicable modules, preserved repository-owned files and rules, and passed the public working-tree and staged secret scans before creating this pull request.`n`nGitHub will merge only after the repository's required checks pass.`n"
                } else {
                    "$rqgPullRequestMarker`n$referenceText`nUpdates the managed Repository Quality Gates files to $TargetVersion.`n`nThe updater preserved repository-owned files, stopped on managed-file conflicts, and passed the public working-tree and staged secret scans before creating this pull request.`n`nGitHub will merge only after the repository's required checks pass.`n"
                }
                [IO.File]::WriteAllText($bodyPath, $body, [Text.UTF8Encoding]::new($false))
                $projectPrefix = if ($pullRequestReferences.Count) { '[' + (($pullRequestReferences[0] -replace '^OP#', '') -replace '-[1-9][0-9]*$', '') + '] ' } else { '' }
                $pullRequestTitle = $projectPrefix + $(if ($entry.enrolment) { "chore: enrol in Repository Quality Gates $TargetVersion" } else { "chore: update Repository Quality Gates to $TargetVersion" })
                $entry.pullRequest = ([string](& gh pr create --repo $fullName --base $defaultBranch --head $branchName --title $pullRequestTitle --body-file $bodyPath)).Trim()
                if ($LASTEXITCODE -ne 0 -or -not $entry.pullRequest) { throw 'Unable to create the update pull request.' }
            }
            if ($AutoMerge) {
                $entry.status = 'ChecksPending'
            } else {
                $entry.status = 'PullRequest'
            }
            $entry.detail = "$($stagedPaths.Count) managed path(s) changed."
        }
        catch {
            $failureCause = $_.Exception.Message
            $cleanupDetail = $null
            if ($Apply -and $entry.pullRequest) {
                $cleanupOutput = @(& gh pr close ([string]$entry.pullRequest) --repo $fullName --delete-branch 2>&1)
                if ($LASTEXITCODE -eq 0) {
                    $pushedUpdateBranch = $false
                    $cleanupDetail = 'The failed temporary RQG pull request and branch were removed.'
                } else {
                    $cleanupDetail = "Temporary RQG pull-request cleanup failed: $($cleanupOutput -join [Environment]::NewLine)"
                }
            } elseif ($Apply -and $pushedUpdateBranch -and $clonePath) {
                $cleanupOutput = @(& git -C $clonePath push origin --delete $branchName 2>&1)
                if ($LASTEXITCODE -eq 0) {
                    $pushedUpdateBranch = $false
                    $cleanupDetail = 'The failed temporary RQG branch was removed.'
                } else {
                    $cleanupDetail = "Temporary RQG branch cleanup failed: $($cleanupOutput -join [Environment]::NewLine)"
                }
            }
            $entry.status = 'Failed'
            $entry.detail = New-RqgFailureComment -Stage $failureStage -Cause $failureCause -Version $TargetVersion -PullRequestUrl ([string]$entry.pullRequest) -UpdateBranch $branchName -Cleanup $cleanupDetail
            Write-Warning "Repository Quality Gates update failed for '$fullName': $($entry.detail)"
        }
        $results.Add([pscustomobject]$entry)
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($Apply -and $AutoMerge) {
    foreach ($entry in @($results | Where-Object status -eq 'ChecksPending')) {
        try {
            $repositoryName = [string]$entry.repository
            $pullRequestUrl = [string]$entry.pullRequest
            $failureStage = 'Pull-request quality-check discovery and completion'
            $checkResult = Wait-PullRequestQualityChecks $repositoryName $pullRequestUrl
            $checkCount = [int]$checkResult.checkCount
            $entry.runners = @($checkResult.runnerNames)
            if ($pullRequestUrl -notmatch '/pull/(?<number>[1-9]\d*)/?$') { throw 'The update pull-request URL does not contain a valid pull-request number.' }
            $pullRequestNumber = [int]$Matches.number
            $failureStage = 'Verified pull-request merge'
            $mergeOutput = @(& gh api --method PUT "repos/$repositoryName/pulls/$pullRequestNumber/merge" -f merge_method=squash 2>&1)
            if ($LASTEXITCODE -ne 0) { throw "Unable to merge the verified update pull request: $($mergeOutput -join [Environment]::NewLine)" }
            try { $mergeResponse = (($mergeOutput -join [Environment]::NewLine) | ConvertFrom-Json) }
            catch { throw 'GitHub returned invalid pull-request merge data.' }
            if ($mergeResponse.merged -ne $true) { throw "GitHub did not merge the verified update pull request: $([string]$mergeResponse.message)" }
            $failureStage = 'Temporary branch cleanup after verified merge'
            $deleteOutput = @(& gh api --method DELETE "repos/$repositoryName/git/refs/heads/$branchName" 2>&1)
            if ($LASTEXITCODE -ne 0) {
                $entry.detail += " $checkCount reported quality check(s) passed and the pull request merged, but the temporary branch could not be removed: $($deleteOutput -join [Environment]::NewLine)"
                $entry.autoMerge = $true
                $entry.status = 'MergedCleanupRequired'
                continue
            }
            $entry.autoMerge = $true
            $entry.status = 'MergedAfterChecks'
            $entry.detail += " $checkCount reported quality check(s) passed before merge."
        }
        catch {
            $failureCause = $_.Exception.Message
            if ($_.Exception.Data.Contains('RunnerNames')) { $entry.runners = @($_.Exception.Data['RunnerNames']) }
            $cleanupOutput = @(& gh pr close ([string]$entry.pullRequest) --repo ([string]$entry.repository) --delete-branch 2>&1)
            $cleanupDetail = if ($LASTEXITCODE -eq 0) { 'The failed temporary RQG pull request and branch were removed.' } else { "Temporary RQG pull-request cleanup failed: $($cleanupOutput -join [Environment]::NewLine)" }
            $entry.autoMerge = $false
            $entry.status = 'Failed'
            if ($failureCause -match '^No quality checks were reported|^Timed out waiting') { $failureStage = 'Pull-request quality-check discovery' }
            elseif ($failureCause -match '^Pull-request quality checks failed') { $failureStage = 'Pull-request quality checks' }
            $entry.detail = New-RqgFailureComment -Stage $failureStage -Cause $failureCause -Version $TargetVersion -PullRequestUrl ([string]$entry.pullRequest) -UpdateBranch $branchName -Cleanup $cleanupDetail
            Write-Warning "Repository Quality Gates completion failed for '$($entry.repository)': $($entry.detail)"
        }
    }
}

$summary = [ordered]@{
    targetVersion = $TargetVersion
    apply = [bool]$Apply
    repositories = @($results)
    failed = @($results | Where-Object status -eq 'Failed').Count
}
$summaryJson = $summary | ConvertTo-Json -Depth 6
if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
    $resolvedResultPath = [IO.Path]::GetFullPath($ResultPath)
    $resultParent = Split-Path -Parent $resolvedResultPath
    if (-not (Test-Path -LiteralPath $resultParent -PathType Container)) { throw 'The result-file parent directory does not exist.' }
    [IO.File]::WriteAllText($resolvedResultPath, $summaryJson, [Text.UTF8Encoding]::new($false))
}
if ($OutputFormat -eq 'Json') { $summaryJson }
else { $results | Format-Table repository, status, autoMerge, pullRequest, detail -AutoSize }
if ($summary.failed -gt 0) { throw "$($summary.failed) managed repository update(s) failed." }
