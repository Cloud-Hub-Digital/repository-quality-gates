# SPDX-License-Identifier: MIT
[CmdletBinding()]
param(
    [string]$RepositoryPath = (Get-Location).Path,
    [string]$StatePath,
    [string]$CatalogPath,
    [switch]$ReportOnly,
    [ValidateSet('Text', 'Json')][string]$OutputFormat = 'Text'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'RepositoryQualityGates.Detection.ps1')

$inputPath = [IO.Path]::GetFullPath($RepositoryPath)
if (-not (Test-Path -LiteralPath $inputPath -PathType Container)) { throw 'The repository path does not exist.' }
$rootOutput = @(& git -C $inputPath rev-parse --show-toplevel 2>&1)
if ($LASTEXITCODE -ne 0) { throw 'The target is not inside a Git repository.' }
$repositoryRoot = [IO.Path]::GetFullPath(($rootOutput | Select-Object -First 1).Trim())

if (-not $StatePath) { $StatePath = Join-Path $repositoryRoot '.repository-quality-gates.json' }
if (-not $CatalogPath) { $CatalogPath = Join-Path $PSScriptRoot 'rqg-module-catalog.json' }
if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { throw 'The repository quality-gates state file is missing.' }
if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) { throw 'The deployed quality-gates module catalog is missing.' }

try { $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json }
catch { throw 'The repository quality-gates state file is invalid.' }
try { $catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json }
catch { throw 'The deployed quality-gates module catalog is invalid.' }
if ($state.schemaVersion -ne 1) { throw 'The repository quality-gates state schema is unsupported.' }
if ($catalog.schemaVersion -ne 1) { throw 'The deployed quality-gates module catalog schema is unsupported.' }

$managedPaths = @($state.files | ForEach-Object { ([string]$_.path -replace '\\', '/').TrimStart('/') })
$repositoryFiles = @(Get-RqgRepositoryFiles -RepositoryRoot $repositoryRoot -ExcludedRelativePaths $managedPaths)
$detectedModules = @(Get-RqgDetectedModules -Catalog $catalog -Files $repositoryFiles)
$detectedIds = @($detectedModules | ForEach-Object { [string]$_.id } | Sort-Object -Unique)
$rulesPath = Join-Path $repositoryRoot '.repository-quality-gates.local.json'
$includedIds = @()
$repositoryOwnedIds = @()
if (Test-Path -LiteralPath $rulesPath -PathType Leaf) {
    try { $rules = Get-Content -LiteralPath $rulesPath -Raw | ConvertFrom-Json }
    catch { throw 'The .repository-quality-gates.local.json file is invalid.' }
    if ($rules.schemaVersion -ne 1) { throw 'The repository-rules schema is unsupported.' }
    $moduleRules = if ($rules.PSObject.Properties['modules']) { $rules.modules } else { $null }
    if ($moduleRules -and $moduleRules.PSObject.Properties['include']) { $includedIds = @($moduleRules.include | ForEach-Object { [string]$_ } | Where-Object { $_ } | Sort-Object -Unique) }
    if ($moduleRules -and $moduleRules.PSObject.Properties['repositoryOwned']) { $repositoryOwnedIds = @($moduleRules.repositoryOwned | ForEach-Object { [string]$_ } | Where-Object { $_ } | Sort-Object -Unique) }
    $catalogIds = @($catalog.modules | ForEach-Object { [string]$_.id })
    foreach ($moduleId in @($includedIds + $repositoryOwnedIds | Sort-Object -Unique)) {
        if ($moduleId -notin $catalogIds) { throw "Repository rules reference an unknown module: $moduleId" }
    }
    $universalRepositoryOwned = @($repositoryOwnedIds | Where-Object { $_ -in @('licensing', 'secret-scanning', 'module-drift') })
    if ($universalRepositoryOwned.Count) { throw "Universal modules cannot be repository-owned: $($universalRepositoryOwned -join ', ')" }
} elseif ($state.PSObject.Properties['preservedModules']) {
    $repositoryOwnedIds = @($state.preservedModules | ForEach-Object { [string]$_ } | Where-Object { $_ } | Sort-Object -Unique)
}
$applicableIds = @($detectedIds + $includedIds | Sort-Object -Unique)
$installedIds = @(@($state.modules) + $repositoryOwnedIds | ForEach-Object { [string]$_ } | Sort-Object -Unique)
$missingIds = @($applicableIds | Where-Object { $_ -notin $installedIds })
$staleIds = @($installedIds | Where-Object { $_ -notin $applicableIds })

$result = [ordered]@{
    repository = $repositoryRoot
    status = if (@($missingIds).Count) { 'MissingModules' } elseif (@($staleIds).Count) { 'StaleModules' } else { 'Current' }
    detectedModules = $detectedIds
    includedModules = $includedIds
    repositoryOwnedModules = $repositoryOwnedIds
    installedModules = $installedIds
    missingModules = $missingIds
    staleModules = $staleIds
}

if ($OutputFormat -eq 'Json') {
    $result | ConvertTo-Json -Depth 4
} else {
    Write-Host "Detected modules: $($detectedIds -join ', ')"
    Write-Host "Installed modules: $($installedIds -join ', ')"
    foreach ($moduleId in $missingIds) {
        if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host "::error title=Missing Repository Quality Gate::$moduleId is required by the repository contents but is not installed." }
        else { Write-Error "$moduleId is required by the repository contents but is not installed." -ErrorAction Continue }
    }
    foreach ($moduleId in $staleIds) {
        if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host "::warning title=Stale Repository Quality Gate::$moduleId is installed but is no longer detected. Review it before pruning." }
        else { Write-Warning "$moduleId is installed but is no longer detected. Review it before pruning." }
    }
    if (-not @($missingIds).Count -and -not @($staleIds).Count) { Write-Host 'Repository quality-gate modules match the detected contents.' }
    elseif (@($missingIds).Count) { Write-Host 'Run the Repository Quality Gates deployment tool in preview mode, review the plan, and apply the required modules.' }
}

if (@($missingIds).Count -and -not $ReportOnly) { exit 2 }
exit 0
