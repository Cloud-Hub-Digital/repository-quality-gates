# SPDX-License-Identifier: MIT
[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$CommitSha,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$RemoteMainSha,
    [Parameter(Mandatory)][string]$CheckRunsPath,
    [string]$TagCommitSha,
    [switch]$ReleaseExists
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requiredChecks = @(
    [pscustomobject]@{ name = 'Documentation Quality'; path = '.github/workflows/quality-documentation.yml' },
    [pscustomobject]@{ name = 'Fleet Update Quality'; path = '.github/workflows/quality-fleet-update.yml' },
    [pscustomobject]@{ name = 'Quality Gate Module Drift'; path = '.github/workflows/quality-module-drift.yml' },
    [pscustomobject]@{ name = 'Secret Scanning'; path = '.github/workflows/secret-scanning.yml' },
    [pscustomobject]@{ name = 'PowerShell Quality'; path = '.github/workflows/quality-powershell.yml' }
)

function New-ReleasePlan([string]$Action, [string]$Reason, [string]$Version, [string]$Tag) {
    [pscustomobject]@{
        action = $Action
        reason = $Reason
        version = $Version
        tag = $Tag
        commitSha = $CommitSha.ToLowerInvariant()
    }
}

$root = [IO.Path]::GetFullPath($RepositoryRoot)
$enginePath = Join-Path $root 'scripts\Invoke-RepositoryQualityGates.ps1'
$statePath = Join-Path $root '.repository-quality-gates.json'
$changelogPath = Join-Path $root 'CHANGELOG.md'
foreach ($path in @($enginePath, $statePath, $changelogPath, $CheckRunsPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required release input is missing: $path" }
}

$engineText = [IO.File]::ReadAllText($enginePath)
$versionMatch = [regex]::Match($engineText, '(?m)^\s*\$productVersion\s*=\s*''(?<version>[^'']+)''\s*$')
if (-not $versionMatch.Success) { throw 'Unable to resolve the canonical Repository Quality Gates version.' }
$version = $versionMatch.Groups['version'].Value
$tag = "v$version"

if ($version -notmatch '^\d+\.\d+\.\d+$') {
    New-ReleasePlan 'Skip' 'The canonical version is not a stable semantic version.' $version $tag
    exit 0
}

$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if ([string]$state.templateVersion -ne $version) {
    throw "The managed-state version '$($state.templateVersion)' does not match the canonical version '$version'."
}

$changelog = [IO.File]::ReadAllText($changelogPath)
if ($changelog -notmatch "(?m)^##\s+$([regex]::Escape($version))(?:\s|$)") {
    throw "CHANGELOG.md does not contain a heading for $version."
}

if ($CommitSha -ine $RemoteMainSha) {
    New-ReleasePlan 'Skip' 'The evaluated commit is no longer the current main commit.' $version $tag
    exit 0
}

$checkRuns = @(Get-Content -LiteralPath $CheckRunsPath -Raw | ConvertFrom-Json)
foreach ($required in $requiredChecks) {
    $matches = @($checkRuns | Where-Object { [string]$_.name -eq $required.name -and [string]$_.path -eq $required.path })
    if ($matches.Count -ne 1) { throw "Required workflow result is missing or ambiguous: $($required.path)" }
    $run = $matches[0]
    if ([string]$run.status -ne 'completed' -or [string]$run.conclusion -ne 'success') {
        throw "Required workflow did not complete successfully: $($required.path)"
    }
}

if ($TagCommitSha) {
    if ($TagCommitSha -notmatch '^[0-9a-fA-F]{40}$') { throw 'The existing tag commit is not a valid commit SHA.' }
    if ($TagCommitSha -ine $CommitSha) { throw "$tag already identifies a different commit. Increase the version before release." }
    if ($ReleaseExists) {
        New-ReleasePlan 'Current' 'The tag and immutable GitHub Release already identify this commit.' $version $tag
    }
    else {
        New-ReleasePlan 'CreateRelease' 'The correct tag exists and the missing GitHub Release can be recovered.' $version $tag
    }
    exit 0
}

if ($ReleaseExists) { throw "A GitHub Release exists for $tag but the corresponding tag could not be resolved." }
New-ReleasePlan 'CreateTagAndRelease' 'All required checks passed for the current main commit.' $version $tag
