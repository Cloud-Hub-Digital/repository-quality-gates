# SPDX-License-Identifier: MIT
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts/RepositoryQualityGates.Lifecycle.ps1')
. (Join-Path $root 'scripts/RepositoryQualityGates.Deactivation.ps1')
$passed=0
function Assert-Removal([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message };$script:passed++ }
function Assert-Blocked([scriptblock]$Action,[string]$Pattern) { $failure=$null;try { &$Action | Out-Null } catch {$failure=$_};Assert-Removal ($null -ne $failure -and $failure.Exception.Message -match $Pattern) "Expected removal blocker: $Pattern" }
$script:privatePlan=$false;$script:otherRule=$false;$script:classic=$false
$script:checks=@([pscustomobject]@{name='Secret Scan';status='completed';conclusion='success';app=[pscustomobject]@{id=15368;slug='github-actions'}},[pscustomobject]@{name='Independent Product Test';status='completed';conclusion='success';app=[pscustomobject]@{id=77;slug='independent'}})
$script:statuses=@()
$script:detail=[pscustomobject]@{
    id=42;name='Repository Standards - Default Branch';target='branch';enforcement='active';bypass_actors=@()
    conditions=[pscustomobject]@{ref_name=[pscustomobject]@{include=@('~DEFAULT_BRANCH');exclude=@()}}
    rules=@([pscustomobject]@{type='deletion'},[pscustomobject]@{type='non_fast_forward'},[pscustomobject]@{type='pull_request';parameters=[pscustomobject]@{required_approving_review_count=1}},[pscustomobject]@{type='required_status_checks';parameters=[pscustomobject]@{strict_required_status_checks_policy=$true;required_status_checks=@([pscustomobject]@{context='Secret Scan';integration_id=15368},[pscustomobject]@{context='Independent Product Test';integration_id=77})}})
}
function Assert-RequiredQualityChecksEnforced($RepositoryName,$Branch,$ExpectedChecks,$Visibility,$Policy) { [pscustomobject]@{platformLimitationVerified=$script:privatePlan;mode=if($script:privatePlan){'rqg-verified-merge-exception'}else{'github-rules-required'};exceptionId=if($script:privatePlan){'RQG-PRIVATE-PLAN-001'}else{$null};requiredChecks=@('Secret Scan','Independent Product Test')} }
function Invoke-RqgDeactivationApi([string[]]$Arguments) {
    $text=$Arguments -join ' '
    if ($text -match '/check-runs\?') { return $script:checks }
    if ($text -match '/statuses\?') { return $script:statuses }
    if ($text -match '/rulesets\?') { if ($script:otherRule) { return @([pscustomobject]@{id=42;name='Repository Standards - Default Branch'},[pscustomobject]@{id=43;name='Independent Controls'}) };return @([pscustomobject]@{id=42;name='Repository Standards - Default Branch'}) }
    if ($text -match '/rulesets/42$') { return $script:detail }
    if ($text -match '/rulesets/43$') { return [pscustomobject]@{enforcement='active';rules=@([pscustomobject]@{type='required_status_checks';parameters=[pscustomobject]@{required_status_checks=@([pscustomobject]@{context='Secret Scan'})}})} }
    throw "Unexpected synthetic removal API: $text"
}
function global:gh {
    if (($args -join ' ') -match '/protection/required_status_checks$') { if ($script:classic) { '{"contexts":["Secret Scan"]}';$global:LASTEXITCODE=0 } else { 'HTTP 404';$global:LASTEXITCODE=1 };return }
    throw 'Unexpected native invocation during removal test.'
}
try {
    $baseline=Assert-RqgDeactivationBaseline 'owner/product' ('a'*40) @('Secret Scan')
    Assert-Removal $true 'A complete passing baseline should be accepted.'
    $script:checks[0].conclusion='failure'
    Assert-Blocked { Assert-RqgDeactivationBaseline 'owner/product' ('a'*40) @('Secret Scan') } 'has not passed'
    $script:checks[0].conclusion='success';$script:checks[1].conclusion='cancelled'
    Assert-Blocked { Assert-RqgDeactivationBaseline 'owner/product' ('a'*40) @('Secret Scan') } 'failed or incomplete'
    $script:checks[1].conclusion='success'
    Assert-Blocked { Assert-RqgDeactivationBaseline 'owner/product' ('a'*40) @('Missing Check') } 'has not passed'
    $script:statuses=@([pscustomobject]@{context='External Product Validation';state='failure';created_at='2026-01-01T00:00:00Z'})
    Assert-Blocked { Assert-RqgDeactivationBaseline 'owner/product' ('a'*40) @('Secret Scan') } 'commit status'
    $script:statuses=@()
    $original=$script:detail.rules | ConvertTo-Json -Depth 12 -Compress
    $plan=Get-RqgDeactivationRules 'owner/product' 'main' @('Secret Scan') 123 'Public' ([pscustomobject]@{}) $baseline.providers
    $required=@($plan.transition.rules | Where-Object type -eq 'required_status_checks')[0].parameters.required_status_checks
    Assert-Removal (@($required | Where-Object { $_.context -eq 'RQG Deactivation' -and $_.integration_id -eq 123 }).Count -eq 1) 'The removal check must be bound to the issuing App.'
    Assert-Removal (@($required | Where-Object { $_.context -eq 'Independent Product Test' -and $_.integration_id -eq 77 }).Count -eq 1) 'An independent provider-bound check must remain required.'
    Assert-Removal ($plan.expectedChecks -contains 'Independent Product Test' -and $plan.expectedChecks -contains 'RQG Deactivation') 'The controlled merge must require both removal and independent checks.'
    Assert-Removal (($script:detail.rules | ConvertTo-Json -Depth 12 -Compress) -ceq $original) 'Preview must not modify the original ruleset object.'
    Assert-Removal (@($plan.transition.rules | Where-Object type -eq 'pull_request')[0].parameters.required_approving_review_count -eq 1) 'Independent approval requirements must remain intact.'
    $checkRule=@($script:detail.rules | Where-Object type -eq 'required_status_checks')[0]
    $checkRule.parameters.required_status_checks[0].integration_id=99
    Assert-Blocked { Get-RqgDeactivationRules 'owner/product' 'main' @('Secret Scan') 123 'Public' ([pscustomobject]@{}) $baseline.providers } 'independent provider'
    $checkRule.parameters.required_status_checks[0].integration_id=15368
    $script:checks[0].app.slug='independent'
    Assert-Blocked { Assert-RqgDeactivationBaseline 'owner/product' ('a'*40) @('Secret Scan') } 'provider is ambiguous'
    $script:checks[0].app.slug='github-actions'
    $live=ConvertTo-RqgProtectionBody $plan.transition
    $live.rules += [pscustomobject]@{type='required_signatures'}
    $live.conditions.ref_name.exclude=@('refs/heads/protected-extra')
    $cleaned=Remove-RqgBoundRemovalRequirement $live 123
    Assert-Removal (@($cleaned.rules | Where-Object type -eq 'required_signatures').Count -eq 1) 'Cleanup must retain protections added after the removal transition.'
    Assert-Removal ($cleaned.conditions.ref_name.exclude -contains 'refs/heads/protected-extra') 'Cleanup must retain current branch conditions.'
    Assert-Removal (@($cleaned.rules | Where-Object type -eq 'required_status_checks')[0].parameters.required_status_checks[0].integration_id -eq 77) 'Cleanup must preserve the live independent provider binding.'
    Assert-Blocked { Assert-RqgProtectionUnchanged $live $plan.transition } 'configuration changed'
    $conditionsOnly=ConvertTo-RqgProtectionBody $plan.transition
    $conditionsOnly.conditions.ref_name.exclude=@('refs/heads/changed')
    Assert-Blocked { Assert-RqgProtectionUnchanged $conditionsOnly $plan.transition } 'configuration changed'
    $correct=[pscustomobject]@{headSha='a'*40;baseRef='main';state='open';merged=$false}
    Assert-RqgRemovalDestination $correct ('a'*40) 'main'
    Assert-Removal $true 'An unchanged removal destination must remain acceptable.'
    $correct.baseRef='different-branch'
    Assert-Blocked { Assert-RqgRemovalDestination $correct ('a'*40) 'main' } 'destination changed'
    $correct.baseRef='main';$correct.state='closed'
    Assert-Blocked { Assert-RqgRemovalDestination $correct ('a'*40) 'main' } 'no longer open'
    $script:otherRule=$true
    Assert-Blocked { Get-RqgDeactivationRules 'owner/product' 'main' @('Secret Scan') 123 'Public' ([pscustomobject]@{}) $baseline.providers } 'independent ruleset'
    $script:otherRule=$false;$script:classic=$true
    Assert-Blocked { Get-RqgDeactivationRules 'owner/product' 'main' @('Secret Scan') 123 'Public' ([pscustomobject]@{}) $baseline.providers } 'Classic branch protection'
    $script:classic=$false
    $script:detail.bypass_actors=@([pscustomobject]@{actor_id=1})
    Assert-Blocked { Get-RqgDeactivationRules 'owner/product' 'main' @('Secret Scan') 123 'Public' ([pscustomobject]@{}) } 'ownership boundary'
    $script:detail.bypass_actors=@();$script:privatePlan=$true
    $private=Get-RqgDeactivationRules 'owner/product' 'main' @('Secret Scan') 123 'Private' ([pscustomobject]@{})
    Assert-Removal ($private.exceptionId -eq 'RQG-PRIVATE-PLAN-001' -and $null -eq $private.ruleset) 'The verified private-plan exception must not create or weaken native rules.'
    Assert-Removal ($private.expectedChecks.Count -eq 1 -and $private.expectedChecks[0] -eq 'RQG Deactivation') 'The private controller must still observe the exact removal check.'
    Write-Output "$passed checked-deactivation assertions passed."
} finally { Remove-Item Function:\global:gh -ErrorAction SilentlyContinue }
