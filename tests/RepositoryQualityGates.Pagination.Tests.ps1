# SPDX-License-Identifier: MIT
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts/RepositoryQualityGates.Deactivation.ps1')
$passed = 0
$script:response = ''
$script:apiExit = 0
$script:lastArguments = @()
function Assert-Pagination([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:passed++
}
function global:gh {
    $script:lastArguments = @($args)
    if ('--slurp' -in $args -and '--jq' -in $args) { throw 'Unsupported GitHub CLI flag combination.' }
    $global:LASTEXITCODE = $script:apiExit
    $script:response
}
try {
    $script:response = '[{"check_runs":[{"name":"First Check"}]},{"check_runs":[]},{"check_runs":[{"name":"Last Check"}]}]'
    $checks = @(Get-RqgDeactivationPagedCollection 'repos/example/project/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/check-runs?per_page=100' 'check_runs')
    Assert-Pagination ($checks.Count -eq 2 -and $checks[0].name -eq 'First Check' -and $checks[1].name -eq 'Last Check') 'Every check page must be retained in order, including pages after an empty page.'
    Assert-Pagination ('--paginate' -in $script:lastArguments -and '--slurp' -in $script:lastArguments -and '--jq' -notin $script:lastArguments) 'The production API helper must use compatible paginated output flags.'
    $script:response = '[[{"context":"First Status","state":"success"}],[],[{"context":"Last Status","state":"success"}]]'
    $statuses = @(Get-RqgDeactivationPagedCollection 'repos/example/project/commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/statuses?per_page=100' '')
    Assert-Pagination ($statuses.Count -eq 2 -and $statuses[1].context -eq 'Last Status') 'Array-valued status pages must flatten without dropping later status evidence.'
    $script:response = '[{"check_runs":[]}]'
    Assert-Pagination (@(Get-RqgDeactivationPagedCollection 'repos/example/project/check-runs' 'check_runs').Count -eq 0) 'An empty check page must remain empty.'
    $script:response = '[{}]'
    $failure = $null
    try { Get-RqgDeactivationPagedCollection 'repos/example/project/check-runs' 'check_runs' | Out-Null } catch { $failure = $_ }
    Assert-Pagination ($null -ne $failure -and $failure.Exception.Message -match 'missing its collection') 'A malformed check page must fail closed.'
    $script:apiExit = 1
    $script:response = 'HTTP 403'
    $failure = $null
    try { Get-RqgDeactivationPagedCollection 'repos/example/project/check-runs' 'check_runs' | Out-Null } catch { $failure = $_ }
    Assert-Pagination ($null -ne $failure -and $failure.Exception.Message -match 'HTTP 403') 'A failed API request must not be treated as an empty successful collection.'
    foreach ($relative in @('.github/workflows/quality-module-drift.yml','modules/module-drift/payload/.github/workflows/quality-module-drift.yml','.rqg/template/modules/module-drift/payload/.github/workflows/quality-module-drift.yml')) {
        $workflow = Get-Content -LiteralPath (Join-Path $root $relative) -Raw
        $report = [regex]::Match($workflow, '(?ms)^  report:\r?\n(?<job>.*?)(?=^  reconcile:)')
        Assert-Pagination ($report.Success -and $report.Groups['job'].Value -notmatch '(?m)^    if:') 'Required reporting must run on pushes as well as pull requests.'
        Assert-Pagination ($report.Groups['job'].Value.Contains('github.event.pull_request.head.repo.full_name != github.repository')) 'Reporting must retain the fork boundary for private runners.'
    }
    Write-Output "$passed pagination and baseline-reporting assertions passed."
} finally {
    Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
}
