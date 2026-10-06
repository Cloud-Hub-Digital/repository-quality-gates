# SPDX-License-Identifier: MIT
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'scripts\Invoke-RepositoryRulesetAppFleet.ps1'
$workflowPath = Join-Path $root '.github\workflows\reconcile-repository-rulesets.yml'
$source = Get-Content -LiteralPath $scriptPath -Raw
$workflow = Get-Content -LiteralPath $workflowPath -Raw
$passed = 0
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:passed++ }
Assert-True ($source.Contains('New-GitHubAppInstallationToken')) 'The fleet wrapper should use short-lived GitHub App installation tokens.'
Assert-True ($source.Contains('DELETE /installation/token')) 'The fleet wrapper should revoke installation tokens after use.'
Assert-True ($source.Contains('-Apply:$Apply')) 'The wrapper should keep audit & apply modes explicit.'
Assert-True ($workflow.Contains("cron: '17 5 * * *'")) 'The workflow should schedule a daily audit.'
Assert-True ($workflow.Contains('options: [audit, apply]')) 'The workflow should expose explicit audit & apply modes.'
Assert-True ($workflow.Contains('contents: read')) 'The workflow GITHUB_TOKEN should remain read-only.'
Assert-True (-not $workflow.Contains('pull-requests: write')) 'The workflow should not grant pull-request write access.'
Assert-True ($workflow.Contains('RQG_APP_PRIVATE_KEY: ${{ secrets.RQG_APP_PRIVATE_KEY }}')) 'The workflow should use the protected App key secret.'
Write-Output "$passed assertions passed."
