[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryPath,
    [string]$TemplateRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$TargetVersion,
    [switch]$Apply,
    [ValidateSet('Text', 'Json')][string]$OutputFormat = 'Text'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-RqgVersion([string]$Value) {
    if ($Value -notmatch '^(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)(?:-(?<pre>[0-9A-Za-z.-]+))?$') {
        throw "Unsupported Repository Quality Gates version: $Value"
    }
    [pscustomobject]@{
        Core = [version]::new([int]$Matches.major, [int]$Matches.minor, [int]$Matches.patch)
        Prerelease = if ($Matches.ContainsKey('pre')) { [string]$Matches['pre'] } else { '' }
    }
}

function Compare-RqgVersion([string]$Left, [string]$Right) {
    $leftVersion = ConvertTo-RqgVersion $Left
    $rightVersion = ConvertTo-RqgVersion $Right
    $coreComparison = $leftVersion.Core.CompareTo($rightVersion.Core)
    if ($coreComparison -ne 0) { return $coreComparison }
    if (-not $leftVersion.Prerelease -and $rightVersion.Prerelease) { return 1 }
    if ($leftVersion.Prerelease -and -not $rightVersion.Prerelease) { return -1 }
    return [string]::Compare($leftVersion.Prerelease, $rightVersion.Prerelease, [StringComparison]::OrdinalIgnoreCase)
}

function Write-Result([Collections.IDictionary]$Result) {
    if ($OutputFormat -eq 'Json') { $Result | ConvertTo-Json -Depth 8 }
    else {
        Write-Host "Repository: $($Result.repository)"
        Write-Host "Status: $($Result.status)"
        if ($Result.currentVersion) { Write-Host "Current version: $($Result.currentVersion)" }
        if ($Result.targetVersion) { Write-Host "Target version: $($Result.targetVersion)" }
        if (@($Result.changedPaths).Count) { Write-Host "Changed paths: $(@($Result.changedPaths).Count)" }
    }
}

$inputPath = [IO.Path]::GetFullPath($RepositoryPath)
$rootOutput = @(& git -C $inputPath rev-parse --show-toplevel 2>&1)
if ($LASTEXITCODE -ne 0) { throw 'The target is not inside a Git repository.' }
$repositoryRoot = [IO.Path]::GetFullPath(($rootOutput | Select-Object -First 1).Trim())
$statePath = Join-Path $repositoryRoot '.repository-quality-gates.json'
$rulesPath = Join-Path $repositoryRoot '.repository-quality-gates.local.json'
$deploymentTool = Join-Path ([IO.Path]::GetFullPath($TemplateRoot)) 'scripts\Invoke-RepositoryQualityGates.ps1'
if (-not (Test-Path -LiteralPath $deploymentTool -PathType Leaf)) { throw 'The Repository Quality Gates deployment tool is missing.' }

if (-not $TargetVersion) {
    $versionOutput = @(& $deploymentTool -Version)
    if ($LASTEXITCODE -ne 0 -or -not @($versionOutput).Count) { throw 'Unable to determine the template version.' }
    $TargetVersion = ([string]$versionOutput[0] -replace '^Repository Quality Gates\s+', '').Trim()
}
[void](ConvertTo-RqgVersion $TargetVersion)

$result = [ordered]@{
    repository = $repositoryRoot
    status = 'Unmanaged'
    currentVersion = $null
    targetVersion = $TargetVersion
    selectedModules = @()
    changedPaths = @()
}

if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    Write-Result $result
    return
}

try { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
catch { throw 'The repository quality-gates state file is invalid.' }
if (-not $state.PSObject.Properties['templateVersion'] -or -not [string]$state.templateVersion) {
    throw 'The repository quality-gates state file does not identify its template version.'
}
$result.currentVersion = [string]$state.templateVersion
$comparison = Compare-RqgVersion $result.currentVersion $TargetVersion
if ($comparison -eq 0) {
    $result.status = 'Current'
    Write-Result $result
    return
}
if ($comparison -gt 0) {
    $result.status = 'Ahead'
    Write-Result $result
    return
}

$preservedModules = @()
$migrateRepositoryRules = $false
if (-not (Test-Path -LiteralPath $rulesPath -PathType Leaf) -and $state.PSObject.Properties['preservedModules']) {
    $preservedModules = @($state.preservedModules | ForEach-Object { [string]$_ } | Where-Object { $_ })
    $migrateRepositoryRules = $preservedModules.Count -gt 0
}
$arguments = @{
    RepositoryPath = $repositoryRoot
    PruneManaged = $true
    AcknowledgeOverlap = $true
    OutputFormat = 'Json'
}
if ($preservedModules.Count) { $arguments.PreserveExistingModule = $preservedModules }

$previewText = @(& $deploymentTool @arguments) -join [Environment]::NewLine
$preview = $previewText | ConvertFrom-Json
$result.selectedModules = @($preview.selectedModules)
$managedModules = @($preview.managedModules | ForEach-Object { [string]$_ })
$result.status = 'Available'
if (-not $Apply) {
    Write-Result $result
    return
}

$arguments.Apply = $true
$applyText = @(& $deploymentTool @arguments) -join [Environment]::NewLine
$null = $applyText | ConvertFrom-Json

if ($migrateRepositoryRules) {
    $rules = [ordered]@{
        schemaVersion = 1
        modules = [ordered]@{ include = @(); repositoryOwned = @($preservedModules) }
        secretScanning = [ordered]@{ additionalConfigFiles = @() }
    }
    $rulesJson = ($rules | ConvertTo-Json -Depth 6).Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
    [IO.File]::WriteAllText($rulesPath, $rulesJson, [Text.UTF8Encoding]::new($false))
}

$powerShellHost = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $powerShellHost) { $powerShellHost = Get-Command powershell.exe -ErrorAction Stop }
$validation = @(
    @{ Module = 'secret-scanning'; Path = 'scripts\Install-Gitleaks.ps1'; Arguments = @() },
    @{ Module = 'secret-scanning'; Path = 'scripts\Test-Secrets.ps1'; Arguments = @('-Mode', 'WorkingTree', '-Repository', $repositoryRoot) },
    @{ Module = 'secret-scanning'; Path = 'scripts\Test-DetectionPolicy.ps1'; Arguments = @() },
    @{ Module = 'module-drift'; Path = 'scripts\Test-QualityGateModuleDrift.ps1'; Arguments = @('-RepositoryPath', $repositoryRoot, '-OutputFormat', 'Text') }
)
foreach ($check in $validation) {
    if ($managedModules -notcontains $check.Module) { continue }
    $checkPath = Join-Path $repositoryRoot $check.Path
    if (-not (Test-Path -LiteralPath $checkPath -PathType Leaf)) { throw "Required validation script is missing: $($check.Path)" }
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = @(& $powerShellHost.Source -NoLogo -NoProfile -ExecutionPolicy Bypass -File $checkPath @($check.Arguments) 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    if ($exitCode -ne 0) { throw "Updated quality-gate validation failed: $($check.Path)" }
}

$result.changedPaths = @(& git -C $repositoryRoot status --short | ForEach-Object { ([string]$_).Substring(3) })
$result.status = 'Updated'
Write-Result $result
