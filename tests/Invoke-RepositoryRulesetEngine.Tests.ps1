# SPDX-License-Identifier: MIT
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root 'scripts\Invoke-RepositoryRulesetEngine.ps1'
$passed = 0
$global:rqgAdministrationMutationCalls = [Collections.Generic.List[string]]::new()
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:passed++ }

function global:gh {
    $joined = $args -join ' '
    if ($joined -match '--method (POST|PATCH|PUT|DELETE)') { $global:rqgAdministrationMutationCalls.Add($joined) }
    if ($joined -match '/git/ref/heads/main --jq \.object.sha$') { 'a' * 40; $global:LASTEXITCODE=0; return }
    if ($joined -match '^api repos/owner/(disabled|stale) --jq') { '{"defaultBranch":"main","visibility":"public","private":false,"allowSquash":true,"allowMerge":false,"allowRebase":false,"deleteBranch":true,"hasIssues":false,"hasDiscussions":false,"hasWiki":false,"hasPages":false}';$global:LASTEXITCODE=0;return }
    if ($joined -match '^api repos/owner/apply --jq') {
        $mergeState = if ($global:rulesetApplied) { 'true' } else { 'false' }
        "{`"defaultBranch`":`"main`",`"visibility`":`"public`",`"private`":false,`"allowSquash`":true,`"allowMerge`":false,`"allowRebase`":false,`"deleteBranch`":$mergeState,`"hasIssues`":true,`"hasDiscussions`":false,`"hasWiki`":false,`"hasPages`":false}"
        $global:LASTEXITCODE=0; return
    }
    if ($joined -match '^api repos/owner/feature-drift --jq') { '{"defaultBranch":"main","visibility":"public","private":false,"allowSquash":true,"allowMerge":false,"allowRebase":false,"deleteBranch":true,"hasIssues":false,"hasDiscussions":true,"hasWiki":true,"hasPages":false}'; $global:LASTEXITCODE=0; return }
    if ($joined -match '^api repos/owner/(public|missing-template|exception) --jq') { $discussion = $Matches[1] -eq 'exception'; "{`"defaultBranch`":`"main`",`"visibility`":`"public`",`"private`":false,`"allowSquash`":true,`"allowMerge`":false,`"allowRebase`":false,`"deleteBranch`":true,`"hasIssues`":true,`"hasDiscussions`":$($discussion.ToString().ToLowerInvariant()),`"hasWiki`":false,`"hasPages`":false}"; $global:LASTEXITCODE=0; return }
    if ($joined -match '^api repos/owner/private --jq') { '{"defaultBranch":"main","visibility":"private","private":true,"allowSquash":true,"allowMerge":false,"allowRebase":false,"deleteBranch":true,"hasIssues":true,"hasDiscussions":false,"hasWiki":false,"hasPages":false}'; $global:LASTEXITCODE=0; return }
    if ($joined -match '^api repos/owner/unmanaged --jq') { '{"defaultBranch":"main","visibility":"public","private":false,"allowSquash":true,"allowMerge":false,"allowRebase":false,"deleteBranch":true,"hasIssues":false,"hasDiscussions":false,"hasWiki":false,"hasPages":false}'; $global:LASTEXITCODE=0; return }
    if ($joined -match '^api repos/terryrogers/DCC_LabStation_LS8 --jq') { '{"defaultBranch":"main","visibility":"public","private":false,"allowSquash":true,"allowMerge":true,"allowRebase":false,"deleteBranch":true,"hasIssues":true,"hasDiscussions":false,"hasWiki":false,"hasPages":false}'; $global:LASTEXITCODE=0; return }
    if ($joined -match 'repos/owner/unmanaged/contents/\.repository-quality-gates\.json') { 'gh: Not Found (HTTP 404)'; $global:LASTEXITCODE=1; return }
    if ($joined -match 'owner/disabled/contents/\.repository-quality-gates\.local\.json') { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"rqgEnabled":false}'));$global:LASTEXITCODE=0;return }
    if ($joined -match 'contents/\.repository-quality-gates\.local\.json') { 'gh: Not Found (HTTP 404)'; $global:LASTEXITCODE=1; return }
    if ($joined -match 'contents/\.repository-quality-gates\.json') { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"templateVersion":"3.1.4","modules":["documentation","licensing"]}')); $global:LASTEXITCODE=0; return }
    if ($joined -match 'contents/\.repository-standards\.json') {
        $profile = if ($joined -match 'owner/exception') { '{"featureExceptions":[{"id":"TEST-DISCUSSIONS","feature":"discussions","enabled":true,"owner":"Example Owner","reason":"Test community route","approvalStatus":"approved","reviewCondition":"Review annually"}]}' } else { '{"featureExceptions":[]}' }
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($profile)); $global:LASTEXITCODE=0; return
    }
    if ($joined -match 'owner/missing-template/.+question\.yml') { 'gh: Not Found (HTTP 404)'; $global:LASTEXITCODE=1; return }
    if ($joined -match 'contents/.+ISSUE_TEMPLATE') { 'abc123'; $global:LASTEXITCODE=0; return }
    if ($joined -match 'repos/owner/private/rules/branches/main') { 'Upgrade to GitHub Pro to use protected branches in private repositories.'; $global:LASTEXITCODE=1; return }
    if ($joined -match 'repos/owner/apply/rulesets\?includes_parents=false') { if ($global:rulesetApplied) { '[{"id":84,"name":"Repository Standards - Default Branch"}]' } else { '[]' }; $global:LASTEXITCODE=0; return }
    if ($joined -match '^api --method POST .*repos/owner/apply/rulesets --input (?<path>.+)$') { $global:lastRulesetBody = Get-Content -LiteralPath $Matches.path -Raw | ConvertFrom-Json; $global:rulesetApplied=$true; '{}'; $global:LASTEXITCODE=0; return }
    if ($joined -match '^api --method PATCH .*repos/owner/apply --input ') { '{}'; $global:LASTEXITCODE=0; return }
    if ($joined -match 'rulesets\?includes_parents=false') { '[{"id":42,"name":"Repository Standards - Default Branch"}]'; $global:LASTEXITCODE=0; return }
    if ($joined -match 'rulesets/42$') { '{"enforcement":"active","bypass_actors":[],"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}}}'; $global:LASTEXITCODE=0; return }
    if ($joined -match 'rulesets/84$') { '{"enforcement":"active","bypass_actors":[],"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}}}'; $global:LASTEXITCODE=0; return }
    if ($joined -match 'repos/owner/apply/rules/branches/main') {
        if (-not $global:rulesetApplied) { '[]'; $global:LASTEXITCODE=0; return }
        @(
            @{type='deletion'}, @{type='non_fast_forward'},
            @{type='pull_request';parameters=@{required_review_thread_resolution=$true;require_last_push_approval=$true;required_approving_review_count=0;allowed_merge_methods=@('squash')}},
            @{type='required_status_checks';parameters=@{strict_required_status_checks_policy=$true;required_status_checks=@(@{context='Markdown Hygiene'},@{context='Licence Decision'})}}
        ) | ConvertTo-Json -Depth 8 -Compress
        $global:LASTEXITCODE=0; return
    }
    if ($joined -match 'rules/branches/main') {
        $methods = if ($joined -match 'DCC_LabStation') { @('squash','merge') } else { @('squash') }
        @(
            @{type='deletion'}, @{type='non_fast_forward'},
            @{type='pull_request';parameters=@{required_review_thread_resolution=$true;require_last_push_approval=$true;required_approving_review_count=0;allowed_merge_methods=$methods}},
            @{type='required_status_checks';parameters=@{strict_required_status_checks_policy=$true;required_status_checks=@(@{context='Markdown Hygiene'},@{context='Licence Decision'})}}
        ) | ConvertTo-Json -Depth 8 -Compress
        $global:LASTEXITCODE=0; return
    }
    throw "Unexpected mock gh invocation: $joined"
}

try {
    $audit = & $engine -Repository @('owner/public','owner/private','owner/unmanaged','owner/missing-template','owner/feature-drift','owner/exception','terryrogers/DCC_LabStation_LS8') -OutputFormat Json | ConvertFrom-Json
    Assert-True ($audit.compliant -eq 3) 'Three public repositories should match the standard, including one approved feature exception.'
    Assert-True ($audit.deferred -eq 1) 'The unsupported private repository should be deferred.'
    $private = @($audit.repositories | Where-Object repository -eq 'owner/private')[0]
    Assert-True ($private.status -eq 'DeferredUnsupportedPlan') 'Private plan rejection should have an explicit status.'
    Assert-True ($private.exceptionId -eq 'RQG-PRIVATE-PLAN-001') 'Private plan rejection should retain the approved exception.'
    $dcc = @($audit.repositories | Where-Object repository -eq 'terryrogers/DCC_LabStation_LS8')[0]
    Assert-True ($dcc.exceptionId -eq 'RS-ADR-021-DCC') 'The DCC merge-method exception should be applied.'
    Assert-True ($dcc.status -eq 'Compliant') 'The DCC exception should accept squash and merge commits.'
    $unmanaged = @($audit.repositories | Where-Object repository -eq 'owner/unmanaged')[0]
    Assert-True ($unmanaged.status -eq 'MissingManagedState') 'A repository without RQG state should require enrolment without an unsafe guessed ruleset.'
    $missingTemplate = @($audit.repositories | Where-Object repository -eq 'owner/missing-template')[0]
    Assert-True ($missingTemplate.status -eq 'NonCompliant') 'A missing local issue form should fail the feature contract.'
    Assert-True ($missingTemplate.missingControls -contains 'issue-template:.github/ISSUE_TEMPLATE/question.yml') 'The missing issue form should be identified exactly.'
    $featureDrift = @($audit.repositories | Where-Object repository -eq 'owner/feature-drift')[0]
    Assert-True ($featureDrift.missingControls -contains 'repository-feature:issues') 'Disabled Issues should fail the feature contract.'
    Assert-True ($featureDrift.missingControls -contains 'repository-feature:discussions') 'Enabled Discussions should fail without an exception.'
    $featureException = @($audit.repositories | Where-Object repository -eq 'owner/exception')[0]
    Assert-True ($featureException.featureExceptionIds -contains 'TEST-DISCUSSIONS') 'An approved repository-local feature exception should be reported.'
    $policy = Get-Content -LiteralPath (Join-Path $root 'policy\repository-ruleset-policy.json') -Raw | ConvertFrom-Json
    Assert-True ($policy.default.bypassActors.Count -eq 0) 'The standard ruleset must have no bypass actors.'
    Assert-True ($policy.repositoryExceptions.Count -eq 1) 'Only the approved repository exception should exist.'
    Assert-True ($policy.schemaVersion -eq 2) 'The combined ruleset & repository-feature policy should use schema 2.'
    $global:rulesetApplied = $false
    $global:lastRulesetBody = $null
    $apply = & $engine -Repository 'owner/apply' -Apply -OutputFormat Json | ConvertFrom-Json
    Assert-True ($apply.repositories[0].status -eq 'AppliedAndVerified') 'Apply mode should create & verify a missing managed ruleset.'
    Assert-True ($global:lastRulesetBody.bypass_actors.Count -eq 0) 'The applied ruleset should contain no bypass actors.'
    Assert-True (@($global:lastRulesetBody.rules | Where-Object type -eq 'required_status_checks').Count -eq 1) 'The applied ruleset should require deployed quality checks.'
    $before=$global:rqgAdministrationMutationCalls.Count
    $disabled=& $engine -Repository 'owner/disabled' -Apply -OutputFormat Json | ConvertFrom-Json
    Assert-True ($disabled.repositories[0].status -eq 'Disabled' -and $global:rqgAdministrationMutationCalls.Count -eq $before) 'A disabled repository must not receive feature or ruleset writes.'
    $unmanagedApply=& $engine -Repository 'owner/unmanaged' -Apply -OutputFormat Json | ConvertFrom-Json
    Assert-True ($unmanagedApply.repositories[0].status -eq 'MissingManagedState' -and $global:rqgAdministrationMutationCalls.Count -eq $before) 'Feature drift on an unmanaged repository must not be mutated.'
    $staleFailure=$null
    try { & $engine -Repository 'owner/stale' -Apply -ExpectedTemplateVersion '3.2.0' -ExpectedCommit ('a'*40) -OutputFormat Json | Out-Null } catch { $staleFailure=$_ }
    Assert-True ($null -ne $staleFailure -and $staleFailure.Exception.Message -match 'verified fleet target' -and $global:rqgAdministrationMutationCalls.Count -eq $before) 'A stale destination must fail before the first settings write.'
    $parseTokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($engine,[ref]$parseTokens,[ref]$parseErrors)
    $preserve=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Preserve-IndependentRules'},$true)
    . ([scriptblock]::Create($preserve.Extent.Text))
    $desired=[pscustomobject]@{rules=@([pscustomobject]@{type='pull_request';parameters=[ordered]@{required_approving_review_count=0;dismiss_stale_reviews_on_push=$false;require_code_owner_review=$false;require_last_push_approval=$true;required_review_thread_resolution=$true}})}
    $existing='{"rules":[{"type":"pull_request","parameters":{"required_approving_review_count":0,"dismiss_stale_reviews_on_push":true,"require_code_owner_review":true,"require_last_push_approval":true,"required_review_thread_resolution":true}}]}' | ConvertFrom-Json
    $preserved=Preserve-IndependentRules $desired $existing
    $saved=$preserved | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    Assert-True ($saved.rules[0].parameters.dismiss_stale_reviews_on_push -and $saved.rules[0].parameters.require_code_owner_review) 'Serialized settings must retain independent stale-approval dismissal and code-owner review.'
    $existing.rules[0].parameters.required_approving_review_count=2
    $strongerFailure=$null
    try { Preserve-IndependentRules $desired $existing | Out-Null } catch { $strongerFailure=$_ }
    Assert-True ($null -ne $strongerFailure -and $strongerFailure.Exception.Message -match 'stronger review') 'A stronger numeric approval requirement must block replacement.'
    Write-Output "$passed assertions passed."
}
finally {
    Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
    Remove-Variable rulesetApplied -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable lastRulesetBody -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable rqgAdministrationMutationCalls -Scope Global -ErrorAction SilentlyContinue
}
