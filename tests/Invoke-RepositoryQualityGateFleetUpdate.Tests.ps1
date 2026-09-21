# SPDX-License-Identifier: MIT
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$fleetTool = Join-Path $root 'scripts\Invoke-RepositoryQualityGateFleetUpdate.ps1'
$workflowPath = Join-Path $root '.github\workflows\update-managed-repositories.yml'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('rqg-fleet-tests-' + [guid]::NewGuid().ToString('N'))
$passed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:passed++
}

function Invoke-Fleet([string[]]$Repositories, [switch]$AutoEnroll) {
    $arguments = @{
        Owner = 'owner'
        Repository = $Repositories
        TemplateRoot = $root
        TargetVersion = '1.4.0'
        OutputFormat = 'Json'
    }
    if ($AutoEnroll) { $arguments.AutoEnroll = $true }
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = @()
    try {
        $output += @(& $fleetTool @arguments 2>&1)
        $exitCode = 0
    }
    catch { $output = @($output) + @($_); $exitCode = 1 }
    finally { $ErrorActionPreference = $previousPreference }
    [pscustomobject]@{ ExitCode = $exitCode; Output = $output -join [Environment]::NewLine }
}

try {
    function global:gh {
        $joined = $args -join ' '
        if ($args[0] -eq 'api') {
            $endpoint = [string]$args[1]
            if ($endpoint -match '^repos/owner/(?<name>[^/?]+)$') {
                $repositoryName = $Matches.name
                if ($joined -match 'defaultBranch') {
                    if ($repositoryName -eq 'empty') { '{"defaultBranch":"main","size":0}' }
                    else { '{"defaultBranch":"main","size":1}' }
                    $global:LASTEXITCODE = 0
                    return
                }
            }
            if ($endpoint -match '/contents/\.repository-quality-gates\.json') {
                'gh: Not Found (HTTP 404)'
                $global:LASTEXITCODE = 1
                return
            }
            if ($endpoint -match '^repos/owner/(?<name>[^/?]+)/contents/\.repository-quality-gates\.local\.json') {
                if ($Matches.name -eq 'optout') {
                    [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"automaticEnrollment":false}'))
                    $global:LASTEXITCODE = 0
                    return
                }
                'gh: Not Found (HTTP 404)'
                $global:LASTEXITCODE = 1
                return
            }
        }
        if ($args[0] -eq 'pr' -and $args[1] -eq 'list') {
            if ($joined -match 'owner/busy') {
                '[{"number":7,"title":"Existing work","url":"https://example.invalid/pull/7","headRefName":"feature","createdAt":"2026-09-20T00:00:00Z"}]'
            } else { '[]' }
            $global:LASTEXITCODE = 0
            return
        }
        throw "Unexpected mock gh invocation: $joined"
    }

    $oldToken = $env:GH_TOKEN
    $env:GH_TOKEN = 'synthetic-test-token'
    try {
        $preview = Invoke-Fleet @('owner/enrol', 'owner/optout', 'owner/busy', 'owner/empty') -AutoEnroll
        Assert-True ($preview.ExitCode -eq 0) "Fleet enrolment preview should succeed. $($preview.Output)"
        $previewJson = $preview.Output | ConvertFrom-Json
        $enrol = @($previewJson.repositories | Where-Object repository -eq 'owner/enrol')[0]
        $optout = @($previewJson.repositories | Where-Object repository -eq 'owner/optout')[0]
        $busy = @($previewJson.repositories | Where-Object repository -eq 'owner/busy')[0]
        $empty = @($previewJson.repositories | Where-Object repository -eq 'owner/empty')[0]
        Assert-True ($enrol.status -eq 'EnrollmentAvailable') 'An unmanaged repository without an opt-out rule should become an enrolment candidate.'
        Assert-True ([bool]$enrol.enrolment) 'The enrolment candidate should be explicitly identified in structured output.'
        Assert-True ($optout.status -eq 'EnrollmentOptOut') 'An unmanaged repository with automaticEnrollment set to false should remain unenrolled.'
        Assert-True (-not [bool]$optout.enrolment) 'An opted-out repository should not be marked for enrolment.'
        Assert-True ($busy.status -eq 'DeferredOpenPullRequests') 'An automatically eligible repository with an open pull request should be deferred.'
        Assert-True (@($busy.blockingPullRequests).Count -eq 1) 'The deferred enrolment should report its blocking pull request.'
        Assert-True ($empty.status -eq 'EmptyRepository') 'An empty repository should be deferred without failing the fleet.'

        $disabled = Invoke-Fleet @('owner/enrol')
        Assert-True ($disabled.ExitCode -eq 0) 'A fleet preview with automatic enrolment disabled should succeed.'
        $disabledJson = $disabled.Output | ConvertFrom-Json
        Assert-True ($disabledJson.repositories[0].status -eq 'Skipped') 'An unmanaged repository should remain skipped when automatic enrolment is disabled.'

        $workflowText = Get-Content -LiteralPath $workflowPath -Raw
        Assert-True ($workflowText.Contains('-AutoEnroll -Apply -AutoMerge')) 'The fleet workflow should explicitly enable automatic enrolment.'
        Assert-True ($workflowText.Contains('Invoke-RepositoryQualityGateAppFleetUpdate.ps1')) 'The fleet workflow should process every installation of the GitHub App.'
        $fleetText = Get-Content -LiteralPath $fleetTool -Raw
        Assert-True ($fleetText.Contains('repository-quality-gates-fleet-update')) 'RQG pull requests should contain a dedicated provenance marker.'
        Assert-True ($fleetText.Contains('baseRefName,isCrossRepository,body')) 'Expired pull-request cleanup should obtain base, repository-origin, and provenance evidence.'
        Assert-True ($fleetText.Contains("status = 'EnrollmentOptOut'")) 'The fleet should honour the downstream automatic-enrolment opt-out.'
        Assert-True ($fleetText.Contains('opted out while automatic enrolment was being prepared')) 'The fleet should recheck the opt-out immediately before publishing the first enrolment branch.'
        Assert-True ($fleetText.Contains('$existingPrOutput = @(& gh pr list')) 'Existing pull-request discovery should capture zero or more output lines as a collection.'
        Assert-True ($fleetText.Contains('$existingPr = ($existingPrOutput -join [Environment]::NewLine).Trim()')) 'A missing existing pull request must normalize to an empty string without a null-method failure.'
        Assert-True ($fleetText.Contains("status = 'ChecksPending'")) 'Automatic updates should queue pull requests for explicit quality-check verification.'
        Assert-True ($fleetText.Contains('Wait-PullRequestQualityChecks')) 'Automatic updates should wait for every reported pull-request quality check.'
        Assert-True ($fleetText.Contains('[DateTimeOffset]::UtcNow.AddMinutes(4)')) 'Automatic updates should allow four minutes for quality checks to appear.'
        Assert-True ($fleetText.Contains('commits/$headSha/check-runs?per_page=100')) 'Automatic updates should read check results through the least-privilege Checks API.'
        Assert-True (-not $fleetText.Contains('statusCheckRollup')) 'Automatic updates should not request broader workflow-run metadata through GraphQL.'
        Assert-True ($fleetText.Contains("status = 'MergedAfterChecks'")) 'Automatic updates should report only a verified post-check merge as merged.'
        Assert-True ($fleetText.Contains('gh api --method PUT "repos/$repositoryName/pulls/$pullRequestNumber/merge"')) 'Verified pull requests should merge through the REST API supported by GitHub App installation tokens.'
        Assert-True (-not $fleetText.Contains('gh pr merge')) 'The fleet must not depend on the GitHub CLI GraphQL merge path or repository-level auto-merge settings.'
        Assert-True ($fleetText.Contains('gh api --method DELETE "repos/$repositoryName/git/refs/heads/$branchName"')) 'A successful REST merge should remove its temporary update branch.'
        Assert-True ($fleetText.IndexOf('if ($pending.Count)') -lt $fleetText.IndexOf('if ($failed.Count)')) 'The fleet should wait for running checks before removing a branch after another check fails.'
        Assert-True ($fleetText.Contains('Repository Quality Gates update failed for')) 'Preparation failures should be written without table truncation.'
        Assert-True ($fleetText.Contains('Repository Quality Gates completion failed for')) 'Post-check completion failures should be written without table truncation.'
        Assert-True ($fleetText.Contains('Get-PullRequestReferences')) 'The fleet should read repository-owned OpenProject references for automated pull requests.'
        Assert-True ($fleetText.Contains("'^OP#[A-Z][A-Z0-9_]{1,31}-[1-9][0-9]*$'")) 'Repository-owned pull-request references should use a strict OpenProject token format.'
        Assert-True ($fleetText.Contains('OpenProject: $($pullRequestReferences -join')) 'Automated pull-request bodies should include the repository-owned OpenProject references.'
        Assert-True ($fleetText.Contains('$pullRequestTitle = $projectPrefix')) 'Automated pull-request titles should begin with the project identifier derived from the reference.'
        $powerShellWorkflow = Get-Content -LiteralPath (Join-Path $root 'modules\powershell\payload\.github\workflows\quality-powershell.yml') -Raw
        Assert-True ($powerShellWorkflow.Contains("if: `${{ hashFiles('tests/Invoke-RepositoryQualityGates.Tests.ps1') != '' }}")) 'The central synthetic deployment suite should run only when a downstream repository contains it.'
        Assert-True ($powerShellWorkflow.Contains("if: `${{ hashFiles('tests/Update-RepositoryQualityGates.Tests.ps1') != '' }}")) 'The central automatic-update suite should run only when a downstream repository contains it.'
        $emptyPullRequestOutput = @()
        $normalizedEmptyPullRequest = ($emptyPullRequestOutput -join [Environment]::NewLine).Trim()
        Assert-True ($normalizedEmptyPullRequest -eq '') 'Zero GitHub CLI output lines should normalize to an empty pull-request URL.'
    }
    finally {
        Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
        if ($null -eq $oldToken) { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue } else { $env:GH_TOKEN = $oldToken }
    }

    Write-Host "$passed assertions passed."
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

exit 0
