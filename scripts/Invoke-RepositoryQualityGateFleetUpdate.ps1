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
    [ValidateRange(5, 300)][int]$CheckSettleSeconds = 30,
    [ValidateRange(1, 168)][int]$TemporaryBranchLifetimeHours = 24,
    [ValidateSet('Text', 'Json')][string]$OutputFormat = 'Text',
    [string]$RequiredCheckPolicyPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'policy\required-check-enforcement.json'),
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

function Remove-RqgMergedBranch([string]$RepositoryName, [string]$BranchName) {
    if ($BranchName -notmatch '^rqg/update-v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$') { throw 'Refusing to remove a branch outside the RQG update namespace.' }
    $deleteOutput = @(& gh api --method DELETE "repos/$RepositoryName/git/refs/heads/$BranchName" 2>&1)
    $deleteCode = $LASTEXITCODE
    # GitHub may delete the branch atomically with the merge. Prove the resulting
    # state even when DELETE reports success; an error alone cannot prove absence.
    $encodedBranch = [Uri]::EscapeDataString($BranchName)
    $refOutput = @(& gh api "repos/$RepositoryName/git/matching-refs/heads/$encodedBranch" 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Unable to verify temporary branch absence: $($refOutput -join [Environment]::NewLine)" }
    try { $refs = ConvertFrom-Json -InputObject ($refOutput -join [Environment]::NewLine) -NoEnumerate }
    catch { throw 'GitHub returned invalid temporary branch reference data.' }
    if ($refs -isnot [array]) { throw 'GitHub did not return a temporary branch reference array.' }
    foreach ($reference in $refs) {
        if ($null -eq $reference -or -not $reference.PSObject.Properties['ref'] -or $reference.ref -isnot [string] -or $reference.ref -cnotmatch '^refs/heads/.+') { throw 'GitHub returned a malformed temporary branch reference.' }
        if ([string]$reference.ref -ceq "refs/heads/$BranchName") {
            throw "Temporary RQG branch still exists after deletion (exit $deleteCode): $($deleteOutput -join [Environment]::NewLine)"
        }
    }
}
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

function Get-PullRequestState([string]$RepositoryName, [int]$PullRequestNumber) {
    $output = @(& gh api "repos/$RepositoryName/pulls/$PullRequestNumber" --jq '{state,merged,headSha:.head.sha,baseRef:.base.ref}' 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Unable to inspect the pull request: $($output -join [Environment]::NewLine)" }
    try { $state = (($output -join [Environment]::NewLine) | ConvertFrom-Json) }
    catch { throw 'GitHub returned invalid pull-request state data.' }
    if ([string]$state.headSha -notmatch '^[0-9a-fA-F]{40}$') { throw 'GitHub returned an invalid pull-request head commit.' }
    if ([string]::IsNullOrWhiteSpace([string]$state.baseRef)) { throw 'GitHub returned an invalid pull-request base branch.' }
    return $state
}

function Get-ExpectedQualityCheckNames([string]$RepositoryPath) {
    $statePath = Join-Path $RepositoryPath '.repository-quality-gates.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw 'The repository quality-gates state file is missing after deployment.' }
    try { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
    catch { throw 'The repository quality-gates state file is invalid after deployment.' }
    $checkNamesByModule = @{
        documentation = 'Markdown Hygiene'
        dotnet = '.NET Build And Test'
        go = 'Go Format, Vet, Test, And Build'
        licensing = 'Licence Decision'
        'module-drift' = 'Report Required Quality Gates'
        node = 'JavaScript Syntax, Test, And Build'
        php = 'PHP Syntax And Project Test'
        platformio = 'Firmware Build'
        powershell = 'PowerShell And Regression Tests'
        python = 'Python Compile And Test'
        'secret-scanning' = 'Secret Scan'
        shell = 'Shell Syntax'
    }
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($module in @($state.modules)) {
        $moduleName = [string]$module
        if ($checkNamesByModule.ContainsKey($moduleName)) { $null = $expected.Add([string]$checkNamesByModule[$moduleName]) }
    }
    if (-not $expected.Count) { throw 'The deployed module set did not identify any expected quality checks.' }
    return @($expected | Sort-Object)
}

function Get-RequiredCheckEnforcementPolicy([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'The required-check enforcement policy path is required.' }
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw 'The required-check enforcement policy file is missing.' }
    try { $policy = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json }
    catch { throw 'The required-check enforcement policy is invalid JSON.' }
    if ([int]$policy.schemaVersion -ne 1) { throw 'The required-check enforcement policy schemaVersion must be 1.' }
    if ([string]$policy.public.mode -cne 'github-rules-required') { throw 'The public required-check enforcement mode must be github-rules-required.' }
    if ([string]$policy.private.mode -cne 'rqg-verified-merge-exception') { throw 'The private required-check enforcement mode must be rqg-verified-merge-exception.' }
    if ($policy.private.enabled -ne $true) { throw 'The private required-check enforcement exception must be explicitly enabled.' }
    if ([string]$policy.private.exceptionId -notmatch '^RQG-[A-Z0-9-]+$') { throw 'The private required-check enforcement exceptionId is invalid.' }
    $requiredControls = @(
        'expected-checks-derived-from-deployed-modules',
        'all-expected-checks-observed',
        'all-observed-executions-accepted',
        'stable-check-set',
        'exact-head-and-base-reverified',
        'merge-pinned-to-verified-head',
        'default-branch-version-verified',
        'unverified-state-fails-closed'
    )
    $actualControls = @($policy.private.requiredControls | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Sort-Object -Unique)
    $missingControls = @($requiredControls | Where-Object { $_ -notin $actualControls })
    $unexpectedControls = @($actualControls | Where-Object { $_ -notin $requiredControls })
    if ($missingControls.Count -or $unexpectedControls.Count -or $actualControls.Count -ne $requiredControls.Count) {
        throw 'The private required-check enforcement exception does not contain the exact approved control set.'
    }
    return $policy
}

function Test-RqgPrivatePlanLimitation([string]$Message) {
    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
    return $Message -match '(?i)(upgrade\s+to\s+GitHub\s+(?:Pro|Team|Enterprise)|branch protection rules are not available for private repositories|protected branches are available (?:to|for).*(?:Pro|Team|Enterprise)|endpoint is unavailable for private repositories on (?:the|your) current plan)'
}

function Assert-RequiredQualityChecksEnforced(
    [string]$RepositoryName,
    [string]$DefaultBranch,
    [string[]]$ExpectedCheckNames,
    [ValidateSet('Public', 'Private')][string]$RepositoryVisibility,
    [object]$Policy
) {
    if ([string]::IsNullOrWhiteSpace($DefaultBranch)) { throw 'The default branch is required for ruleset verification.' }
    $expected = @($ExpectedCheckNames | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Sort-Object -Unique)
    if (-not $expected.Count) { throw 'At least one expected quality check is required for ruleset verification.' }
    if ($null -eq $Policy) { throw 'The required-check enforcement policy is required.' }

    $encodedBranch = [Uri]::EscapeDataString($DefaultBranch)
    $output = @(& gh api -H 'Accept: application/vnd.github+json' "repos/$RepositoryName/rules/branches/$encodedBranch`?per_page=100" 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $errorText = ($output -join [Environment]::NewLine).Trim()
        if ($RepositoryVisibility -eq 'Private' -and [bool]$Policy.private.enabled -and (Test-RqgPrivatePlanLimitation $errorText)) {
            return [pscustomobject]@{
                mode = [string]$Policy.private.mode
                exceptionId = [string]$Policy.private.exceptionId
                requiredChecks = @()
                expectedChecks = $expected
                platformLimitationVerified = $true
            }
        }
        throw "Unable to inspect active default-branch rules: $errorText"
    }
    try { $rules = @((($output -join [Environment]::NewLine) | ConvertFrom-Json)) }
    catch { throw 'GitHub returned invalid active default-branch rule data.' }
    if ($rules.Count -ge 100) { throw 'Active default-branch rule verification reached the API page limit and cannot prove complete enforcement.' }

    $requiredContexts = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($rule in @($rules | Where-Object { [string]$_.type -eq 'required_status_checks' })) {
        foreach ($requiredCheck in @($rule.parameters.required_status_checks)) {
            $context = ([string]$requiredCheck.context).Trim()
            if ($context) { $null = $requiredContexts.Add($context) }
        }
    }
    $missing = @($expected | Where-Object { -not $requiredContexts.Contains($_) })
    if ($missing.Count) { throw "Default-branch rules do not require expected quality checks: $($missing -join ', ')" }
    return [pscustomobject]@{
        mode = [string]$Policy.public.mode
        exceptionId = $null
        requiredChecks = @($requiredContexts | Sort-Object)
        expectedChecks = $expected
        platformLimitationVerified = $false
    }
}

function Wait-PullRequestQualityChecks([string]$RepositoryName, [string]$PullRequestUrl, [string[]]$ExpectedCheckNames, [int]$SettleSeconds) {
    if ($PullRequestUrl -notmatch '/pull/(?<number>\d+)(?:[/?#]|$)') { throw 'The pull-request URL does not contain a pull-request number.' }
    $pullRequestNumber = [int]$Matches.number
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(45)
    $discoveryDeadline = [DateTimeOffset]::UtcNow.AddMinutes(4)
    $headSha = $null
    $baseRef = $null
    $lastCheckSignature = $null
    $stableSince = $null
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $pullRequestState = Get-PullRequestState $RepositoryName $pullRequestNumber
        if ([bool]$pullRequestState.merged -or [string]$pullRequestState.state -ne 'open') {
            throw 'The update pull request is no longer open and cannot be verified for merge.'
        }
        $currentHeadSha = [string]$pullRequestState.headSha
        if ($currentHeadSha -cne $headSha) {
            $headSha = $currentHeadSha
            $baseRef = [string]$pullRequestState.baseRef
            $discoveryDeadline = [DateTimeOffset]::UtcNow.AddMinutes(4)
            $lastCheckSignature = $null
            $stableSince = $null
        }
        # Read the Checks API directly. GitHub's GraphQL rollup also expands
        # workflow-run metadata, which requires broader Actions access even
        # though RQG only needs each check's name, status, and conclusion.
        $output = @(& gh api --paginate -H 'Accept: application/vnd.github+json' "repos/$RepositoryName/commits/$headSha/check-runs?per_page=100" --jq '.check_runs[] | {id,name,status,conclusion,details_url,started_at}' 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Unable to inspect pull-request quality checks: $($output -join [Environment]::NewLine)" }
        try { $checks = @($output | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) }
        catch { throw 'GitHub returned invalid pull-request quality-check data.' }
        if (-not $checks.Count) {
            if ([DateTimeOffset]::UtcNow -ge $discoveryDeadline) { throw 'No quality checks were reported for the update pull request.' }
            Start-Sleep -Seconds 5
            continue
        }

        $signature = (@($checks | Sort-Object id | ForEach-Object { "$($_.id):$($_.status):$($_.conclusion)" }) -join '|')
        if ($signature -cne $lastCheckSignature) {
            $lastCheckSignature = $signature
            $stableSince = [DateTimeOffset]::UtcNow
        }

        $checksByName = @($checks | Group-Object { if ($_.PSObject.Properties['name'] -and -not [string]::IsNullOrWhiteSpace([string]$_.name)) { [string]$_.name } else { 'Unnamed Check' } })
        $observedNames = @($checksByName.Name)
        $missingExpected = @($ExpectedCheckNames | Where-Object { $_ -notin $observedNames })
        if ($missingExpected.Count) {
            if ([DateTimeOffset]::UtcNow -ge $discoveryDeadline) { throw "Expected quality checks were not reported: $($missingExpected -join ', ')" }
            Start-Sleep -Seconds 5
            continue
        }

        $pending = [Collections.Generic.List[string]]::new()
        $failed = [Collections.Generic.List[string]]::new()
        foreach ($group in $checksByName) {
            $logicalChecks = @($group.Group)
            if (@($logicalChecks | Where-Object { [string]$_.status -ne 'completed' }).Count) { $pending.Add([string]$group.Name); continue }
            $failedConclusions = @($logicalChecks | Where-Object { [string]$_.conclusion -notin @('success', 'neutral', 'skipped') } | ForEach-Object { [string]$_.conclusion } | Sort-Object -Unique)
            if ($failedConclusions.Count) { $failed.Add("$($group.Name) ($($failedConclusions -join '/'))") }
        }
        # Do not remove the temporary branch while another check is still
        # running. A workflow that is checking out that branch would then fail
        # for the wrong reason and hide the original result.
        if ($pending.Count) { Start-Sleep -Seconds 10; continue }
        if ($null -eq $stableSince -or ([DateTimeOffset]::UtcNow - $stableSince).TotalSeconds -lt $SettleSeconds) { Start-Sleep -Seconds 5; continue }
        $runnerNames = @(Get-WorkflowRunnerNames -RepositoryName $RepositoryName -Checks $checks)
        if ($failed.Count) {
            $exception = [InvalidOperationException]::new("Pull-request quality checks failed: $($failed -join ', ')")
            $exception.Data['RunnerNames'] = $runnerNames
            throw $exception
        }
        return [pscustomobject]@{ checkCount = $checksByName.Count; runnerNames = $runnerNames; headSha = $headSha; baseRef = $baseRef }
    }
    throw 'Timed out waiting for pull-request quality checks to complete.'
}

function Wait-DefaultBranchTargetVersion([string]$RepositoryName, [string]$DefaultBranch, [string]$ExpectedVersion) {
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(2)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $remoteState = Get-RemoteTextFile $RepositoryName $DefaultBranch '.repository-quality-gates.json'
        if ($remoteState.exists) {
            try { $state = $remoteState.content | ConvertFrom-Json }
            catch { throw 'The default-branch repository quality-gates state is invalid after merge.' }
            if ([string]$state.templateVersion -ceq $ExpectedVersion) { return }
        }
        Start-Sleep -Seconds 5
    }
    throw "The default branch did not report Repository Quality Gates version $ExpectedVersion after merge."
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

function Get-OpenProjectWorkPackageDisplayId([string]$Reference) {
    if ($Reference -match '^(?:OP#(?<displayId>[A-Z][A-Z0-9_]{1,31}-[1-9][0-9]*)|\[(?<displayId>[A-Z][A-Z0-9_]{1,31}-[1-9][0-9]*)\])$') {
        return [string]$Matches.displayId
    }
    throw 'An OpenProject work-package reference must use [PROJECT-123] or OP#PROJECT-123.'
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
        throw 'The downstream pullRequest.references rule must be an array of OpenProject work-package references.'
    }
    $references = @($pullRequestRules.references | ForEach-Object {
        if ($_ -isnot [string]) { throw 'Each downstream pullRequest reference must be a string.' }
        $reference = $_.Trim()
        [pscustomobject]@{ reference = $reference; displayId = Get-OpenProjectWorkPackageDisplayId $reference }
    })
    if (@($references.reference | Sort-Object -Unique).Count -ne $references.Count) { throw 'The downstream pullRequest references contain duplicates.' }
    if (@($references.displayId | Sort-Object -Unique).Count -ne $references.Count) { throw 'The downstream pullRequest references contain duplicate OpenProject work-package display IDs.' }
    $projectIdentifiers = @($references.displayId | ForEach-Object { $_ -replace '-[1-9][0-9]*$', '' } | Sort-Object -Unique)
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
        '^Required-check enforcement' { return 'Configure active default-branch rules to require every expected Repository Quality Gates check, verify the effective branch rules, then rerun before publishing an update branch.' }
        '^Verified pull-request merge' { return 'Inspect branch protection, required reviews, mergeability, and the GitHub App Pull requests and Contents permissions; resolve the reported merge blocker and rerun.' }
        '^Default-branch version verification' { return 'Inspect the merged pull request and default-branch managed-state file, confirm the merge contains the target RQG version, and correct the branch state before retrying.' }
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

function Get-RqgFailureStatus {
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$Cause,
        [bool]$PullRequestMerged = $false
    )

    if ($PullRequestMerged) {
        if ($Stage -match '^Temporary branch cleanup') { return 'MergedCleanupRequired' }
        if ($Stage -match '^Pull-request quality-check discovery|^Pull-request quality checks') { return 'MergedWithFailedChecks' }
        if ($Stage -match '^Default-branch version verification') { return 'PostMergeVerificationFailed' }
        return 'MergeOutcomeUnverified'
    }

    switch -Regex ($Stage) {
        '^Repository metadata' { return 'RepositoryInspectionFailed' }
        '^Managed-state inspection' { return 'ManagedStateInvalid' }
        '^Open pull-request inspection' { return 'OpenPullRequestInspectionFailed' }
        '^Repository clone' { return 'CloneFailed' }
        '^Managed-file update' {
            if ($Cause -match 'path conflict|managed file was modified|unmanaged file already uses') { return 'ManagedFileConflict' }
            return 'ManagedFileUpdateFailed'
        }
        '^Publication-safety scan' { return 'PublicationSafetyFailed' }
        '^Update commit' { return 'CommitFailed' }
        '^Update branch push' { return 'BranchPushFailed' }
        '^Update pull-request creation' { return 'PullRequestCreationFailed' }
        '^Pull-request quality-check discovery' { return 'CheckDiscoveryFailed' }
        '^Pull-request quality checks' {
            if ($Cause -match '^Pull-request quality checks failed:\s*Licence Decision\s+\([^)]+\)\s*$') { return 'RequiresLicenceDecision' }
            return 'FailedChecks'
        }
        '^Required-check enforcement' { return 'RequiredChecksNotEnforced' }
        '^Verified pull-request merge' { return 'MergeFailed' }
        '^Default-branch version verification' { return 'PostMergeVerificationFailed' }
        '^Temporary branch cleanup' { return 'MergedCleanupRequired' }
        default { return 'FleetUpdateFailed' }
    }
}

function Test-RqgFailureStatus([string]$Status) {
    return $Status -notin @(
        'Skipped',
        'Current',
        'EmptyRepository',
        'EnrollmentOptOut',
        'DeferredOpenPullRequests',
        'EnrollmentAvailable',
        'Available',
        'Ahead',
        'ChecksPending',
        'PullRequest',
        'UpdatedSuccessfully'
    )
}

$requiredCheckPolicy = Get-RequiredCheckEnforcementPolicy $RequiredCheckPolicyPath

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
        $entry = [ordered]@{ repository = $fullName; visibility = $null; status = 'Skipped'; enrolment = $false; pullRequest = $null; autoMerge = $false; runners = @(); expectedChecks = @(); requiredCheckControl = $null; requiredCheckException = $null; blockingPullRequests = @(); cleanedPullRequests = @(); detail = $null }
        $clonePath = $null
        $pushedUpdateBranch = $false
        $failureStage = 'Repository metadata and eligibility inspection'
        try {
            if ($sourceName -and $fullName -ieq $sourceName) { $entry.detail = 'Central template repository.'; $results.Add([pscustomobject]$entry); continue }
            if ($fullName -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw "Invalid repository name: $fullName" }
            if ($Owner -and ($fullName -split '/')[0] -ine $Owner) { $entry.detail = 'Repository is outside the selected owner.'; $results.Add([pscustomobject]$entry); continue }

            $failureStage = 'Repository metadata inspection'
            $metadataText = @(& gh api "repos/$fullName" --jq '{defaultBranch:.default_branch,size:.size,visibility:.visibility,private:.private}' 2>$null) -join [Environment]::NewLine
            if ($LASTEXITCODE -ne 0 -or -not $metadataText) { throw 'Unable to read repository metadata.' }
            try { $metadata = $metadataText | ConvertFrom-Json }
            catch { throw 'GitHub returned invalid repository metadata.' }
            $defaultBranch = ([string]$metadata.defaultBranch).Trim()
            $visibilityValue = if ($metadata.PSObject.Properties.Name -contains 'visibility') { [string]$metadata.visibility } else { '' }
            $privateValue = if ($metadata.PSObject.Properties.Name -contains 'private') { $metadata.private } else { $false }
            $repositoryVisibility = if ($visibilityValue -in @('public', 'private')) { (Get-Culture).TextInfo.ToTitleCase($visibilityValue) } elseif ($privateValue -eq $true) { 'Private' } else { 'Public' }
            $entry.visibility = $repositoryVisibility
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
            $clonePath = Join-Path $tempRoot ([guid]::NewGuid().ToString('N'))
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
            $entry.expectedChecks = @(Get-ExpectedQualityCheckNames $clonePath)

            & git -C $clonePath add -A
            if ($LASTEXITCODE -ne 0) { throw 'Unable to stage the update.' }
            . (Join-Path $clonePath 'scripts/RepositoryQualityGates.Detection.ps1')
            $null = @(Repair-RqgManagedIndexCasing -RepositoryRoot $clonePath)
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

            $failureStage = 'Required-check enforcement before publication'
            $enforcement = Assert-RequiredQualityChecksEnforced -RepositoryName $fullName -DefaultBranch $defaultBranch -ExpectedCheckNames @($entry.expectedChecks) -RepositoryVisibility $repositoryVisibility -Policy $requiredCheckPolicy
            $entry.requiredCheckControl = [string]$enforcement.mode
            $entry.requiredCheckException = [string]$enforcement.exceptionId

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
                $referenceText = if ($pullRequestReferences.Count) { "`nOpenProject: $($pullRequestReferences.reference -join ', ')`n" } else { '' }
                $body = if ($entry.enrolment) {
                    "$rqgPullRequestMarker`n$referenceText`nEnrols this repository in Repository Quality Gates $TargetVersion under the central automatic-enrolment policy.`n`nThe enrolment detected the repository contents, selected only applicable modules, preserved repository-owned files and rules, and passed the public working-tree and staged secret scans before creating this pull request.`n`nGitHub will merge only after the repository's required checks pass.`n"
                } else {
                    "$rqgPullRequestMarker`n$referenceText`nUpdates the managed Repository Quality Gates files to $TargetVersion.`n`nThe updater preserved repository-owned files, stopped on managed-file conflicts, and passed the public working-tree and staged secret scans before creating this pull request.`n`nGitHub will merge only after the repository's required checks pass.`n"
                }
                [IO.File]::WriteAllText($bodyPath, $body, [Text.UTF8Encoding]::new($false))
                $workPackagePrefix = if ($pullRequestReferences.Count) { '[' + $pullRequestReferences[0].displayId + '] ' } else { '' }
                $pullRequestTitle = $workPackagePrefix + $(if ($entry.enrolment) { "chore: enrol in Repository Quality Gates $TargetVersion" } else { "chore: update Repository Quality Gates to $TargetVersion" })
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
            $entry.status = Get-RqgFailureStatus -Stage $failureStage -Cause $failureCause
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
            $checkResult = Wait-PullRequestQualityChecks -RepositoryName $repositoryName -PullRequestUrl $pullRequestUrl -ExpectedCheckNames @($entry.expectedChecks) -SettleSeconds $CheckSettleSeconds
            $checkCount = [int]$checkResult.checkCount
            $entry.runners = @($checkResult.runnerNames)
            if ($pullRequestUrl -notmatch '/pull/(?<number>[1-9]\d*)/?$') { throw 'The update pull-request URL does not contain a valid pull-request number.' }
            $pullRequestNumber = [int]$Matches.number
            $failureStage = 'Verified pull-request merge'
            $preMergeState = Get-PullRequestState $repositoryName $pullRequestNumber
            if ([bool]$preMergeState.merged -or [string]$preMergeState.state -ne 'open') { throw 'The update pull request closed before the verified merge could begin.' }
            if ([string]$preMergeState.headSha -cne [string]$checkResult.headSha) { throw 'The update pull-request head changed after quality-check verification.' }
            if ([string]$preMergeState.baseRef -cne [string]$checkResult.baseRef) { throw 'The update pull-request base branch changed after quality-check verification.' }
            $failureStage = 'Required-check enforcement before verified merge'
            $mergeEnforcement = Assert-RequiredQualityChecksEnforced -RepositoryName $repositoryName -DefaultBranch ([string]$checkResult.baseRef) -ExpectedCheckNames @($entry.expectedChecks) -RepositoryVisibility ([string]$entry.visibility) -Policy $requiredCheckPolicy
            if ([string]$mergeEnforcement.mode -cne [string]$entry.requiredCheckControl -or [string]$mergeEnforcement.exceptionId -cne [string]$entry.requiredCheckException) { throw 'The required-check enforcement control changed after publication.' }
            $failureStage = 'Verified pull-request merge'
            $mergeOutput = @(& gh api --method PUT "repos/$repositoryName/pulls/$pullRequestNumber/merge" -f merge_method=squash -f "sha=$($checkResult.headSha)" 2>&1)
            if ($LASTEXITCODE -ne 0) { throw "Unable to merge the verified update pull request: $($mergeOutput -join [Environment]::NewLine)" }
            try { $mergeResponse = (($mergeOutput -join [Environment]::NewLine) | ConvertFrom-Json) }
            catch { throw 'GitHub returned invalid pull-request merge data.' }
            if ($mergeResponse.merged -ne $true) { throw "GitHub did not merge the verified update pull request: $([string]$mergeResponse.message)" }
            $failureStage = 'Default-branch version verification after merge'
            Wait-DefaultBranchTargetVersion $repositoryName ([string]$checkResult.baseRef) $TargetVersion
            $failureStage = 'Temporary branch cleanup after verified merge'
            Remove-RqgMergedBranch -RepositoryName $repositoryName -BranchName $branchName
            $entry.autoMerge = $true
            $entry.status = 'UpdatedSuccessfully'
            $entry.detail += " $checkCount reported quality check(s) passed before merge."
        }
        catch {
            $failureCause = $_.Exception.Message
            if ($_.Exception.Data.Contains('RunnerNames')) { $entry.runners = @($_.Exception.Data['RunnerNames']) }
            $cleanupDetail = $null
            $completionPullRequestState = $null
            try {
                if ([string]$entry.pullRequest -match '/pull/(?<number>[1-9]\d*)/?$') { $completionPullRequestState = Get-PullRequestState ([string]$entry.repository) ([int]$Matches.number) }
            } catch { $completionPullRequestState = $null }
            if ($completionPullRequestState -and [bool]$completionPullRequestState.merged) {
                $cleanupDetail = 'The pull request was already merged; no destructive cleanup was attempted.'
            } else {
                $cleanupOutput = @(& gh pr close ([string]$entry.pullRequest) --repo ([string]$entry.repository) --delete-branch 2>&1)
                $cleanupDetail = if ($LASTEXITCODE -eq 0) { 'The failed temporary RQG pull request and branch were removed.' } else { "Temporary RQG pull-request cleanup failed: $($cleanupOutput -join [Environment]::NewLine)" }
            }
            $entry.autoMerge = $false
            if ($failureCause -match '^No quality checks were reported|^Expected quality checks were not reported|^Timed out waiting') { $failureStage = 'Pull-request quality-check discovery' }
            elseif ($failureCause -match '^Pull-request quality checks failed') { $failureStage = 'Pull-request quality checks' }
            $entry.status = Get-RqgFailureStatus -Stage $failureStage -Cause $failureCause -PullRequestMerged ([bool]($completionPullRequestState -and [bool]$completionPullRequestState.merged))
            $entry.detail = New-RqgFailureComment -Stage $failureStage -Cause $failureCause -Version $TargetVersion -PullRequestUrl ([string]$entry.pullRequest) -UpdateBranch $branchName -Cleanup $cleanupDetail
            Write-Warning "Repository Quality Gates completion failed for '$($entry.repository)': $($entry.detail)"
        }
    }
}

$summary = [ordered]@{
    targetVersion = $TargetVersion
    apply = [bool]$Apply
    repositories = @($results)
    failed = @($results | Where-Object { Test-RqgFailureStatus ([string]$_.status) }).Count
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
