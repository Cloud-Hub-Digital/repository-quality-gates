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
    [ValidateSet('Text', 'Json')][string]$OutputFormat = 'Text'
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

if (-not $TargetVersion) {
    $versionOutput = @(& $deploymentTool -Version)
    $TargetVersion = ([string]$versionOutput[0] -replace '^Repository Quality Gates\s+', '').Trim()
}
if (-not $Owner) { $Owner = (& gh api user --jq .login).Trim() }

if (-not $Repository.Count) {
    $Repository = @(& gh api --paginate /installation/repositories --jq '.repositories[].full_name' | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate repositories installed for the GitHub App.' }
}
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
        $entry = [ordered]@{ repository = $fullName; status = 'Skipped'; enrolment = $false; pullRequest = $null; autoMerge = $false; blockingPullRequests = @(); cleanedPullRequests = @(); detail = $null }
        $clonePath = $null
        $pushedUpdateBranch = $false
        try {
            if ($sourceName -and $fullName -ieq $sourceName) { $entry.detail = 'Central template repository.'; $results.Add([pscustomobject]$entry); continue }
            if ($fullName -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw "Invalid repository name: $fullName" }
            if ($Owner -and ($fullName -split '/')[0] -ine $Owner) { $entry.detail = 'Repository is outside the selected owner.'; $results.Add([pscustomobject]$entry); continue }

            $defaultBranch = (& gh api "repos/$fullName" --jq .default_branch 2>$null).Trim()
            if ($LASTEXITCODE -ne 0 -or -not $defaultBranch) { throw 'Unable to read repository metadata.' }
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
            $updateText = @(& $updateScript @updateArguments) -join [Environment]::NewLine
            $update = $updateText | ConvertFrom-Json
            if ($update.status -notin @('Updated', 'Enrolled')) { $entry.status = [string]$update.status; $results.Add([pscustomobject]$entry); continue }

            & git -C $clonePath add -A
            if ($LASTEXITCODE -ne 0) { throw 'Unable to stage the update.' }
            $stagedPaths = @(& git -C $clonePath diff --cached --name-only --diff-filter=ACDMRTUXB | Where-Object { $_ })
            if (-not $stagedPaths.Count) { $entry.status = 'Current'; $results.Add([pscustomobject]$entry); continue }
            $null = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $clonePath 'scripts\Test-Secrets.ps1') -Mode Staged -Repository $clonePath 2>&1)
            if ($LASTEXITCODE -ne 0) { throw 'The staged publication-safety scan failed.' }
            & git -C $clonePath config user.name 'github-actions[bot]'
            & git -C $clonePath config user.email '41898282+github-actions[bot]@users.noreply.github.com'
            $commitMessage = if ($entry.enrolment) { "chore: enrol in Repository Quality Gates $TargetVersion" } else { "chore: update Repository Quality Gates to $TargetVersion" }
            & git -C $clonePath commit -m $commitMessage | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Unable to commit the update.' }

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

            & git -C $clonePath fetch origin "+refs/heads/$branchName`:refs/remotes/origin/$branchName" 2>$null
            $remoteUpdate = (& git -C $clonePath rev-parse --verify "refs/remotes/origin/$branchName" 2>$null)
            if ($LASTEXITCODE -eq 0 -and $remoteUpdate) {
                & git -C $clonePath push "--force-with-lease=refs/heads/$branchName`:$($remoteUpdate.Trim())" origin "HEAD:refs/heads/$branchName" | Out-Null
            } else {
                & git -C $clonePath push origin "HEAD:refs/heads/$branchName" | Out-Null
            }
            if ($LASTEXITCODE -ne 0) { throw 'Unable to push the update branch.' }
            $pushedUpdateBranch = $true

            $existingPr = (& gh pr list --repo $fullName --state open --head $branchName --base $defaultBranch --json number,url --jq '.[0].url // empty').Trim()
            if ($existingPr) { $entry.pullRequest = $existingPr }
            else {
                $bodyPath = Join-Path $clonePath 'rqg-pr-body.md'
                $body = if ($entry.enrolment) {
                    "$rqgPullRequestMarker`n`nEnrols this repository in Repository Quality Gates $TargetVersion under the central automatic-enrolment policy.`n`nThe enrolment detected the repository contents, selected only applicable modules, preserved repository-owned files and rules, and passed the public working-tree and staged secret scans before creating this pull request.`n`nGitHub will merge only after the repository's required checks pass.`n"
                } else {
                    "$rqgPullRequestMarker`n`nUpdates the managed Repository Quality Gates files to $TargetVersion.`n`nThe updater preserved repository-owned files, stopped on managed-file conflicts, and passed the public working-tree and staged secret scans before creating this pull request.`n`nGitHub will merge only after the repository's required checks pass.`n"
                }
                [IO.File]::WriteAllText($bodyPath, $body, [Text.UTF8Encoding]::new($false))
                $pullRequestTitle = if ($entry.enrolment) { "chore: enrol in Repository Quality Gates $TargetVersion" } else { "chore: update Repository Quality Gates to $TargetVersion" }
                $entry.pullRequest = (& gh pr create --repo $fullName --base $defaultBranch --head $branchName --title $pullRequestTitle --body-file $bodyPath).Trim()
                if ($LASTEXITCODE -ne 0) { throw 'Unable to create the update pull request.' }
            }
            if ($AutoMerge) {
                $mergeOutput = @(& gh pr merge $entry.pullRequest --repo $fullName --auto --squash --delete-branch 2>&1)
                if ($LASTEXITCODE -ne 0) { throw "Unable to enable automatic merge for the update pull request: $($mergeOutput -join [Environment]::NewLine)" }
                $entry.autoMerge = $true
                $entry.status = 'AutoMergeEnabled'
            } else {
                $entry.status = 'PullRequest'
            }
            $entry.detail = "$($stagedPaths.Count) managed path(s) changed."
        }
        catch {
            $failureMessage = $_.Exception.Message
            if ($Apply -and $entry.pullRequest) {
                $cleanupOutput = @(& gh pr close ([string]$entry.pullRequest) --repo $fullName --delete-branch 2>&1)
                if ($LASTEXITCODE -eq 0) {
                    $pushedUpdateBranch = $false
                    $failureMessage += ' The failed temporary RQG pull request and branch were removed.'
                } else {
                    $failureMessage += " Temporary RQG cleanup also failed: $($cleanupOutput -join [Environment]::NewLine)"
                }
            } elseif ($Apply -and $pushedUpdateBranch -and $clonePath) {
                $cleanupOutput = @(& git -C $clonePath push origin --delete $branchName 2>&1)
                if ($LASTEXITCODE -eq 0) {
                    $pushedUpdateBranch = $false
                    $failureMessage += ' The failed temporary RQG branch was removed.'
                } else {
                    $failureMessage += " Temporary RQG branch cleanup also failed: $($cleanupOutput -join [Environment]::NewLine)"
                }
            }
            $entry.status = 'Failed'
            $entry.detail = $failureMessage
        }
        $results.Add([pscustomobject]$entry)
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$summary = [ordered]@{
    targetVersion = $TargetVersion
    apply = [bool]$Apply
    repositories = @($results)
    failed = @($results | Where-Object status -eq 'Failed').Count
}
if ($OutputFormat -eq 'Json') { $summary | ConvertTo-Json -Depth 6 }
else { $results | Format-Table repository, status, autoMerge, pullRequest, detail -AutoSize }
if ($summary.failed -gt 0) { throw "$($summary.failed) managed repository update(s) failed." }
