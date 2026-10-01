# SPDX-License-Identifier: MIT
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$fleetTool = Join-Path $root 'scripts\Invoke-RepositoryQualityGateFleetUpdate.ps1'
$workflowPath = Join-Path $root '.github\workflows\update-managed-repositories.yml'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('rqg-fleet-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$passed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:passed++
}

function Invoke-Fleet([string[]]$Repositories, [switch]$AutoEnroll) {
    $resultPath = Join-Path $testRoot ('result-' + [guid]::NewGuid().ToString('N') + '.json')
    $arguments = @{
        Owner = 'owner'
        Repository = $Repositories
        TemplateRoot = $root
        TargetVersion = '1.4.0'
        OutputFormat = 'Json'
        ResultPath = $resultPath
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
    [pscustomobject]@{ ExitCode = $exitCode; Output = $output -join [Environment]::NewLine; ResultPath = $resultPath }
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
        $persistedPreview = Get-Content -LiteralPath $preview.ResultPath -Raw | ConvertFrom-Json
        Assert-True ($persistedPreview.repositories.Count -eq $previewJson.repositories.Count) 'The result file should preserve the same repository rows as JSON output.'
        Assert-True ($persistedPreview.failed -eq $previewJson.failed) 'The result file should preserve the same failure count as JSON output.'
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
        $tokens = $null
        $parseErrors = $null
        $fleetAst = [Management.Automation.Language.Parser]::ParseFile($fleetTool, [ref]$tokens, [ref]$parseErrors)
        Assert-True (-not $parseErrors.Count) 'The fleet updater should parse before its status-classification functions are tested.'
        foreach ($functionName in @('Get-RequiredCheckEnforcementPolicy', 'Test-RqgPrivatePlanLimitation', 'Assert-RequiredQualityChecksEnforced', 'Get-RqgFailureStatus', 'Test-RqgFailureStatus')) {
            $functionAst = @($fleetAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true))[0]
            Assert-True ($null -ne $functionAst) "The fleet updater should define $functionName."
            Invoke-Expression $functionAst.Extent.Text
        }
        Assert-True ((Get-RqgFailureStatus -Stage 'Repository clone' -Cause 'Unable to clone the repository.') -eq 'CloneFailed') 'Repository clone failures should classify as CloneFailed.'
        Assert-True ((Get-RqgFailureStatus -Stage 'Managed-file update' -Cause 'Deployment stopped because 2 path conflict(s) require review.') -eq 'ManagedFileConflict') 'Managed path conflicts should classify as ManagedFileConflict.'
        Assert-True ((Get-RqgFailureStatus -Stage 'Pull-request quality checks' -Cause 'Pull-request quality checks failed: Licence Decision (failure)') -eq 'RequiresLicenceDecision') 'A sole licence failure should classify as RequiresLicenceDecision.'
        Assert-True ((Get-RqgFailureStatus -Stage 'Pull-request quality checks' -Cause 'Pull-request quality checks failed: Licence Decision (failure), Secret Scan (failure)') -eq 'FailedChecks') 'Multiple failed checks should classify as FailedChecks without hiding non-licence failures.'
        Assert-True ((Get-RqgFailureStatus -Stage 'Required-check enforcement before publication' -Cause 'Default-branch rules do not require expected quality checks: Secret Scan') -eq 'RequiredChecksNotEnforced') 'Missing required-check enforcement should have a dedicated status.'
        Assert-True ((Get-RqgFailureStatus -Stage 'Pull-request quality checks' -Cause 'Pull-request quality checks failed: Secret Scan (failure)' -PullRequestMerged $true) -eq 'MergedWithFailedChecks') 'A pull request merged outside the verified path while checks failed should classify as MergedWithFailedChecks.'
        Assert-True (Test-RqgFailureStatus 'RequiresLicenceDecision') 'RequiresLicenceDecision should count as a fleet failure.'
        Assert-True (Test-RqgFailureStatus 'MergedCleanupRequired') 'MergedCleanupRequired should count as a fleet failure until cleanup succeeds.'
        Assert-True (-not (Test-RqgFailureStatus 'UpdatedSuccessfully')) 'UpdatedSuccessfully should not count as a fleet failure.'
        Assert-True (-not (Test-RqgFailureStatus 'DeferredOpenPullRequests')) 'A deliberate open-pull-request deferral should not count as an execution failure.'
        $policyPath = Join-Path $root 'policy\required-check-enforcement.json'
        $requiredCheckPolicy = Get-RequiredCheckEnforcementPolicy $policyPath
        Assert-True ($requiredCheckPolicy.public.mode -eq 'github-rules-required') 'The checked-in policy should require native GitHub rules for public repositories.'
        Assert-True ($requiredCheckPolicy.private.mode -eq 'rqg-verified-merge-exception') 'The checked-in policy should name the reviewed private-repository exception.'
        Assert-True (@($requiredCheckPolicy.private.requiredControls).Count -eq 8) 'The private exception should contain the exact eight-control contract.'
        $invalidPolicyPath = Join-Path $testRoot 'invalid-required-check-policy.json'
        '{"schemaVersion":2}' | Set-Content -LiteralPath $invalidPolicyPath -Encoding utf8NoBOM
        $invalidPolicyFailure = $null
        try { $null = Get-RequiredCheckEnforcementPolicy $invalidPolicyPath }
        catch { $invalidPolicyFailure = $_ }
        Assert-True ($null -ne $invalidPolicyFailure) 'An unsupported required-check policy schema should fail closed.'
        $incompletePolicyPath = Join-Path $testRoot 'incomplete-required-check-policy.json'
        $incompletePolicy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
        $incompletePolicy.private.requiredControls = @($incompletePolicy.private.requiredControls | Select-Object -Skip 1)
        $incompletePolicy | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $incompletePolicyPath -Encoding utf8NoBOM
        $incompletePolicyFailure = $null
        try { $null = Get-RequiredCheckEnforcementPolicy $incompletePolicyPath }
        catch { $incompletePolicyFailure = $_ }
        Assert-True ($null -ne $incompletePolicyFailure) 'A private exception missing an approved control should fail closed.'
        Assert-True (Test-RqgPrivatePlanLimitation 'Upgrade to GitHub Pro to use protected branches in private repositories.') 'The known private-plan limitation should be recognized.'
        Assert-True (-not (Test-RqgPrivatePlanLimitation 'gh: Forbidden (HTTP 403)')) 'A generic permission error must not be treated as a plan limitation.'
        $ruleResponses = [Collections.Generic.Queue[object]]::new()
        $ruleResponses.Enqueue((@(
            [pscustomobject]@{ type = 'required_status_checks'; parameters = [pscustomobject]@{ required_status_checks = @([pscustomobject]@{ context = 'Secret Scan' }, [pscustomobject]@{ context = 'Licence Decision' }) } }
        ) | ConvertTo-Json -Depth 8 -Compress))
        $ruleResponses.Enqueue((@(
            [pscustomobject]@{ type = 'required_status_checks'; parameters = [pscustomobject]@{ required_status_checks = @([pscustomobject]@{ context = 'Secret Scan' }) } }
        ) | ConvertTo-Json -Depth 8 -Compress))
        function global:gh {
            if ($args[0] -eq 'api') {
                $joined = $args -join ' '
                if ($joined -match 'repos/owner/protected/rules/branches/main') {
                    $ruleResponses.Dequeue()
                    $global:LASTEXITCODE = 0
                    return
                }
                if ($joined -match 'repos/owner/private-plan/rules/branches/main') {
                    'Upgrade to GitHub Pro to use protected branches in private repositories.'
                    $global:LASTEXITCODE = 1
                    return
                }
                if ($joined -match 'repos/owner/public-plan/rules/branches/main') {
                    'Upgrade to GitHub Pro to use protected branches in private repositories.'
                    $global:LASTEXITCODE = 1
                    return
                }
                if ($joined -match 'repos/owner/private-unknown/rules/branches/main') {
                    'gh: Forbidden (HTTP 403)'
                    $global:LASTEXITCODE = 1
                    return
                }
            }
            throw "Unexpected required-check mock invocation: $($args -join ' ')"
        }
        $enforced = Assert-RequiredQualityChecksEnforced -RepositoryName 'owner/protected' -DefaultBranch 'main' -ExpectedCheckNames @('Licence Decision', 'Secret Scan') -RepositoryVisibility Public -Policy $requiredCheckPolicy
        Assert-True (@($enforced.requiredChecks).Count -eq 2) 'Effective default-branch rules should preserve every required check context.'
        Assert-True ($enforced.mode -eq 'github-rules-required') 'A repository with complete native rules should use GitHub rules enforcement.'
        Assert-True ($null -eq $enforced.exceptionId) 'A repository with complete native rules should not record an exception.'
        $missingRuleFailure = $null
        try { $null = Assert-RequiredQualityChecksEnforced -RepositoryName 'owner/protected' -DefaultBranch 'main' -ExpectedCheckNames @('Licence Decision', 'Secret Scan') -RepositoryVisibility Public -Policy $requiredCheckPolicy }
        catch { $missingRuleFailure = $_ }
        Assert-True ($null -ne $missingRuleFailure) 'Ruleset verification should fail when an expected check is not required.'
        Assert-True ($missingRuleFailure.Exception.Message -eq 'Default-branch rules do not require expected quality checks: Licence Decision') 'Ruleset verification should identify each missing required check.'
        $privateException = Assert-RequiredQualityChecksEnforced -RepositoryName 'owner/private-plan' -DefaultBranch 'main' -ExpectedCheckNames @('Licence Decision', 'Secret Scan') -RepositoryVisibility Private -Policy $requiredCheckPolicy
        Assert-True ($privateException.mode -eq 'rqg-verified-merge-exception') 'A verified private-plan limitation should activate the reviewed merge exception.'
        Assert-True ($privateException.exceptionId -eq 'RQG-PRIVATE-PLAN-001') 'The private-plan exception should retain its approved identifier.'
        Assert-True ([bool]$privateException.platformLimitationVerified) 'The private-plan exception should record verified platform limitation evidence.'
        $publicPlanFailure = $null
        try { $null = Assert-RequiredQualityChecksEnforced -RepositoryName 'owner/public-plan' -DefaultBranch 'main' -ExpectedCheckNames @('Secret Scan') -RepositoryVisibility Public -Policy $requiredCheckPolicy }
        catch { $publicPlanFailure = $_ }
        Assert-True ($null -ne $publicPlanFailure) 'A public repository must not use the private-plan exception.'
        $privateUnknownFailure = $null
        try { $null = Assert-RequiredQualityChecksEnforced -RepositoryName 'owner/private-unknown' -DefaultBranch 'main' -ExpectedCheckNames @('Secret Scan') -RepositoryVisibility Private -Policy $requiredCheckPolicy }
        catch { $privateUnknownFailure = $_ }
        Assert-True ($null -ne $privateUnknownFailure) 'A generic private-repository permission error must fail closed.'
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
        Assert-True ($fleetText.Contains(".check_runs[] | {id,name,status,conclusion,details_url,started_at}")) 'Automatic updates should retain stable check-run identities and URLs needed to identify each workflow run.'
        Assert-True ($fleetText.Contains("[ValidateRange(5, 300)][int]`$CheckSettleSeconds = 30")) 'Automatic updates should require a bounded check-set settling period.'
        Assert-True ($fleetText.Contains('function Get-ExpectedQualityCheckNames')) 'Automatic updates should derive expected quality checks from the deployed module set.'
        Assert-True ($fleetText.Contains("'secret-scanning' = 'Secret Scan'")) 'The expected-check map should include the universal secret scan.'
        Assert-True ($fleetText.Contains('Expected quality checks were not reported')) 'Automatic updates should fail closed when a deployed module check never appears.'
        Assert-True ($fleetText.Contains('$currentHeadSha -cne $headSha')) 'Automatic updates should reset discovery when reconciliation changes the pull-request head.'
        Assert-True ($fleetText.Contains('$signature -cne $lastCheckSignature')) 'Automatic updates should reset the settling period whenever the check set changes.'
        Assert-True ($fleetText.Contains('$checks | Group-Object')) 'Duplicate push and pull-request runs should be grouped into logical check results.'
        Assert-True ($fleetText.Contains('$failedConclusions -join')) 'Duplicate failures should be reported once per logical check with distinct conclusions.'
        Assert-True ($fleetText.Contains('actions/runs/$runId/jobs?per_page=100')) 'Automatic updates should inspect workflow jobs to identify the downstream self-hosted runners actually used.'
        Assert-True ($fleetText.Contains('Write-Host "::add-mask::$runnerName"')) 'Every discovered runner name should be registered for masking before public workflow output is retained.'
        Assert-True ($fleetText.Contains("`$exception.Data['RunnerNames'] = `$runnerNames")) 'Failed checks should preserve their runner assignments for the private email report.'
        Assert-True (-not $fleetText.Contains('statusCheckRollup')) 'Automatic updates should not request broader workflow-run metadata through GraphQL.'
        Assert-True ($fleetText.Contains("status = 'UpdatedSuccessfully'")) 'Automatic updates should report only a verified post-check merge as updated successfully.'
        Assert-True ($fleetText.Contains('function Get-RqgFailureStatus')) 'Fleet failures should be classified by their actual failed stage.'
        Assert-True ($fleetText.Contains("return 'CloneFailed'")) 'Repository clone failures should have a dedicated status.'
        Assert-True ($fleetText.Contains("return 'ManagedFileConflict'")) 'Managed-file conflicts should have a dedicated status.'
        Assert-True ($fleetText.Contains("return 'RequiresLicenceDecision'")) 'A sole failed Licence Decision check should have an actionable status.'
        Assert-True ($fleetText.Contains("return 'FailedChecks'")) 'General pull-request check failures should have a dedicated status.'
        Assert-True ($fleetText.Contains("return 'MergedWithFailedChecks'")) 'An externally merged pull request with unresolved checks should remain explicit.'
        Assert-True ($fleetText.Contains("return 'RequiredChecksNotEnforced'")) 'Missing branch-rule enforcement should have a dedicated status.'
        Assert-True ($fleetText.Contains('Test-RqgFailureStatus')) 'The aggregate failure count should use the precise status model.'
        Assert-True (-not $fleetText.Contains("`$entry.status = 'Failed'")) 'Repository results should not collapse distinct failures into a broad Failed status.'
        Assert-True ($fleetText.Contains('gh api --method PUT "repos/$repositoryName/pulls/$pullRequestNumber/merge"')) 'Verified pull requests should merge through the REST API supported by GitHub App installation tokens.'
        Assert-True ($fleetText.Contains('[string]$preMergeState.headSha -cne [string]$checkResult.headSha')) 'The merge should be blocked when the pull-request head changes after check verification.'
        Assert-True ($fleetText.Contains('[string]$preMergeState.baseRef -cne [string]$checkResult.baseRef')) 'The merge should be blocked when the pull-request base changes after check verification.'
        Assert-True ($fleetText.Contains('Assert-RequiredQualityChecksEnforced -RepositoryName $fullName')) 'The updater should verify required checks before publishing the first remote branch.'
        Assert-True ($fleetText.Contains('Assert-RequiredQualityChecksEnforced -RepositoryName $repositoryName')) 'The updater should reverify required checks immediately before merge.'
        Assert-True ($fleetText.Contains('Get-RequiredCheckEnforcementPolicy $RequiredCheckPolicyPath')) 'The updater should load the reviewed required-check policy before fleet processing.'
        Assert-True ($fleetText.Contains("[ValidateSet('Public', 'Private')][string]`$RepositoryVisibility")) 'Required-check enforcement should use dynamically discovered repository visibility.'
        Assert-True ($fleetText.Contains('The required-check enforcement control changed after publication.')) 'The updater should stop if the enforcement control changes before merge.'
        Assert-True (-not $fleetText.Contains('owner/private-plan')) 'The production updater must not contain a hard-coded repository exception inventory.'
        Assert-True ($fleetText.Contains('-f "sha=$($checkResult.headSha)"')) 'The merge API request should be pinned atomically to the verified pull-request head.'
        Assert-True ($fleetText.Contains('Wait-DefaultBranchTargetVersion')) 'A successful merge should be verified against the target version on the default branch.'
        Assert-True ($fleetText.Contains("'^Default-branch version verification'")) 'Post-merge version failures should provide a specific investigation route.'
        Assert-True ($fleetText.Contains('no destructive cleanup was attempted')) 'A pull request merged outside the verified path should not be closed or have its branch deleted as failed cleanup.'
        Assert-True (-not $fleetText.Contains('gh pr merge')) 'The fleet must not depend on the GitHub CLI GraphQL merge path or repository-level auto-merge settings.'
        Assert-True ($fleetText.Contains('gh api --method DELETE "repos/$repositoryName/git/refs/heads/$branchName"')) 'A successful REST merge should remove its temporary update branch.'
        Assert-True ($fleetText.IndexOf('if ($pending.Count)') -lt $fleetText.IndexOf('if ($failed.Count)')) 'The fleet should wait for running checks before removing a branch after another check fails.'
        Assert-True ($fleetText.Contains('Repository Quality Gates update failed for')) 'Preparation failures should be written without table truncation.'
        Assert-True ($fleetText.Contains('Repository Quality Gates completion failed for')) 'Post-check completion failures should be written without table truncation.'
        Assert-True ($fleetText.Contains('function New-RqgFailureComment')) 'Failed repository rows should use a structured investigation comment.'
        Assert-True ($fleetText.Contains('Stage: $Stage. Cause: $Cause Context: $context')) 'Failed repository comments should identify the stage, cause, and target context.'
        Assert-True ($fleetText.Contains('Investigation: $(Get-RqgInvestigationAction $Stage)')) 'Failed repository comments should provide a stage-specific investigation action.'
        Assert-True ($fleetText.Contains('Pull request: $PullRequestUrl.')) 'Failed repository comments should include the update pull request when one exists.'
        Assert-True ($fleetText.Contains("Open the update pull request Checks tab, inspect each named failing check and its job log")) 'Quality-check failures should direct the operator to the named check logs.'
        Assert-True ($fleetText.Contains('<!-- repository-quality-gates-fleet-update -->')) 'Automated rollout pull requests must retain the exact authenticated fleet provenance marker.'
        Assert-True ($fleetText.Contains('Get-PullRequestReferences')) 'The fleet should read repository-owned OpenProject work-package references for automated pull requests.'
        Assert-True ($fleetText.Contains('OP#(?<displayId>')) 'The fleet should accept the OP# work-package shorthand.'
        Assert-True ($fleetText.Contains('\[(?<displayId>')) 'The fleet should accept the bracketed work-package shorthand.'
        Assert-True ($fleetText.Contains("'[' + `$pullRequestReferences[0].displayId + '] '")) 'Automated pull-request titles should use the bracketed work-package display ID.'
        Assert-True ($fleetText.Contains('OpenProject: $($pullRequestReferences.reference -join')) 'Automated pull-request bodies should preserve the validated repository-owned shorthand references.'
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
