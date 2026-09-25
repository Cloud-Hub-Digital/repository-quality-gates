# SPDX-License-Identifier: MIT
[CmdletBinding()]
param(
    [string]$RepositoryPath,
    [switch]$Version,
    [string]$CatalogPath,
    [switch]$Apply,
    [switch]$Commit,
    [switch]$Push,
    [switch]$PruneManaged,
    [string[]]$IncludeModule = @(),
    [string[]]$PreserveExistingModule = @(),
    [string[]]$PreserveExistingPath = @(),
    [string[]]$AdoptExistingManagedFile = @(),
    [switch]$AllowDirtyWorkingTree,
    [switch]$AcknowledgeOverlap,
    [switch]$ConfigureLocalHooks,
    [string]$PrivateConfigPath,
    [ValidateSet('Stop', 'BackupAndReplace')][string]$ConflictAction = 'Stop',
    [string]$CommitMessage = 'chore: configure repository quality gates',
    [string]$Remote = 'origin',
    [ValidateSet('Text', 'Json')][string]$OutputFormat = 'Text'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$productVersion = '1.5.8'
$productRepository = 'https://github.com/Cloud-Hub-Digital/repository-quality-gates'
$toolRoot = Split-Path -Parent $PSScriptRoot
$detectionLibraryPath = Join-Path $toolRoot 'modules\module-drift\payload\scripts\RepositoryQualityGates.Detection.ps1'
if (-not (Test-Path -LiteralPath $detectionLibraryPath -PathType Leaf)) { throw 'The shared module-detection library is missing.' }
. $detectionLibraryPath

if ($Version) {
    $copyrightName = 'Terry' + ' Rogers'
    $copyrightUrl = 'https://www.terry' + 'rogers.me'
    Write-Output "Repository Quality Gates $productVersion"
    Write-Output $productRepository
    Write-Output "$copyrightName $([char]0x00A9) $((Get-Date).Year)"
    Write-Output $copyrightUrl
    Write-Output "$productRepository/releases/tag/v$productVersion"
    return
}

if (-not $RepositoryPath) { throw '-RepositoryPath is required unless -Version is used.' }
$helperCommand = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $helperCommand) { throw 'PowerShell 7 (pwsh) is required to deploy Repository Quality Gates.' }
$helperHost = $helperCommand.Source

if (-not $CatalogPath) { $CatalogPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\catalog.json' }

if ($Commit -and -not $Apply) { throw '-Commit requires -Apply.' }
if ($Push -and -not $Commit) { throw '-Push requires -Commit and -Apply.' }
if ($ConfigureLocalHooks -and -not $Apply) { throw '-ConfigureLocalHooks requires -Apply.' }
if ($ConfigureLocalHooks -and -not $PrivateConfigPath) { throw '-ConfigureLocalHooks requires -PrivateConfigPath.' }

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $output = & git -C $script:RepositoryRoot @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)" }
    return @($output)
}

function Test-GitIgnored([string]$RelativePath) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git -C $script:RepositoryRoot check-ignore --quiet --no-index -- $RelativePath 2>$null
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($exitCode -eq 0) { return $true }
    if ($exitCode -eq 1) { return $false }
    throw "Unable to evaluate Git ignore rules for $RelativePath."
}

function Get-FileHashValue([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $bytes = [IO.File]::ReadAllBytes($Path)
    try {
        $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
        $text = $strictUtf8.GetString($bytes)
        $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($normalized)
    }
    catch [Text.DecoderFallbackException] { }
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Get-RelativePath([string]$Base, [string]$Path) {
    $baseFull = [IO.Path]::GetFullPath($Base).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $pathFull = [IO.Path]::GetFullPath($Path)
    $baseUri = [Uri]$baseFull
    $pathUri = [Uri]$pathFull
    return ([Uri]::UnescapeDataString($baseUri.MakeRelativeUri($pathUri).ToString()) -replace '\\', '/').TrimStart('/')
}

function Resolve-FullChildPath([string]$Base, [string]$Relative) {
    $baseFull = [IO.Path]::GetFullPath($Base).TrimEnd('\', '/')
    $candidate = [IO.Path]::GetFullPath((Join-Path $baseFull ($Relative -replace '/', [IO.Path]::DirectorySeparatorChar)))
    if (-not $candidate.StartsWith($baseFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "A module path escapes its allowed root: $Relative"
    }
    $current = $baseFull
    $remainder = $candidate.Substring($baseFull.Length).TrimStart('\', '/')
    foreach ($segment in @($remainder -split '[\\/]')) {
        if (-not $segment) { continue }
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) { break }
        $attributes = (Get-Item -LiteralPath $current -Force).Attributes
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "A module path traverses a symbolic link, junction, or other reparse point: $Relative"
        }
    }
    return $candidate
}

function Read-ManagedState([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ schemaVersion = 1; modules = @(); files = @(); gitIgnoreLines = @() }
    }
    try { $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { throw 'The existing .repository-quality-gates.json file is invalid.' }
    if ($state.schemaVersion -ne 1) { throw 'The existing quality-gates state schema is unsupported.' }
    return $state
}

function Get-RuleStringArray($Object, [string]$Name, [string]$Context) {
    if (-not $Object -or -not $Object.PSObject.Properties[$Name]) { return @() }
    $value = $Object.$Name
    if ($null -eq $value) { return @() }
    if ($value -is [string] -or $value -isnot [Collections.IEnumerable]) {
        throw "$Context.$Name must be an array of strings."
    }
    $items = @($value | ForEach-Object {
        if ($_ -isnot [string] -or -not $_.Trim()) { throw "$Context.$Name must contain only non-empty strings." }
        $_.Trim()
    })
    if (@($items | Sort-Object -Unique).Count -ne $items.Count) { throw "$Context.$Name contains duplicate values." }
    return @($items)
}

function Read-RepositoryRules([string]$Path, $Catalog) {
    $empty = [pscustomobject]@{ includeModules = @(); repositoryOwnedModules = @(); repositoryOwnedPaths = @(); additionalSecretConfigs = @(); pullRequestReferences = @() }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $empty }
    try { $rules = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { throw 'The .repository-quality-gates.local.json file is invalid.' }
    foreach ($property in @($rules.PSObject.Properties.Name)) {
        if ($property -notin @('schemaVersion', 'automaticEnrollment', 'modules', 'paths', 'secretScanning', 'pullRequest')) { throw "Unsupported repository-rules property: $property" }
    }
    if ($rules.PSObject.Properties['automaticEnrollment'] -and $rules.automaticEnrollment -isnot [bool]) {
        throw 'The repository-rules automaticEnrollment property must be true or false.'
    }
    if ($rules.schemaVersion -ne 1) { throw 'The repository-rules schema is unsupported.' }
    $moduleRules = if ($rules.PSObject.Properties['modules']) { $rules.modules } else { $null }
    $pathRules = if ($rules.PSObject.Properties['paths']) { $rules.paths } else { $null }
    $secretRules = if ($rules.PSObject.Properties['secretScanning']) { $rules.secretScanning } else { $null }
    $pullRequestRules = if ($rules.PSObject.Properties['pullRequest']) { $rules.pullRequest } else { $null }
    if ($moduleRules) {
        foreach ($property in @($moduleRules.PSObject.Properties.Name)) {
            if ($property -notin @('include', 'repositoryOwned')) { throw "Unsupported repository-rules modules property: $property" }
        }
    }
    if ($pathRules) {
        foreach ($property in @($pathRules.PSObject.Properties.Name)) {
            if ($property -ne 'repositoryOwned') { throw "Unsupported repository-rules paths property: $property" }
        }
    }
    if ($secretRules) {
        foreach ($property in @($secretRules.PSObject.Properties.Name)) {
            if ($property -ne 'additionalConfigFiles') { throw "Unsupported repository-rules secretScanning property: $property" }
        }
    }
    if ($pullRequestRules) {
        foreach ($property in @($pullRequestRules.PSObject.Properties.Name)) {
            if ($property -ne 'references') { throw "Unsupported repository-rules pullRequest property: $property" }
        }
    }
    $include = @(Get-RuleStringArray $moduleRules 'include' 'modules')
    $repositoryOwned = @(Get-RuleStringArray $moduleRules 'repositoryOwned' 'modules')
    $repositoryOwnedPaths = @(Get-RuleStringArray $pathRules 'repositoryOwned' 'paths')
    $pullRequestReferences = @(Get-RuleStringArray $pullRequestRules 'references' 'pullRequest')
    foreach ($reference in $pullRequestReferences) {
        if ($reference -notmatch '^OP#[A-Z][A-Z0-9_]{1,31}-[1-9][0-9]*$') {
            throw "Unsupported pull-request reference: $reference"
        }
    }
    if (@($pullRequestReferences | ForEach-Object { ($_ -replace '^OP#', '') -replace '-[1-9][0-9]*$', '' } | Sort-Object -Unique).Count -gt 1) {
        throw 'All pull-request references must belong to the same OpenProject project.'
    }
    $additionalConfigs = @(Get-RuleStringArray $secretRules 'additionalConfigFiles' 'secretScanning')
    $catalogIds = @($Catalog.modules | ForEach-Object { [string]$_.id })
    foreach ($moduleId in @($include + $repositoryOwned | Sort-Object -Unique)) {
        if ($moduleId -notin $catalogIds) { throw "Repository rules reference an unknown module: $moduleId" }
    }
    $universalRepositoryOwned = @($repositoryOwned | Where-Object { $_ -in @('licensing', 'secret-scanning', 'module-drift') })
    if ($universalRepositoryOwned.Count) {
        throw "Universal modules cannot be repository-owned: $($universalRepositoryOwned -join ', ')"
    }
    $overlap = @($include | Where-Object { $_ -in $repositoryOwned })
    if ($overlap.Count) { throw "Repository rules cannot both include and mark a module repository-owned: $($overlap -join ', ')" }
    foreach ($relative in $repositoryOwnedPaths) {
        if ([IO.Path]::IsPathRooted($relative)) { throw "A repository-owned path must be relative: $relative" }
        $normalized = ($relative -replace '\\', '/').TrimStart('/')
        if ($normalized -in @('.git', '.repository-quality-gates.json', '.repository-quality-gates.local.json') -or $normalized.StartsWith('.git/', [StringComparison]::OrdinalIgnoreCase)) {
            throw "A protected Repository Quality Gates control path cannot be repository-owned: $relative"
        }
        $ownedPath = Resolve-FullChildPath $script:RepositoryRoot $normalized
        if (-not (Test-Path -LiteralPath $ownedPath -PathType Leaf)) { throw "A repository-owned path is missing: $relative" }
    }
    foreach ($relative in $additionalConfigs) {
        if ([IO.Path]::IsPathRooted($relative)) { throw "A repository secret configuration path must be relative: $relative" }
        $normalized = ($relative -replace '\\', '/').TrimStart('/')
        if (-not $normalized.EndsWith('.toml', [StringComparison]::OrdinalIgnoreCase)) { throw "A repository secret configuration must be a TOML file: $relative" }
        $configPath = Resolve-FullChildPath $script:RepositoryRoot $normalized
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw "A repository secret configuration is missing: $relative" }
    }
    return [pscustomobject]@{
        includeModules = @($include)
        repositoryOwnedModules = @($repositoryOwned)
        repositoryOwnedPaths = @($repositoryOwnedPaths)
        additionalSecretConfigs = @($additionalConfigs)
        pullRequestReferences = @($pullRequestReferences)
    }
}

function Add-Backup([string]$SourcePath, [string]$RelativePath) {
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { return }
    $destination = Resolve-FullChildPath $script:BackupRoot $RelativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $SourcePath -Destination $destination -Force
}

$inputPath = [IO.Path]::GetFullPath($RepositoryPath)
if (-not (Test-Path -LiteralPath $inputPath -PathType Container)) { throw 'The repository path does not exist.' }
$rootOutput = & git -C $inputPath rev-parse --show-toplevel 2>&1
if ($LASTEXITCODE -ne 0) { throw 'The target is not inside a Git repository.' }
$script:RepositoryRoot = [IO.Path]::GetFullPath(($rootOutput | Select-Object -First 1).Trim())
$templateRoot = [IO.Path]::GetFullPath($toolRoot)
$catalogFullPath = [IO.Path]::GetFullPath($CatalogPath)
if (-not (Test-Path -LiteralPath $catalogFullPath -PathType Leaf)) { throw 'The module catalog does not exist.' }
$catalog = Get-Content -LiteralPath $catalogFullPath -Raw | ConvertFrom-Json
if ($catalog.schemaVersion -ne 1) { throw 'The module catalog schema is unsupported.' }
$repositoryRulesPath = Join-Path $script:RepositoryRoot '.repository-quality-gates.local.json'
$repositoryRules = Read-RepositoryRules $repositoryRulesPath $catalog
$repositoryOwnedPaths = @(@($PreserveExistingPath) + @($repositoryRules.repositoryOwnedPaths) | ForEach-Object {
    if ([IO.Path]::IsPathRooted([string]$_)) { throw "A repository-owned path must be relative: $_" }
    $normalized = ([string]$_ -replace '\\', '/').TrimStart('/')
    if (-not $normalized) { throw 'A repository-owned path cannot be empty.' }
    if ($normalized -in @('.git', '.repository-quality-gates.json', '.repository-quality-gates.local.json') -or $normalized.StartsWith('.git/', [StringComparison]::OrdinalIgnoreCase)) {
        throw "A protected Repository Quality Gates control path cannot be repository-owned: $_"
    }
    $ownedPath = Resolve-FullChildPath $script:RepositoryRoot $normalized
    if (-not (Test-Path -LiteralPath $ownedPath -PathType Leaf)) { throw "A repository-owned path is missing: $_" }
    $normalized
} | Sort-Object -Unique)
$adoptedManagedFiles = @{}
foreach ($entry in @($AdoptExistingManagedFile)) {
    $parts = ([string]$entry).Split('=', 2)
    if ($parts.Count -ne 2) { throw "An adopted managed file must use relative/path=sha256 syntax: $entry" }
    $relative = ($parts[0] -replace '\\', '/').TrimStart('/')
    $hash = $parts[1].Trim().ToLowerInvariant()
    if (-not $relative -or [IO.Path]::IsPathRooted($relative) -or $hash -notmatch '^[0-9a-f]{64}$') { throw "An adopted managed file is invalid: $entry" }
    [void](Resolve-FullChildPath $script:RepositoryRoot $relative)
    if ($adoptedManagedFiles.ContainsKey($relative)) { throw "An adopted managed file path is duplicated: $relative" }
    $adoptedManagedFiles[$relative] = $hash
}

$statusBefore = @(& git -C $script:RepositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect the repository working tree.' }
if (($Apply -or $Commit -or $Push) -and @($statusBefore).Count -gt 0 -and -not $AllowDirtyWorkingTree) {
    throw 'The repository contains pre-existing changes. Commit, stash, or use -AllowDirtyWorkingTree for apply-only work.'
}
if (($Commit -or $Push) -and @($statusBefore).Count -gt 0) {
    throw 'Commit and push require a clean repository before deployment so unrelated work cannot be included.'
}

$statePath = Join-Path $script:RepositoryRoot '.repository-quality-gates.json'
$state = Read-ManagedState $statePath
$managedByPath = @{}
$managedDetectionPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($entry in @($state.files)) {
    $relative = ([string]$entry.path -replace '\\', '/').TrimStart('/')
    $managedByPath[$relative] = $entry
    [void]$managedDetectionPaths.Add($relative)
}
foreach ($relative in @($repositoryRules.additionalSecretConfigs)) {
    $normalized = ($relative -replace '\\', '/').TrimStart('/')
    if ($managedByPath.ContainsKey($normalized)) {
        throw "A repository-specific secret configuration cannot be an RQG-managed file: $relative"
    }
}
foreach ($relative in $repositoryOwnedPaths) {
    if ($managedByPath.ContainsKey($relative)) { $managedByPath.Remove($relative) }
}

# Previously deployed template payloads must not alter later module detection.
# For example, the secret-scanning module contains PowerShell helper scripts;
# those helpers should not make a repository acquire the PowerShell module on
# its second run when the original project contained no PowerShell source.
$repositoryFiles = @(Get-RqgRepositoryFiles -RepositoryRoot $script:RepositoryRoot -ExcludedRelativePaths @($managedDetectionPaths))
$detectedModules = @(Get-RqgDetectedModules -Catalog $catalog -Files $repositoryFiles)
$detectedIds = @($detectedModules | ForEach-Object { [string]$_.id })
$includedIds = @(@($IncludeModule) + @($repositoryRules.includeModules) | ForEach-Object { [string]$_ } | Where-Object { $_ } | Sort-Object -Unique)
$catalogIds = @($catalog.modules | ForEach-Object { [string]$_.id })
foreach ($includedId in $includedIds) {
    if ($includedId -notin $catalogIds) { throw "Cannot include unknown module '$includedId'." }
}
$applicableIds = @($detectedIds + $includedIds | Sort-Object -Unique)
$applicableModules = @($catalog.modules | Where-Object { [string]$_.id -in $applicableIds })
$preservedIds = @(@($PreserveExistingModule) + @($repositoryRules.repositoryOwnedModules) | ForEach-Object { [string]$_ } | Where-Object { $_ } | Sort-Object -Unique)
$universalPreservedIds = @($preservedIds | Where-Object { $_ -in @('licensing', 'secret-scanning', 'module-drift') })
if ($universalPreservedIds.Count) {
    throw "Universal modules cannot be preserved outside RQG management: $($universalPreservedIds -join ', ')"
}
foreach ($preservedId in $preservedIds) {
    if ($preservedId -notin $applicableIds) { throw "Cannot preserve module '$preservedId' because it is not applicable to this repository." }
}
$selectedModules = @($applicableModules | Where-Object { [string]$_.id -notin $preservedIds })
$selectedIds = @($selectedModules | ForEach-Object { [string]$_.id })
$desired = @{}
foreach ($module in $selectedModules) {
    $sourceRoot = Resolve-FullChildPath $templateRoot ([string]$module.source)
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { throw "Module source is missing: $($module.id)" }
    $excludedNames = if ($module.PSObject.Properties['exclude']) { @($module.exclude | ForEach-Object { [string]$_ }) } else { @() }
    foreach ($sourceFile in @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force -File)) {
        $relative = Get-RelativePath $sourceRoot $sourceFile.FullName
        if ($excludedNames -contains $relative) { continue }
        if ($desired.ContainsKey($relative)) { throw "Modules produce the same target path: $relative" }
        $desired[$relative] = [pscustomobject]@{ module = [string]$module.id; source = $sourceFile.FullName; hash = Get-FileHashValue $sourceFile.FullName }
    }
}
foreach ($relative in $repositoryOwnedPaths) {
    if ($desired.ContainsKey($relative)) { $desired.Remove($relative) }
}
if ($selectedIds -contains 'module-drift') {
    $catalogTarget = 'scripts/rqg-module-catalog.json'
    if ($desired.ContainsKey($catalogTarget)) { throw "Modules produce the same target path: $catalogTarget" }
    $desired[$catalogTarget] = [pscustomobject]@{ module = 'module-drift'; source = $catalogFullPath; hash = Get-FileHashValue $catalogFullPath }

    # Store a self-contained copy of the deployment engine and every module
    # payload in the managed repository. GitHub Actions can then reconcile
    # module additions and removals without access to this private source
    # repository or to a separate credential.
    $embeddedRoot = '.rqg/template'
    $embeddedFiles = @{
        "$embeddedRoot/scripts/Invoke-RepositoryQualityGates.ps1" = $PSCommandPath
        "$embeddedRoot/modules/catalog.json" = $catalogFullPath
    }
    foreach ($catalogModule in @($catalog.modules)) {
        $moduleSourceRelative = ([string]$catalogModule.source -replace '\\', '/').TrimStart('/')
        $moduleSourceRoot = Resolve-FullChildPath $templateRoot $moduleSourceRelative
        foreach ($sourceFile in @(Get-ChildItem -LiteralPath $moduleSourceRoot -Recurse -Force -File)) {
            $sourceRelative = Get-RelativePath $moduleSourceRoot $sourceFile.FullName
            $embeddedFiles["$embeddedRoot/$moduleSourceRelative/$sourceRelative"] = $sourceFile.FullName
        }
        if ($catalogModule.PSObject.Properties['gitignoreFragment']) {
            $fragmentRelative = ([string]$catalogModule.gitignoreFragment -replace '\\', '/').TrimStart('/')
            $embeddedFiles["$embeddedRoot/$fragmentRelative"] = Resolve-FullChildPath $templateRoot $fragmentRelative
        }
    }
    foreach ($embeddedTarget in @($embeddedFiles.Keys | Sort-Object)) {
        if ($desired.ContainsKey($embeddedTarget)) { throw "Modules produce the same target path: $embeddedTarget" }
        $embeddedSource = [string]$embeddedFiles[$embeddedTarget]
        $desired[$embeddedTarget] = [pscustomobject]@{ module = 'module-drift'; source = $embeddedSource; hash = Get-FileHashValue $embeddedSource }
    }
}

$managedUnignoreLines = [Collections.Generic.List[string]]::new()
foreach ($relative in @($desired.Keys | Sort-Object)) {
    if (Test-GitIgnored $relative) { $managedUnignoreLines.Add("!/$relative") }
}

$plan = [Collections.Generic.List[object]]::new()
foreach ($relative in @($desired.Keys | Sort-Object)) {
    $item = $desired[$relative]
    $target = Resolve-FullChildPath $script:RepositoryRoot $relative
    $existingHash = Get-FileHashValue $target
    if (-not $existingHash) {
        $action = 'Add'; $reason = 'Target file does not exist.'
    } elseif ($existingHash -eq $item.hash) {
        $action = 'Unchanged'; $reason = 'Target already matches the selected module.'
    } elseif (-not $managedByPath.ContainsKey($relative) -and $adoptedManagedFiles.ContainsKey($relative) -and [string]$adoptedManagedFiles[$relative] -eq $existingHash) {
        $action = 'Update'; $reason = 'The file matches a verified historical RQG payload and is adopted for this update.'
    } elseif (-not $managedByPath.ContainsKey($relative)) {
        $action = 'Conflict'; $reason = 'An unmanaged file already uses this path.'
    } elseif ([string]$managedByPath[$relative].sha256 -ne $existingHash) {
        $action = 'Conflict'; $reason = 'A previously managed file was modified locally.'
    } else {
        $action = 'Update'; $reason = 'The managed file is unchanged locally and a module update is available.'
    }
    $plan.Add([pscustomobject]@{ module = $item.module; path = $relative; action = $action; reason = $reason; sourceHash = $item.hash; existingHash = $existingHash })
}

foreach ($entry in @($state.files)) {
    $relative = [string]$entry.path
    if ($desired.ContainsKey($relative)) { continue }
    if ($relative -in $repositoryOwnedPaths) { continue }
    $target = Resolve-FullChildPath $script:RepositoryRoot $relative
    $existingHash = Get-FileHashValue $target
    if (-not $existingHash) { continue }
    if ($PruneManaged) {
        if ($existingHash -ne [string]$entry.sha256) {
            $plan.Add([pscustomobject]@{ module = [string]$entry.module; path = $relative; action = 'Conflict'; reason = 'An obsolete managed file was modified locally and cannot be pruned.'; sourceHash = $null; existingHash = $existingHash })
        } else {
            $plan.Add([pscustomobject]@{ module = [string]$entry.module; path = $relative; action = 'Remove'; reason = 'The file belongs to a previously selected module that is no longer detected.'; sourceHash = $null; existingHash = $existingHash })
        }
    } else {
        $plan.Add([pscustomobject]@{ module = [string]$entry.module; path = $relative; action = 'Retain'; reason = 'The module is no longer detected; use -PruneManaged after review to remove its unchanged files.'; sourceHash = $null; existingHash = $existingHash })
    }
}

$ignoreLines = [Collections.Generic.List[string]]::new()
foreach ($module in $selectedModules) {
    if (-not $module.PSObject.Properties['gitignoreFragment']) { continue }
    $fragmentPath = Resolve-FullChildPath $templateRoot ([string]$module.gitignoreFragment)
    foreach ($line in @(Get-Content -LiteralPath $fragmentPath | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') })) {
        if (-not $ignoreLines.Contains($line)) { $ignoreLines.Add($line) }
    }
}
foreach ($line in $managedUnignoreLines) {
    if (-not $ignoreLines.Contains($line)) { $ignoreLines.Add($line) }
}
$gitIgnorePath = Join-Path $script:RepositoryRoot '.gitignore'
$existingIgnore = if (Test-Path -LiteralPath $gitIgnorePath) { @(Get-Content -LiteralPath $gitIgnorePath) } else { @() }
$missingIgnore = @($ignoreLines | Where-Object { $existingIgnore -notcontains $_ })
if (@($missingIgnore).Count -gt 0) {
    $plan.Add([pscustomobject]@{ module = 'secret-scanning'; path = '.gitignore'; action = 'Merge'; reason = 'Required local tool exclusions are missing.'; sourceHash = $null; existingHash = Get-FileHashValue $gitIgnorePath })
}

$plannedWorkflowPaths = @($desired.Keys | Where-Object { $_ -like '.github/workflows/*' })
$overlaps = [Collections.Generic.List[object]]::new()
$workflowRoot = Join-Path $script:RepositoryRoot '.github\workflows'
if (Test-Path -LiteralPath $workflowRoot) {
    foreach ($workflow in @(Get-ChildItem -LiteralPath $workflowRoot -File | Where-Object { $_.Extension.ToLowerInvariant() -in @('.yml', '.yaml') })) {
        $relative = Get-RelativePath $script:RepositoryRoot $workflow.FullName
        if ($plannedWorkflowPaths -contains $relative) { continue }
        $content = Get-Content -LiteralPath $workflow.FullName -Raw
        foreach ($module in $applicableModules) {
            foreach ($pattern in @($module.overlapPatterns)) {
                if ($content -match [regex]::Escape([string]$pattern)) {
                    $overlaps.Add([pscustomobject]@{ module = [string]$module.id; path = $relative; pattern = [string]$pattern })
                    break
                }
            }
        }
    }
}

$conflicts = @($plan | Where-Object action -eq 'Conflict')
$preservationEvidence = @($overlaps | Where-Object { $_.module -in $preservedIds })
$unverifiedPreservedIds = @($preservedIds | Where-Object { $_ -notin @($preservationEvidence | ForEach-Object module) })
$blockingOverlaps = @($overlaps | Where-Object { $_.module -notin $preservedIds })
$result = [ordered]@{
    repository = $script:RepositoryRoot
    mode = if ($Apply) { if ($Push) { 'ApplyCommitPush' } elseif ($Commit) { 'ApplyCommit' } else { 'Apply' } } else { 'Preview' }
    selectedModules = $applicableIds
    managedModules = $selectedIds
    preservedModules = $preservedIds
    repositoryRulesFile = if (Test-Path -LiteralPath $repositoryRulesPath -PathType Leaf) { '.repository-quality-gates.local.json' } else { $null }
    repositoryOwnedPaths = @($repositoryOwnedPaths)
    additionalSecretConfigs = @($repositoryRules.additionalSecretConfigs)
    preservationEvidence = $preservationEvidence
    managedUnignoreLines = @($managedUnignoreLines)
    plan = @($plan)
    overlaps = @($overlaps)
    backupPath = $null
    commit = $null
    pushed = $false
}

if (-not $Apply) {
    if ($OutputFormat -eq 'Json') { $result | ConvertTo-Json -Depth 8 }
    else {
        Write-Host "Selected modules: $($applicableIds -join ', ')"
        if (@($preservedIds).Count) { Write-Host "Preserving existing modules: $($preservedIds -join ', ')" }
        $plan | Format-Table module, action, path, reason -AutoSize
        if (@($overlaps).Count) { Write-Warning "Potentially overlapping existing workflows were found. Review the JSON output for details." }
        Write-Host 'Preview only. Re-run with -Apply after reviewing the plan.'
    }
    return
}

if (@($conflicts).Count -gt 0 -and $ConflictAction -eq 'Stop') {
    throw "Deployment stopped because $(@($conflicts).Count) path conflict(s) require review. Use preview JSON for details or -ConflictAction BackupAndReplace after review."
}
if (@($unverifiedPreservedIds).Count -gt 0) {
    throw "Deployment stopped because preserved module(s) lack matching workflow evidence: $($unverifiedPreservedIds -join ', ')."
}
if (@($blockingOverlaps).Count -gt 0 -and -not $AcknowledgeOverlap) {
    throw "Deployment stopped because $(@($blockingOverlaps).Count) potentially overlapping workflow(s) require review. Re-run with -AcknowledgeOverlap only after deciding both checks should remain."
}

# Parse existing PowerShell source before making any changes. Read the text as
# Read managed text explicitly as UTF-8 for deterministic cross-platform handling.
# without a BOM (for example, strings containing an em dash).
$parseFailures = [Collections.Generic.List[string]]::new()
$powerShellExtensions = @('.ps1', '.psm1', '.psd1')
foreach ($file in @(Get-ChildItem -LiteralPath $script:RepositoryRoot -Recurse -Force -File | Where-Object {
    $_.FullName -notmatch '[\\/](\.git|node_modules|vendor|bin|obj)[\\/]' -and
    $powerShellExtensions -contains $_.Extension.ToLowerInvariant()
})) {
    $tokens = $null; $errors = $null
    try {
        $sourceText = [IO.File]::ReadAllText($file.FullName)
        [void][Management.Automation.Language.Parser]::ParseInput($sourceText, $file.FullName, [ref]$tokens, [ref]$errors)
        foreach ($parseError in @($errors)) { $parseFailures.Add("$($file.FullName): $($parseError.Message)") }
    }
    catch { $parseFailures.Add("$($file.FullName): Unable to read or parse the file: $($_.Exception.Message)") }
}
if (@($parseFailures).Count) { throw "PowerShell validation failed before deployment; no files were changed:`n$($parseFailures -join [Environment]::NewLine)" }

$gitDirectory = (Invoke-Git rev-parse --path-format=absolute --git-dir | Select-Object -First 1).Trim()
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:BackupRoot = Join-Path $gitDirectory "rqg-backups\$stamp"
$needsBackup = @($plan | Where-Object { $_.action -in @('Update', 'Remove', 'Conflict') })
if (@($needsBackup).Count -gt 0) { New-Item -ItemType Directory -Path $script:BackupRoot -Force | Out-Null; $result.backupPath = $script:BackupRoot }

foreach ($entry in @($plan)) {
    $target = Resolve-FullChildPath $script:RepositoryRoot $entry.path
    switch ($entry.action) {
        'Add' {
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Copy-Item -LiteralPath $desired[$entry.path].source -Destination $target
        }
        'Update' {
            Add-Backup $target $entry.path
            Copy-Item -LiteralPath $desired[$entry.path].source -Destination $target -Force
        }
        'Conflict' {
            Add-Backup $target $entry.path
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Copy-Item -LiteralPath $desired[$entry.path].source -Destination $target -Force
        }
        'Remove' {
            Add-Backup $target $entry.path
            Remove-Item -LiteralPath $target -Force
        }
        'Retain' { }
        'Merge' {
            if (Test-Path -LiteralPath $target) { Add-Backup $target $entry.path }
            $existingText = if (Test-Path -LiteralPath $target -PathType Leaf) { [IO.File]::ReadAllText($target) } else { '' }
            $newline = if ($existingText.Contains("`r`n")) { "`r`n" } elseif ($existingText.Contains("`n")) { "`n" } else { [Environment]::NewLine }
            $appendText = ''
            if ($existingText.Length -gt 0) {
                if (-not $existingText.EndsWith("`n")) { $appendText += $newline }
                if (@($existingIgnore).Count -gt 0 -and @($existingIgnore)[-1] -ne '') { $appendText += $newline }
            }
            $appendText += (@($missingIgnore) -join $newline) + $newline
            [IO.File]::AppendAllText($target, $appendText, [Text.UTF8Encoding]::new($false))
        }
    }
}

$stillIgnored = @($desired.Keys | Where-Object { Test-GitIgnored $_ })
if (@($stillIgnored).Count -gt 0) {
    throw "Required managed files remain ignored after the .gitignore merge: $($stillIgnored -join ', '). Review parent-directory ignore rules before retrying."
}

$stateFiles = @(
foreach ($relative in @($desired.Keys | Sort-Object)) {
    $target = Resolve-FullChildPath $script:RepositoryRoot $relative
    [ordered]@{ path = $relative; module = $desired[$relative].module; sha256 = Get-FileHashValue $target }
}
if (-not $PruneManaged) {
    foreach ($entry in @($state.files)) {
        $relative = [string]$entry.path
        if ($desired.ContainsKey($relative)) { continue }
        $target = Resolve-FullChildPath $script:RepositoryRoot $relative
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            [ordered]@{ path = $relative; module = [string]$entry.module; sha256 = [string]$entry.sha256 }
        }
    }
}
)
$installedManagedModules = @($stateFiles | ForEach-Object { [string]$_.module } | Sort-Object -Unique)
$newState = [ordered]@{
    schemaVersion = 1
    templateVersion = $productVersion
    modules = $installedManagedModules
    preservedModules = $preservedIds
    files = @($stateFiles)
    gitIgnoreLines = @($ignoreLines)
}
$stateJson = ($newState | ConvertTo-Json -Depth 6).Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
$stateAttributes = if (Test-Path -LiteralPath $statePath -PathType Leaf) { [IO.File]::GetAttributes($statePath) } else { $null }
try {
    if ($null -ne $stateAttributes -and ($stateAttributes -band [IO.FileAttributes]::Hidden)) {
        [IO.File]::SetAttributes($statePath, ($stateAttributes -band (-bnot [IO.FileAttributes]::Hidden)))
    }
    [IO.File]::WriteAllText($statePath, $stateJson, [Text.UTF8Encoding]::new($false))
} finally {
    if ($null -ne $stateAttributes -and (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        [IO.File]::SetAttributes($statePath, $stateAttributes)
    }
}

if ($ConfigureLocalHooks) {
    & $helperHost -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:RepositoryRoot 'scripts\Configure-SecretScanning.ps1') -PrivateConfigPath $PrivateConfigPath
    if ($LASTEXITCODE -ne 0) { throw 'Local secret-scanning configuration failed.' }
}

if ($Commit) {
    & $helperHost -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:RepositoryRoot 'scripts\Install-Gitleaks.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Verified Gitleaks installation failed.' }
    $stagePaths = @($plan | Where-Object action -ne 'Unchanged' | ForEach-Object path) + '.repository-quality-gates.json'
    foreach ($relative in @($stagePaths | Select-Object -Unique)) { & git -C $script:RepositoryRoot add -- $relative; if ($LASTEXITCODE -ne 0) { throw "Failed to stage $relative" } }
    & $helperHost -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:RepositoryRoot 'scripts\Test-Secrets.ps1') -Mode Staged -Repository $script:RepositoryRoot -PrivateConfigPath $PrivateConfigPath
    if ($LASTEXITCODE -ne 0) { throw 'The staged secret scan failed.' }
    $staged = @(Invoke-Git diff --cached --name-only --diff-filter=ACMRD)
    $allowed = @($stagePaths | ForEach-Object { $_ -replace '\\', '/' } | Select-Object -Unique)
    $unexpected = @($staged | Where-Object { $allowed -notcontains ($_ -replace '\\', '/') })
    if (@($unexpected).Count) { throw "Unexpected staged paths prevent commit: $($unexpected -join ', ')" }
    if (-not @($staged).Count) { throw 'There are no deployment changes to commit.' }
    Invoke-Git commit -m $CommitMessage | Out-Null
    $result.commit = (Invoke-Git rev-parse HEAD | Select-Object -First 1).Trim()
}

if ($Push) {
    $remoteNames = @(Invoke-Git remote)
    if ($remoteNames -notcontains $Remote) { throw "The requested Git remote does not exist: $Remote" }
    $branch = (Invoke-Git branch --show-current | Select-Object -First 1).Trim()
    if (-not $branch) { throw 'Push is not allowed from a detached HEAD.' }
    Invoke-Git fetch --prune $Remote | Out-Null
    $remoteRef = "refs/remotes/$Remote/$branch"
    $remoteCommit = (& git -C $script:RepositoryRoot rev-parse --verify $remoteRef 2>$null)
    if ($LASTEXITCODE -eq 0 -and $remoteCommit) {
        $behind = [int]((Invoke-Git rev-list --count "HEAD..$remoteRef" | Select-Object -First 1).Trim())
        if ($behind -gt 0) { throw "The local branch is behind $Remote/$branch. Integrate remote changes before pushing." }
        $remoteObject = $remoteCommit.Trim()
    } else { $remoteObject = '0000000000000000000000000000000000000000' }
    $localObject = (Invoke-Git rev-parse HEAD | Select-Object -First 1).Trim()
    $updates = Join-Path ([IO.Path]::GetTempPath()) ("rqg-push-" + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        "refs/heads/$branch $localObject refs/heads/$branch $remoteObject" | Set-Content -LiteralPath $updates -Encoding ascii
        & $helperHost -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:RepositoryRoot 'scripts\Test-Secrets.ps1') -Mode Push -Repository $script:RepositoryRoot -PushUpdatesPath $updates -PrivateConfigPath $PrivateConfigPath
        if ($LASTEXITCODE -ne 0) { throw 'The outgoing secret scan failed.' }
    } finally { Remove-Item -LiteralPath $updates -Force -ErrorAction SilentlyContinue }
    & git -C $script:RepositoryRoot push --set-upstream $Remote $branch
    if ($LASTEXITCODE -ne 0) { throw 'Git push failed.' }
    $result.pushed = $true
}

if ($OutputFormat -eq 'Json') { $result | ConvertTo-Json -Depth 8 }
else {
    Write-Host "Selected modules: $($detectedIds -join ', ')"
    if (@($preservedIds).Count) { Write-Host "Preserved existing modules: $($preservedIds -join ', ')" }
    $plan | Format-Table module, action, path -AutoSize
    if ($result.backupPath) { Write-Host "Recovery copy: $($result.backupPath)" }
    if ($result.commit) { Write-Host "Commit: $($result.commit)" }
    if ($result.pushed) { Write-Host "Pushed: $Remote" }
}
