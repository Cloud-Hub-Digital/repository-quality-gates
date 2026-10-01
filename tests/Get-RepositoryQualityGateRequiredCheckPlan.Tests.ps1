# SPDX-License-Identifier: MIT
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$planner = Join-Path $root 'scripts\Get-RepositoryQualityGateRequiredCheckPlan.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('rqg-required-check-plan-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$passed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:passed++
}

try {
    function global:gh {
        $joined = $args -join ' '
        if ($joined -match '^api repos/owner/public --jq') { '{"defaultBranch":"main","visibility":"public","private":false}'; $global:LASTEXITCODE = 0; return }
        if ($joined -match '^api repos/owner/private --jq') { '{"defaultBranch":"main","visibility":"private","private":true}'; $global:LASTEXITCODE = 0; return }
        if ($joined -match 'contents/\.repository-quality-gates\.json') {
            [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"modules":["licensing","secret-scanning"]}'))
            $global:LASTEXITCODE = 0
            return
        }
        if ($joined -match 'repos/owner/public/rules/branches/main') {
            @([pscustomobject]@{ type = 'required_status_checks'; parameters = [pscustomobject]@{ required_status_checks = @([pscustomobject]@{ context = 'Secret Scan' }) } }) | ConvertTo-Json -Depth 8 -Compress
            $global:LASTEXITCODE = 0
            return
        }
        if ($joined -match 'repos/owner/private/rules/branches/main') {
            'Upgrade to GitHub Pro to use protected branches in private repositories.'
            $global:LASTEXITCODE = 1
            return
        }
        throw "Unexpected mock gh invocation: $joined"
    }
    $resultPath = Join-Path $testRoot 'plan.json'
    $plan = & $planner -Repository @('owner/private', 'owner/public') -OutputFormat Json -ResultPath $resultPath | ConvertFrom-Json
    Assert-True ($plan.repositories.Count -eq 2) 'The planner should return one row for each dynamically supplied repository.'
    Assert-True ($plan.configurationRequired -eq 1) 'The planner should identify the incomplete public rule configuration.'
    Assert-True ($plan.verifiedMergeExceptions -eq 1) 'The planner should identify the reviewed private-plan exception.'
    $public = @($plan.repositories | Where-Object repository -eq 'owner/public')[0]
    $private = @($plan.repositories | Where-Object repository -eq 'owner/private')[0]
    Assert-True ($public.action -eq 'ConfigureGitHubRules') 'The public repository should require native rule configuration.'
    Assert-True (@($public.missingChecks) -contains 'Licence Decision') 'The public plan should name the missing expected check.'
    Assert-True ($private.action -eq 'UseVerifiedMergeException') 'The private repository should use the reviewed exception only for the known plan limitation.'
    Assert-True ($private.exceptionId -eq 'RQG-PRIVATE-PLAN-001') 'The private plan should include the approved exception identifier.'
    Assert-True (Test-Path -LiteralPath $resultPath -PathType Leaf) 'The planner should persist its reviewable JSON result.'
    $invalidPolicyPath = Join-Path $testRoot 'invalid-policy.json'
    $invalidPolicy = Get-Content -LiteralPath (Join-Path $root 'policy\required-check-enforcement.json') -Raw | ConvertFrom-Json
    $invalidPolicy.private.requiredControls = @($invalidPolicy.private.requiredControls | Select-Object -Skip 1)
    $invalidPolicy | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $invalidPolicyPath -Encoding utf8NoBOM
    $invalidPolicyFailure = $null
    try { $null = & $planner -Repository 'owner/public' -RequiredCheckPolicyPath $invalidPolicyPath }
    catch { $invalidPolicyFailure = $_ }
    Assert-True ($null -ne $invalidPolicyFailure) 'The planner should reject an exception policy that omits an approved control.'
    $source = Get-Content -LiteralPath $planner -Raw
    Assert-True (-not $source.Contains('owner/public')) 'The production planner should not contain a hard-coded repository inventory.'
    Assert-True ($source.Contains('Sort-Object -Unique')) 'The planner should operate on a dynamic deduplicated repository input.'
    Write-Output "$passed assertions passed."
}
finally {
    Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
