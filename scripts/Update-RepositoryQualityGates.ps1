# SPDX-License-Identifier: MIT
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryPath,
    [string]$TemplateRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$TargetVersion,
    [switch]$Enroll,
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

function Update-WorkflowRunnerRouting([string]$RepositoryRoot) {
    $workflowDirectory = Join-Path $RepositoryRoot '.github\workflows'
    if (-not (Test-Path -LiteralPath $workflowDirectory -PathType Container)) { return }

    $linuxExpression = '${{ fromJSON(((github.event_name == ''pull_request'' && github.event.pull_request.head.repo.full_name != github.repository) || !github.event.repository.private) && ''["ubuntu-latest"]'' || (vars.RQG_LINUX_RUNS_ON || ''["ubuntu-latest"]'')) }}'
    $windowsLatestExpression = '${{ fromJSON(((github.event_name == ''pull_request'' && github.event.pull_request.head.repo.full_name != github.repository) || !github.event.repository.private) && ''["windows-latest"]'' || (vars.RQG_WINDOWS_RUNS_ON || ''["windows-latest"]'')) }}'
    $windows2025Expression = '${{ fromJSON(((github.event_name == ''pull_request'' && github.event.pull_request.head.repo.full_name != github.repository) || !github.event.repository.private) && ''["windows-2025"]'' || (vars.RQG_WINDOWS_RUNS_ON || ''["windows-2025"]'')) }}'
    $selectorPattern = '(?m)^(?<indent>[ \t]*)runs-on:[ \t]*(?<quote>["'']?)(?<label>ubuntu-latest|windows-latest|windows-2025)\k<quote>(?<suffix>[ \t]*(?:#.*)?)$'

    foreach ($workflow in @(Get-ChildItem -LiteralPath $workflowDirectory -File | Where-Object { $_.Extension -in @('.yml', '.yaml') })) {
        $original = [IO.File]::ReadAllText($workflow.FullName)
        $updated = [regex]::Replace($original, $selectorPattern, {
            param($match)
            $expression = switch ([string]$match.Groups['label'].Value) {
                'ubuntu-latest' { $linuxExpression }
                'windows-latest' { $windowsLatestExpression }
                'windows-2025' { $windows2025Expression }
                default { throw "Unsupported hosted runner selector: $($match.Groups['label'].Value)" }
            }
            return $match.Groups['indent'].Value + 'runs-on: ' + $expression + $match.Groups['suffix'].Value
        })
        if ($updated -cne $original) {
            [IO.File]::WriteAllText($workflow.FullName, $updated, [Text.UTF8Encoding]::new($false))
        }
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

$isManaged = Test-Path -LiteralPath $statePath -PathType Leaf
if (-not $isManaged -and -not $Enroll) {
    Write-Result $result
    return
}

$state = $null
if ($isManaged) {
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
}

$preservedModules = @()
$preservedPaths = @()
$adoptedManagedFiles = @()
$migrateRepositoryRules = $false
if ($isManaged -and -not (Test-Path -LiteralPath $rulesPath -PathType Leaf) -and $state.PSObject.Properties['preservedModules']) {
    $legacyPreservedModules = @($state.preservedModules | ForEach-Object { [string]$_ } | Where-Object { $_ } | Sort-Object -Unique)
    $preservedModules = @($legacyPreservedModules | Where-Object { $_ -notin @('secret-scanning', 'module-drift') })

    if ($legacyPreservedModules -contains 'secret-scanning') {
        # Versions before path-level repository rules could preserve the entire
        # secret-scanning module when only the root .gitleaks.toml contained a
        # repository exception. Adopt only byte-for-byte historical RQG files;
        # keep a customized root policy repository-owned when it still extends
        # the centrally managed portable baseline.
        $legacySecretHashes = @{
            '.githooks/pre-commit' = @('92c9c24afeb1afe833384e8b2fe1f9fafac135193c97a0306a09983ec8e652a8')
            '.githooks/pre-push' = @('4a20602b0c9b890ca993997ccdba35c8b3a040916e46594ad59dc68047af37b2')
            '.github/workflows/secret-scanning.yml' = @('bde3015d33707e3f1a529441f2e2a123b85baec9956aa2a21a361df3a6911ca5')
            '.gitleaks.toml' = @('d82d36b06c3b6db6f6af4ba3c9f4c337ce1bcf494ba9c28797741a77fa402842', '89959bb386284925477919912cbd1cc7f2cbf17aa1dfaaeeeb8f1978916ac875')
            'scripts/Configure-SecretScanning.ps1' = @('274992c067e0ba3e9b8967a81d9dbc032700cbca5aba6e05d2641d3de14e77f9')
            'scripts/Install-GitHooks.ps1' = @('d31b4927808d40b1b66c69c9144ee7835d7658c22784aca9b4451b61c31f3a0a')
            'scripts/Install-Gitleaks.ps1' = @('b5a766f5f3b4722c3376d0fb1aa7c4d1772f863020cd4f52452e57431653b67e')
            'scripts/Test-DetectionPolicy.ps1' = @('1e62050f9580009c198ddb85e49a236c4d425ee29847034d9fd362c69f373555')
            'scripts/Test-Secrets.ps1' = @('86e23ae268a8a030a9e8f489f35bd3edc5d40cfca615436cba02bc1299ac2843', '03e215bda17bf0b40577b640574e7b37fd0340d009ec0eabfafd63bb4fa82b87')
        }
        foreach ($relative in @($legacySecretHashes.Keys | Sort-Object)) {
            $target = Join-Path $repositoryRoot ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { continue }
            $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($hash -in @($legacySecretHashes[$relative])) {
                $adoptedManagedFiles += "$relative=$hash"
                continue
            }
            if ($relative -eq '.gitleaks.toml') {
                $policyText = [IO.File]::ReadAllText($target)
                $extendSection = [regex]::Match($policyText, '(?ms)^\s*\[extend\]\s*(?<body>.*?)(?=^\s*\[|\z)')
                if (-not $extendSection.Success -or $extendSection.Groups['body'].Value -notmatch '(?m)^\s*path\s*=\s*["'']security/gitleaks-portable\.toml["'']\s*(?:#.*)?$') {
                    throw 'The legacy repository-owned .gitleaks.toml does not extend security/gitleaks-portable.toml and cannot be migrated automatically.'
                }
                $preservedPaths += $relative
            }
        }
    }
    $migrateRepositoryRules = $preservedModules.Count -gt 0 -or $preservedPaths.Count -gt 0
}
$arguments = @{
    RepositoryPath = $repositoryRoot
    PruneManaged = $true
    OutputFormat = 'Json'
}
if ($isManaged) { $arguments.AcknowledgeOverlap = $true }
if ($preservedModules.Count) { $arguments.PreserveExistingModule = $preservedModules }
if ($preservedPaths.Count) { $arguments.PreserveExistingPath = $preservedPaths }
if ($adoptedManagedFiles.Count) { $arguments.AdoptExistingManagedFile = $adoptedManagedFiles }

$previewText = @(& $deploymentTool @arguments) -join [Environment]::NewLine
$preview = $previewText | ConvertFrom-Json
$result.selectedModules = @($preview.selectedModules)
$managedModules = @($preview.managedModules | ForEach-Object { [string]$_ })
$result.status = if ($isManaged) { 'Available' } else { 'EnrollmentAvailable' }
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
        paths = [ordered]@{ repositoryOwned = @($preservedPaths) }
        secretScanning = [ordered]@{ additionalConfigFiles = @() }
    }
    $rulesJson = ($rules | ConvertTo-Json -Depth 6).Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
    [IO.File]::WriteAllText($rulesPath, $rulesJson, [Text.UTF8Encoding]::new($false))
}

# Repository-owned workflows remain outside RQG module management, but their
# runner selection must still follow the repository visibility policy. Exact
# GitHub-hosted selectors stay the public and fork-pull-request fallback while
# trusted private events use the repository's configured runner labels.
Update-WorkflowRunnerRouting -RepositoryRoot $repositoryRoot

$powerShellHost = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $powerShellHost) { throw 'PowerShell 7 (pwsh) is required to update Repository Quality Gates.' }
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
$result.status = if ($isManaged) { 'Updated' } else { 'Enrolled' }
Write-Result $result
