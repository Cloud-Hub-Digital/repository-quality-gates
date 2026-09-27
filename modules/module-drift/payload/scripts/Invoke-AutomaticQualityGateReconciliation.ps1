# SPDX-License-Identifier: MIT
[CmdletBinding()]
param(
    [string]$RepositoryPath = (Get-Location).Path,
    [ValidateSet('Text', 'Json')][string]$OutputFormat = 'Text'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$inputPath = [IO.Path]::GetFullPath($RepositoryPath)
$rootOutput = @(& git -C $inputPath rev-parse --show-toplevel 2>&1)
if ($LASTEXITCODE -ne 0) { throw 'The target is not inside a Git repository.' }
$repositoryRoot = [IO.Path]::GetFullPath(($rootOutput | Select-Object -First 1).Trim())
$statePath = Join-Path $repositoryRoot '.repository-quality-gates.json'
$toolPath = Join-Path $repositoryRoot '.rqg\template\scripts\Invoke-RepositoryQualityGates.ps1'

if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw 'The repository quality-gates state file is missing.' }
if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) { throw 'The embedded Repository Quality Gates deployment tool is missing.' }

try { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
catch { throw 'The repository quality-gates state file is invalid.' }

$arguments = @{
    RepositoryPath = $repositoryRoot
    Apply = $true
    PruneManaged = $true
    AllowDirtyWorkingTree = $true
    AcknowledgeOverlap = $true
    OutputFormat = $OutputFormat
}
$rulesPath = Join-Path $repositoryRoot '.repository-quality-gates.local.json'
if (-not (Test-Path -LiteralPath $rulesPath -PathType Leaf) -and $state.PSObject.Properties['preservedModules']) {
    $preservedModules = @($state.preservedModules | ForEach-Object { [string]$_ } | Where-Object { $_ })
    if ($preservedModules.Count) { $arguments.PreserveExistingModule = $preservedModules }
}

& $toolPath @arguments

$driftChecker = Join-Path $repositoryRoot 'scripts\Test-QualityGateModuleDrift.ps1'
$powerShellHost = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $powerShellHost) { throw 'PowerShell 7 (pwsh) is required to reconcile Repository Quality Gates.' }
& $powerShellHost.Source -NoLogo -NoProfile -ExecutionPolicy Bypass -File $driftChecker -RepositoryPath $repositoryRoot -OutputFormat Text
if ($LASTEXITCODE -ne 0) { throw 'Repository quality-gate reconciliation did not produce a current module set.' }

exit 0
