[CmdletBinding()]
param(
    [string]$Owner,
    [string[]]$Repository = @(),
    [string]$TemplateRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$TargetVersion,
    [switch]$Apply,
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
$results = [Collections.Generic.List[object]]::new()
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('rqg-fleet-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
    foreach ($fullName in @($Repository | Sort-Object -Unique)) {
        $entry = [ordered]@{ repository = $fullName; status = 'Skipped'; pullRequest = $null; detail = $null }
        try {
            if ($sourceName -and $fullName -ieq $sourceName) { $entry.detail = 'Central template repository.'; $results.Add([pscustomobject]$entry); continue }
            if ($fullName -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw "Invalid repository name: $fullName" }
            if ($Owner -and ($fullName -split '/')[0] -ine $Owner) { $entry.detail = 'Repository is outside the selected owner.'; $results.Add([pscustomobject]$entry); continue }

            $defaultBranch = (& gh api "repos/$fullName" --jq .default_branch 2>$null).Trim()
            if ($LASTEXITCODE -ne 0 -or -not $defaultBranch) { throw 'Unable to read repository metadata.' }
            $encodedState = @(& gh api "repos/$fullName/contents/.repository-quality-gates.json?ref=$defaultBranch" --jq .content 2>$null)
            if ($LASTEXITCODE -ne 0 -or -not @($encodedState).Count) { $entry.detail = 'Repository is not managed by Repository Quality Gates.'; $results.Add([pscustomobject]$entry); continue }
            $stateText = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((($encodedState -join '') -replace '\s', '')))
            $remoteState = $stateText | ConvertFrom-Json
            if ([string]$remoteState.templateVersion -eq $TargetVersion) { $entry.status = 'Current'; $results.Add([pscustomobject]$entry); continue }

            if (-not $Apply) { $entry.status = 'Available'; $entry.detail = "Current version: $($remoteState.templateVersion)"; $results.Add([pscustomobject]$entry); continue }

            $clonePath = Join-Path $tempRoot (($fullName -replace '/', '-') + '-' + [guid]::NewGuid().ToString('N'))
            $null = @(& gh repo clone $fullName $clonePath -- --branch $defaultBranch --single-branch 2>&1)
            if ($LASTEXITCODE -ne 0) { throw 'Unable to clone the repository.' }
            & git -C $clonePath checkout -B $branchName | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Unable to create the update branch.' }

            $updateText = @(& $updateScript -RepositoryPath $clonePath -TemplateRoot $templateRootFull -TargetVersion $TargetVersion -Apply -OutputFormat Json) -join [Environment]::NewLine
            $update = $updateText | ConvertFrom-Json
            if ($update.status -ne 'Updated') { $entry.status = [string]$update.status; $results.Add([pscustomobject]$entry); continue }

            & git -C $clonePath add -A
            if ($LASTEXITCODE -ne 0) { throw 'Unable to stage the update.' }
            $stagedPaths = @(& git -C $clonePath diff --cached --name-only --diff-filter=ACDMRTUXB | Where-Object { $_ })
            if (-not $stagedPaths.Count) { $entry.status = 'Current'; $results.Add([pscustomobject]$entry); continue }
            $null = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $clonePath 'scripts\Test-Secrets.ps1') -Mode Staged -Repository $clonePath 2>&1)
            if ($LASTEXITCODE -ne 0) { throw 'The staged publication-safety scan failed.' }
            & git -C $clonePath config user.name 'github-actions[bot]'
            & git -C $clonePath config user.email '41898282+github-actions[bot]@users.noreply.github.com'
            & git -C $clonePath commit -m "chore: update Repository Quality Gates to $TargetVersion" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Unable to commit the update.' }

            & git -C $clonePath fetch origin "+refs/heads/$branchName`:refs/remotes/origin/$branchName" 2>$null
            $remoteUpdate = (& git -C $clonePath rev-parse --verify "refs/remotes/origin/$branchName" 2>$null)
            if ($LASTEXITCODE -eq 0 -and $remoteUpdate) {
                & git -C $clonePath push "--force-with-lease=refs/heads/$branchName`:$($remoteUpdate.Trim())" origin "HEAD:refs/heads/$branchName" | Out-Null
            } else {
                & git -C $clonePath push origin "HEAD:refs/heads/$branchName" | Out-Null
            }
            if ($LASTEXITCODE -ne 0) { throw 'Unable to push the update branch.' }

            $existingPr = (& gh pr list --repo $fullName --state open --head $branchName --base $defaultBranch --json number,url --jq '.[0].url // empty').Trim()
            if ($existingPr) { $entry.pullRequest = $existingPr }
            else {
                $bodyPath = Join-Path $clonePath 'rqg-pr-body.md'
                $body = "Updates the managed Repository Quality Gates files to $TargetVersion.`n`nThe updater preserved repository-owned files, stopped on managed-file conflicts, and passed the public working-tree and staged secret scans before creating this pull request.`n`nReview and merge only after the repository's required checks pass.`n"
                [IO.File]::WriteAllText($bodyPath, $body, [Text.UTF8Encoding]::new($false))
                $entry.pullRequest = (& gh pr create --repo $fullName --base $defaultBranch --head $branchName --title "chore: update Repository Quality Gates to $TargetVersion" --body-file $bodyPath).Trim()
                if ($LASTEXITCODE -ne 0) { throw 'Unable to create the update pull request.' }
            }
            $entry.status = 'PullRequest'
            $entry.detail = "$($stagedPaths.Count) managed path(s) changed."
        }
        catch {
            $entry.status = 'Failed'
            $entry.detail = $_.Exception.Message
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
else { $results | Format-Table repository, status, pullRequest, detail -AutoSize }
if ($summary.failed -gt 0) { throw "$($summary.failed) managed repository update(s) failed." }
