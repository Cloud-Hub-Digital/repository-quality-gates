# SPDX-License-Identifier: MIT
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$Repository,
    [string]$PolicyPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'policy\repository-ruleset-policy.json'),
    [switch]$Apply,
    [ValidateSet('Objects', 'Json')][string]$OutputFormat = 'Objects',
    [string]$ResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Gh([string[]]$Arguments, [string]$FailureMessage, [switch]$AllowFailure) {
    $output = @(& gh @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($output -join [Environment]::NewLine).Trim()
    if ($exitCode -ne 0 -and -not $AllowFailure) { throw "$FailureMessage $text" }
    return [pscustomobject]@{ ExitCode = $exitCode; Text = $text }
}

function Read-Json([string]$Text, [string]$FailureMessage) {
    try { return $Text | ConvertFrom-Json }
    catch { throw $FailureMessage }
}

function Test-PrivatePlanLimitation([string]$Message) {
    return -not [string]::IsNullOrWhiteSpace($Message) -and $Message -match '(?i)(upgrade\s+to\s+GitHub\s+(?:Pro|Team|Enterprise)|branch protection rules are not available for private repositories|protected branches are available (?:to|for).*(?:Pro|Team|Enterprise)|endpoint is unavailable for private repositories on (?:the|your) current plan)'
}

function Get-ExpectedChecks([object]$State) {
    $checkNamesByModule = @{
        documentation = 'Markdown Hygiene'; dotnet = '.NET Build And Test'; go = 'Go Format, Vet, Test, And Build'
        licensing = 'Licence Decision'; 'module-drift' = 'Report Required Quality Gates'; node = 'JavaScript Syntax, Test, And Build'
        php = 'PHP Syntax And Project Test'; platformio = 'Firmware Build'; powershell = 'PowerShell And Regression Tests'
        python = 'Python Compile And Test'; 'secret-scanning' = 'Secret Scan'; shell = 'Shell Syntax'
    }
    $checks = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($module in @($State.modules)) {
        $name = [string]$module
        if ($checkNamesByModule.ContainsKey($name)) { $null = $checks.Add([string]$checkNamesByModule[$name]) }
    }
    if (-not $checks.Count) { throw 'The managed state does not identify any expected quality checks.' }
    return @($checks | Sort-Object)
}

function Get-RepositoryPolicy([object]$Policy, [string]$RepositoryName) {
    $effective = [ordered]@{}
    foreach ($property in $Policy.default.PSObject.Properties) { $effective[$property.Name] = $property.Value }
    $matches = @($Policy.repositoryExceptions | Where-Object { [string]$_.repository -ceq $RepositoryName })
    if ($matches.Count -gt 1) { throw "$RepositoryName has more than one ruleset exception." }
    $exceptionId = $null
    if ($matches.Count -eq 1) {
        $exceptionId = [string]$matches[0].id
        foreach ($property in $matches[0].PSObject.Properties | Where-Object Name -notin @('id', 'repository')) { $effective[$property.Name] = $property.Value }
    }
    return [pscustomobject]@{ Settings = [pscustomobject]$effective; ExceptionId = $exceptionId }
}

function Get-RepositoryContext([string]$RepositoryName) {
    $metadataResult = Invoke-Gh @('api', "repos/$RepositoryName", '--jq', '{defaultBranch:.default_branch,visibility:.visibility,private:.private,allowSquash:.allow_squash_merge,allowMerge:.allow_merge_commit,allowRebase:.allow_rebase_merge,deleteBranch:.delete_branch_on_merge}') 'Unable to read repository metadata.'
    $metadata = Read-Json $metadataResult.Text "GitHub returned invalid metadata for $RepositoryName."
    $defaultBranch = ([string]$metadata.defaultBranch).Trim()
    if (-not $defaultBranch) { throw "$RepositoryName does not identify a default branch." }
    $visibility = if ([bool]$metadata.private) { 'Private' } else { 'Public' }
    $stateResult = Invoke-Gh @('api', "repos/$RepositoryName/contents/$([Uri]::EscapeDataString('.repository-quality-gates.json'))?ref=$([Uri]::EscapeDataString($defaultBranch))", '--jq', '.content') 'Unable to read the managed state.' -AllowFailure
    if ($stateResult.ExitCode -ne 0) {
        if ($stateResult.Text -match '(?i)(HTTP 404|Not Found)') { return [pscustomobject]@{ Metadata = $metadata; DefaultBranch = $defaultBranch; Visibility = $visibility; Managed = $false; ExpectedChecks = @() } }
        throw "Unable to read the managed state for $RepositoryName. $($stateResult.Text)"
    }
    try { $state = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($stateResult.Text -replace '\s', ''))) | ConvertFrom-Json }
    catch { throw "GitHub returned invalid managed state for $RepositoryName." }
    return [pscustomobject]@{ Metadata = $metadata; DefaultBranch = $defaultBranch; Visibility = $visibility; Managed = $true; ExpectedChecks = @(Get-ExpectedChecks $state) }
}

function Test-RepositoryRules([string]$RepositoryName, [object]$Context, [object]$EffectivePolicy, [object]$Policy) {
    $encodedBranch = [Uri]::EscapeDataString($Context.DefaultBranch)
    $ruleResult = Invoke-Gh @('api', '-H', 'Accept: application/vnd.github+json', "repos/$RepositoryName/rules/branches/$encodedBranch`?per_page=100") 'Unable to inspect active default-branch rules.' -AllowFailure
    if ($ruleResult.ExitCode -ne 0) {
        if ($Context.Visibility -eq 'Private' -and (Test-PrivatePlanLimitation $ruleResult.Text)) {
            return [pscustomobject]@{ Deferred = $true; Missing = @(); Detail = $ruleResult.Text }
        }
        throw "Unable to inspect active default-branch rules for $RepositoryName. $($ruleResult.Text)"
    }
    $rules = @((Read-Json $ruleResult.Text "GitHub returned invalid active default-branch rules for $RepositoryName."))
    if ($rules.Count -ge 100) { throw "$RepositoryName reached the active-rule API page limit." }
    $missing = [Collections.Generic.List[string]]::new()
    $rulesetResult = Invoke-Gh @('api', '-H', 'Accept: application/vnd.github+json', "repos/$RepositoryName/rulesets?includes_parents=false&per_page=100") 'Unable to list repository rulesets.'
    $rulesets = @((Read-Json $rulesetResult.Text "GitHub returned invalid ruleset data for $RepositoryName."))
    if ($rulesets.Count -ge 100) { throw "$RepositoryName reached the repository-ruleset API page limit." }
    $managedRulesets = @($rulesets | Where-Object { [string]$_.name -ceq [string]$Policy.rulesetName })
    if ($managedRulesets.Count -gt 1) { throw "$RepositoryName has duplicate managed rulesets." }
    if (-not $managedRulesets.Count) { $missing.Add('managed-ruleset') }
    else {
        $detailResult = Invoke-Gh @('api', '-H', 'Accept: application/vnd.github+json', "repos/$RepositoryName/rulesets/$([long]$managedRulesets[0].id)") 'Unable to read the managed repository ruleset.'
        $detail = Read-Json $detailResult.Text "GitHub returned invalid managed ruleset data for $RepositoryName."
        if ([string]$detail.enforcement -cne 'active') { $missing.Add('active-enforcement') }
        if (@($detail.bypass_actors).Count) { $missing.Add('no-bypass-actors') }
        $includes = @($detail.conditions.ref_name.include | ForEach-Object { [string]$_ })
        if ($includes.Count -ne 1 -or $includes[0] -cne '~DEFAULT_BRANCH') { $missing.Add('default-branch-target') }
    }
    if ([bool]$EffectivePolicy.blockDeletion -and -not @($rules | Where-Object type -eq 'deletion').Count) { $missing.Add('block-deletion') }
    if ([bool]$EffectivePolicy.blockForcePush -and -not @($rules | Where-Object type -eq 'non_fast_forward').Count) { $missing.Add('block-force-push') }
    $pullRules = @($rules | Where-Object type -eq 'pull_request')
    if (-not $pullRules.Count) { $missing.Add('require-pull-request') }
    else {
        $pull = $pullRules[0].parameters
        if ([bool]$pull.required_review_thread_resolution -ne [bool]$EffectivePolicy.requireConversationResolution) { $missing.Add('conversation-resolution') }
        if ([bool]$pull.require_last_push_approval -ne [bool]$EffectivePolicy.requireLastPushApproval) { $missing.Add('last-push-approval') }
        if ([int]$pull.required_approving_review_count -ne [int]$EffectivePolicy.requiredApprovingReviewCount) { $missing.Add('approving-review-count') }
        $expectedMethods = @('squash')
        if ([bool]$EffectivePolicy.allowMergeCommit) { $expectedMethods += 'merge' }
        $actualMethods = @($pull.allowed_merge_methods | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        if (Compare-Object -ReferenceObject @($expectedMethods | Sort-Object) -DifferenceObject $actualMethods) { $missing.Add('allowed-merge-methods') }
    }
    $statusRules = @($rules | Where-Object type -eq 'required_status_checks')
    if (-not $statusRules.Count) { $missing.Add('required-status-checks') }
    else {
        $contexts = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($statusRule in $statusRules) {
            if (-not [bool]$statusRule.parameters.strict_required_status_checks_policy) { $missing.Add('current-status-checks') }
            foreach ($check in @($statusRule.parameters.required_status_checks)) { if ([string]$check.context) { $null = $contexts.Add([string]$check.context) } }
        }
        foreach ($expected in $Context.ExpectedChecks) { if (-not $contexts.Contains($expected)) { $missing.Add("status-check:$expected") } }
    }
    $metadata = $Context.Metadata
    if ([bool]$metadata.allowSquash -ne [bool]$EffectivePolicy.allowSquashMerge) { $missing.Add('repository-squash-setting') }
    if ([bool]$metadata.allowMerge -ne [bool]$EffectivePolicy.allowMergeCommit) { $missing.Add('repository-merge-commit-setting') }
    if ([bool]$metadata.allowRebase -ne [bool]$EffectivePolicy.allowRebaseMerge) { $missing.Add('repository-rebase-setting') }
    if ([bool]$metadata.deleteBranch -ne [bool]$EffectivePolicy.deleteBranchOnMerge) { $missing.Add('delete-branch-on-merge') }
    return [pscustomobject]@{ Deferred = $false; Missing = @($missing | Sort-Object -Unique); Detail = $null }
}

function New-RulesetBody([object]$Policy, [object]$EffectivePolicy, [object]$Context) {
    $methods = @('squash')
    if ([bool]$EffectivePolicy.allowMergeCommit) { $methods += 'merge' }
    $checks = @($Context.ExpectedChecks | ForEach-Object { [ordered]@{ context = $_ } })
    return [ordered]@{
        name = [string]$Policy.rulesetName; target = [string]$Policy.target; enforcement = [string]$Policy.enforcement
        bypass_actors = @(); conditions = [ordered]@{ ref_name = [ordered]@{ include = @('~DEFAULT_BRANCH'); exclude = @() } }
        rules = @(
            [ordered]@{ type = 'deletion' },
            [ordered]@{ type = 'non_fast_forward' },
            [ordered]@{ type = 'pull_request'; parameters = [ordered]@{
                dismiss_stale_reviews_on_push = $false; require_code_owner_review = $false
                require_last_push_approval = [bool]$EffectivePolicy.requireLastPushApproval
                required_approving_review_count = [int]$EffectivePolicy.requiredApprovingReviewCount
                required_review_thread_resolution = [bool]$EffectivePolicy.requireConversationResolution
                allowed_merge_methods = $methods
            } },
            [ordered]@{ type = 'required_status_checks'; parameters = [ordered]@{
                strict_required_status_checks_policy = [bool]$EffectivePolicy.requireCurrentStatusChecks
                do_not_enforce_on_create = $false; required_status_checks = $checks
            } }
        )
    }
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI is required.' }
if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) { throw 'The repository ruleset policy is missing.' }
$policy = Read-Json (Get-Content -LiteralPath $PolicyPath -Raw) 'The repository ruleset policy is invalid JSON.'
if ([int]$policy.schemaVersion -ne 1 -or [string]$policy.target -cne 'branch' -or [string]$policy.enforcement -cne 'active' -or [string]$policy.privatePlanException.id -cne 'RQG-PRIVATE-PLAN-001') { throw 'The repository ruleset policy is not an approved schema 1 policy.' }
$requiredTrueDefaults = @('requireLastPushApproval','requireConversationResolution','requireCurrentStatusChecks','allowSquashMerge','deleteBranchOnMerge','blockDeletion','blockForcePush')
if (@($requiredTrueDefaults | Where-Object { $policy.default.$_ -ne $true }).Count -or $policy.default.allowMergeCommit -ne $false -or $policy.default.allowRebaseMerge -ne $false -or [int]$policy.default.requiredApprovingReviewCount -ne 0 -or @($policy.default.bypassActors).Count) { throw 'The repository ruleset policy weakens the approved defaults.' }
$exceptions = @($policy.repositoryExceptions)
if ($exceptions.Count -ne 1 -or [string]$exceptions[0].id -cne 'RS-ADR-021-DCC' -or [string]$exceptions[0].repository -cne 'terryrogers/DCC_LabStation_LS8' -or $exceptions[0].allowMergeCommit -ne $true -or @($exceptions[0].PSObject.Properties.Name | Where-Object { $_ -notin @('id','repository','allowMergeCommit') }).Count) { throw 'The repository ruleset policy contains an unapproved repository exception.' }

$rows = [Collections.Generic.List[object]]::new()
foreach ($repositoryName in @($Repository | Sort-Object -Unique)) {
    if ($repositoryName -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw "Invalid repository name: $repositoryName" }
    $effective = Get-RepositoryPolicy $policy $repositoryName
    $context = Get-RepositoryContext $repositoryName
    if (-not $context.Managed) {
        $rows.Add([pscustomobject][ordered]@{
            repository = $repositoryName; visibility = $context.Visibility; defaultBranch = $context.DefaultBranch
            status = 'MissingManagedState'; action = 'EnrollRepositoryQualityGates'; exceptionId = $null
            expectedChecks = @(); missingControls = @('repository-quality-gates-state')
        })
        continue
    }
    $audit = Test-RepositoryRules $repositoryName $context $effective.Settings $policy
    $action = 'None'
    $status = 'Compliant'
    if ($audit.Deferred) { $status = 'DeferredUnsupportedPlan'; $action = 'ReconcileWhenSupportedOrPublic' }
    elseif ($audit.Missing.Count) { $status = 'NonCompliant'; $action = if ($Apply) { 'ApplyRuleset' } else { 'ApplyRequired' } }

    if ($Apply -and $status -eq 'NonCompliant') {
        $list = Invoke-Gh @('api', '-H', 'Accept: application/vnd.github+json', "repos/$repositoryName/rulesets?includes_parents=false&per_page=100") 'Unable to list repository rulesets.'
        $rulesets = @((Read-Json $list.Text "GitHub returned invalid ruleset data for $repositoryName."))
        if ($rulesets.Count -ge 100) { throw "$repositoryName reached the repository-ruleset API page limit." }
        $managed = @($rulesets | Where-Object { [string]$_.name -ceq [string]$policy.rulesetName })
        if ($managed.Count -gt 1) { throw "$repositoryName has duplicate managed rulesets." }
        $bodyPath = [IO.Path]::GetTempFileName()
        try {
            [IO.File]::WriteAllText($bodyPath, ((New-RulesetBody $policy $effective.Settings $context) | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
            if ($managed.Count) { $null = Invoke-Gh @('api', '--method', 'PUT', '-H', 'Accept: application/vnd.github+json', "repos/$repositoryName/rulesets/$([long]$managed[0].id)", '--input', $bodyPath) 'Unable to update the managed repository ruleset.' }
            else { $null = Invoke-Gh @('api', '--method', 'POST', '-H', 'Accept: application/vnd.github+json', "repos/$repositoryName/rulesets", '--input', $bodyPath) 'Unable to create the managed repository ruleset.' }
        }
        finally { Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue }
        $settingsPath = [IO.Path]::GetTempFileName()
        try {
            $settingsBody = [ordered]@{ allow_squash_merge = [bool]$effective.Settings.allowSquashMerge; allow_merge_commit = [bool]$effective.Settings.allowMergeCommit; allow_rebase_merge = [bool]$effective.Settings.allowRebaseMerge; delete_branch_on_merge = [bool]$effective.Settings.deleteBranchOnMerge }
            [IO.File]::WriteAllText($settingsPath, ($settingsBody | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            $null = Invoke-Gh @('api', '--method', 'PATCH', '-H', 'Accept: application/vnd.github+json', "repos/$repositoryName", '--input', $settingsPath) 'Unable to apply repository merge settings.'
        }
        finally { Remove-Item -LiteralPath $settingsPath -Force -ErrorAction SilentlyContinue }
        $context = Get-RepositoryContext $repositoryName
        $audit = Test-RepositoryRules $repositoryName $context $effective.Settings $policy
        if ($audit.Deferred -or $audit.Missing.Count) { throw "$repositoryName did not pass post-apply ruleset verification." }
        $status = 'AppliedAndVerified'; $action = 'None'
    }

    $rows.Add([pscustomobject][ordered]@{
        repository = $repositoryName; visibility = $context.Visibility; defaultBranch = $context.DefaultBranch
        status = $status; action = $action; exceptionId = if ($audit.Deferred) { [string]$policy.privatePlanException.id } else { $effective.ExceptionId }
        expectedChecks = @($context.ExpectedChecks); missingControls = @($audit.Missing)
    })
}

$result = [pscustomobject][ordered]@{
    schemaVersion = 1; generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O'); mode = if ($Apply) { 'Apply' } else { 'Audit' }
    repositories = @($rows); compliant = @($rows | Where-Object status -in @('Compliant', 'AppliedAndVerified')).Count
    deferred = @($rows | Where-Object status -eq 'DeferredUnsupportedPlan').Count; nonCompliant = @($rows | Where-Object status -in @('NonCompliant','MissingManagedState')).Count
}
$json = $result | ConvertTo-Json -Depth 12
if ($ResultPath) {
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($ResultPath)); if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($ResultPath), $json, [Text.UTF8Encoding]::new($false))
}
if ($OutputFormat -eq 'Json') { $json } else { $result }
