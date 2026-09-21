# SPDX-License-Identifier: MIT
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $root 'scripts\Get-RepositoryQualityGateReleasePlan.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('rqg-release-plan-tests-' + [guid]::NewGuid().ToString('N'))
$passed = 0
$sha = '1111111111111111111111111111111111111111'
$otherSha = '2222222222222222222222222222222222222222'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:passed++
}

function Write-Fixture([string]$Version = '1.3.0', [string]$StateVersion = $Version, [switch]$IncludeChangelog) {
    $fixture = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $fixture 'scripts') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixture 'scripts\Invoke-RepositoryQualityGates.ps1'), "`$productVersion = '$Version'`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $fixture '.repository-quality-gates.json'), (@{ templateVersion = $StateVersion } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    $change = if ($IncludeChangelog) { "# Changelog`n`n## $Version - 2026-09-21`n" } else { "# Changelog`n" }
    [IO.File]::WriteAllText((Join-Path $fixture 'CHANGELOG.md'), $change, [Text.UTF8Encoding]::new($false))
    return $fixture
}

function Write-Checks([string]$Directory, [string]$FailedName = '') {
    $workflows = @(
        @{ name = 'Documentation Quality'; path = '.github/workflows/quality-documentation.yml' },
        @{ name = 'Fleet Update Quality'; path = '.github/workflows/quality-fleet-update.yml' },
        @{ name = 'Quality Gate Module Drift'; path = '.github/workflows/quality-module-drift.yml' },
        @{ name = 'Secret Scanning'; path = '.github/workflows/secret-scanning.yml' },
        @{ name = 'PowerShell Quality'; path = '.github/workflows/quality-powershell.yml' }
    )
    $runs = @($workflows | ForEach-Object { [pscustomobject]@{ name = $_.name; path = $_.path; status = 'completed'; conclusion = if ($_.name -eq $FailedName) { 'failure' } else { 'success' } } })
    $path = Join-Path $Directory ("checks-$([guid]::NewGuid().ToString('N')).json")
    [IO.File]::WriteAllText($path, ($runs | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    return $path
}

function Invoke-Plan([string]$Fixture, [hashtable]$Extra = @{}) {
    $parameters = @{ RepositoryRoot = $Fixture; CommitSha = $sha; RemoteMainSha = $sha; CheckRunsPath = (Write-Checks $Fixture) }
    foreach ($key in $Extra.Keys) { $parameters[$key] = $Extra[$key] }
    try {
        $output = & $tool @parameters 2>&1
        [pscustomobject]@{ Succeeded = $true; Output = @($output); Plan = $output }
    }
    catch {
        [pscustomobject]@{ Succeeded = $false; Output = @($_); Plan = $null }
    }
}

try {
    $fixture = Write-Fixture -IncludeChangelog
    $result = Invoke-Plan $fixture
    Assert-True $result.Succeeded 'A valid stable release plan should succeed.'
    Assert-True ($result.Plan.action -eq 'CreateTagAndRelease' -and $result.Plan.tag -eq 'v1.3.0') 'A new stable version should create its tag and release.'

    $result = Invoke-Plan $fixture @{ TagCommitSha = $sha; ReleaseExists = $true }
    Assert-True ($result.Succeeded -and $result.Plan.action -eq 'Current') 'An existing matching tag and release should be current.'

    $result = Invoke-Plan $fixture @{ TagCommitSha = $sha }
    Assert-True ($result.Succeeded -and $result.Plan.action -eq 'CreateRelease') 'A matching tag without a release should be recoverable.'

    $result = Invoke-Plan $fixture @{ TagCommitSha = $otherSha }
    Assert-True (-not $result.Succeeded) 'A version tag that identifies another commit should fail closed.'

    $result = Invoke-Plan $fixture @{ RemoteMainSha = $otherSha }
    Assert-True ($result.Succeeded -and $result.Plan.action -eq 'Skip') 'A stale main commit should be skipped.'

    $failedChecks = Write-Checks $fixture 'Secret Scanning'
    $result = Invoke-Plan $fixture @{ CheckRunsPath = $failedChecks }
    Assert-True (-not $result.Succeeded) 'A failed required workflow should block release.'

    $wrongPathChecks = Write-Checks $fixture
    $wrongPathRuns = @(Get-Content -LiteralPath $wrongPathChecks -Raw | ConvertFrom-Json)
    $wrongPathRuns[0].path = '.github/workflows/lookalike.yml'
    [IO.File]::WriteAllText($wrongPathChecks, ($wrongPathRuns | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    $result = Invoke-Plan $fixture @{ CheckRunsPath = $wrongPathChecks }
    Assert-True (-not $result.Succeeded) 'A duplicate display name from another workflow path should not satisfy release readiness.'

    $mismatch = Write-Fixture -StateVersion '1.2.0' -IncludeChangelog
    $result = Invoke-Plan $mismatch
    Assert-True (-not $result.Succeeded) 'Inconsistent version metadata should block release.'

    $missingChange = Write-Fixture
    $result = Invoke-Plan $missingChange
    Assert-True (-not $result.Succeeded) 'A missing changelog entry should block release.'

    $prerelease = Write-Fixture -Version '1.3.0-dev.1' -IncludeChangelog
    $result = Invoke-Plan $prerelease
    Assert-True ($result.Succeeded -and $result.Plan.action -eq 'Skip') 'A prerelease version should be skipped.'

    Write-Host "$passed assertions passed."
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

exit 0
