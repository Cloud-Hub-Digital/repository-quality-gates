# SPDX-License-Identifier: MIT
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root 'scripts\Invoke-RepositoryRulesetEngine.ps1'
$passed = 0
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:passed++ }

function global:gh {
    $joined = $args -join ' '
    if ($joined -match '^api repos/owner/apply --jq') {
        $mergeState = if ($global:rulesetApplied) { 'true' } else { 'false' }
        "{`"defaultBranch`":`"main`",`"visibility`":`"public`",`"private`":false,`"allowSquash`":true,`"allowMerge`":false,`"allowRebase`":false,`"deleteBranch`":$mergeState,`"hasIssues`":true,`"hasDiscussions`":false,`"hasWiki`":false,`"hasPages`":false}"
        $global:LASTEXITCODE=0; return
    }
    if ($joined -match '^api repos/owner/feature-drift --jq') { '{"defaultBranch":"main","visibility":"public","private":false,"allowSquash":true,"allowMerge":false,"allowRebase":false,"deleteBranch":true,"hasIssues":false,"hasDiscussions":true,"hasWiki":true,"hasPages":false}'; $global:LASTEXITCODE=0; return }
    if ($joined -match '^api repos/owner/(public|missing-template|exception) --jq') { $discussion = $Matches[1] -eq 'exception'; "{`"defaultBranch`":`"main`",`"visibility`":`"public`",`"private`":false,`"allowSquash`":true,`"allowMerge`":false,`"allowRebase`":false,`"deleteBranch`":true,`"hasIssues`":true,`"hasDiscussions`":$($discussion.ToString().ToLowerInvariant()),`"hasWiki`":false,`"hasPages`":false}"; $global:LASTEXITCODE=0; return }
    if ($joined -match '^api repos/owner/private --jq') { '{"defaultBranch":"main","visibility":"private","private":true,"allowSquash":true,"allowMerge":false,"allowRebase":false,"deleteBranch":true,"hasIssues":true,"hasDiscussions":false,"hasWiki":false,"hasPages":false}'; $global:LASTEXITCODE=0; return }
    if ($joined -match '^api repos/owner/unmanaged --jq') { '{"defaultBranch":"main","visibility":"public","private":false,"allowSquash":true,"allowMerge":false,"allowRebase":false,"deleteBranch":true,"hasIssues":true,"hasDiscussions":false,"hasWiki":false,"hasPages":false}'; $global:LASTEXITCODE=0; return }
    if ($joined -match '^api repos/terryrogers/DCC_LabStation_LS8 --jq') { '{"defaultBranch":"main","visibility":"public","private":false,"allowSquash":true,"allowMerge":true,"allowRebase":false,"deleteBranch":true,"hasIssues":true,"hasDiscussions":false,"hasWiki":false,"hasPages":false}'; $global:LASTEXITCODE=0; return }
    if ($joined -match 'repos/owner/unmanaged/contents/\.repository-quality-gates\.json') { 'gh: Not Found (HTTP 404)'; $global:LASTEXITCODE=1; return }
    if ($joined -match 'contents/\.repository-quality-gates\.json') { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"modules":["documentation","licensing"]}')); $global:LASTEXITCODE=0; return }
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
    Write-Output "$passed assertions passed."
}
finally {
    Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
    Remove-Variable rulesetApplied -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable lastRulesetBody -Scope Global -ErrorAction SilentlyContinue
}
