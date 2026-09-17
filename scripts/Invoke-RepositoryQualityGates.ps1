[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryPath,
    [string]$CatalogPath,
    [switch]$Apply,
    [switch]$Commit,
    [switch]$Push,
    [switch]$PruneManaged,
    [string[]]$PreserveExistingModule = @(),
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
$helperHost = (Get-Command powershell.exe -ErrorAction Stop).Source

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
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
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
    return $candidate
}

function Get-RepositoryFiles {
    $excluded = '[\\/](\.git|node_modules|vendor|bin|obj|\.tools)[\\/]'
    $relativeFiles = Invoke-Git -c core.quotepath=false ls-files --cached --others --exclude-standard
    $files = foreach ($relative in $relativeFiles) {
        if (-not $relative) { continue }
        if ($relative.StartsWith('"')) { throw 'Unsupported quoted filename; review the repository filename before continuing.' }
        $fullPath = Resolve-FullChildPath $script:RepositoryRoot $relative
        if ((Test-Path -LiteralPath $fullPath -PathType Leaf) -and $fullPath -notmatch $excluded) {
            [IO.FileInfo]$fullPath
        }
    }
    return @($files)
}

function Test-ModuleDetection($Module, [array]$Files) {
    if ($Module.PSObject.Properties['always'] -and $Module.always -eq $true) { return $true }
    if (-not $Module.PSObject.Properties['detect']) { return $false }
    $detect = $Module.detect
    $fileNames = if ($detect.PSObject.Properties['fileNames']) { @($detect.fileNames | ForEach-Object { [string]$_ }) } else { @() }
    $extensions = if ($detect.PSObject.Properties['extensions']) { @($detect.extensions | ForEach-Object { ([string]$_).ToLowerInvariant() }) } else { @() }
    foreach ($file in $Files) {
        if ($fileNames -contains $file.Name) { return $true }
        if ($extensions -contains $file.Extension.ToLowerInvariant()) { return $true }
    }
    return $false
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
$templateRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$catalogFullPath = [IO.Path]::GetFullPath($CatalogPath)
if (-not (Test-Path -LiteralPath $catalogFullPath -PathType Leaf)) { throw 'The module catalog does not exist.' }
$catalog = Get-Content -LiteralPath $catalogFullPath -Raw | ConvertFrom-Json
if ($catalog.schemaVersion -ne 1) { throw 'The module catalog schema is unsupported.' }

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

# Previously deployed template payloads must not alter later module detection.
# For example, the secret-scanning module contains PowerShell helper scripts;
# those helpers should not make a repository acquire the PowerShell module on
# its second run when the original project contained no PowerShell source.
$repositoryFiles = @(Get-RepositoryFiles | Where-Object {
    $relative = Get-RelativePath $script:RepositoryRoot $_.FullName
    -not $managedDetectionPaths.Contains($relative)
})
$detectedModules = @($catalog.modules | Where-Object { Test-ModuleDetection $_ $repositoryFiles })
$detectedIds = @($detectedModules | ForEach-Object { [string]$_.id })
$preservedIds = @($PreserveExistingModule | ForEach-Object { [string]$_ } | Sort-Object -Unique)
foreach ($preservedId in $preservedIds) {
    if ($preservedId -notin $detectedIds) { throw "Cannot preserve module '$preservedId' because it is not applicable to this repository." }
}
$selectedModules = @($detectedModules | Where-Object { [string]$_.id -notin $preservedIds })
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
    } elseif (-not $managedByPath.ContainsKey($relative)) {
        $action = 'Conflict'; $reason = 'An unmanaged file already uses this path.'
    } elseif ([string]$managedByPath[$relative].sha256 -ne $existingHash) {
        $action = 'Conflict'; $reason = 'A previously managed file was modified locally.'
    } else {
        $action = 'Update'; $reason = 'The managed file is unchanged locally and a module update is available.'
    }
    $plan.Add([pscustomobject]@{ module = $item.module; path = $relative; action = $action; reason = $reason; sourceHash = $item.hash; existingHash = $existingHash })
}

if ($PruneManaged) {
    foreach ($entry in @($state.files)) {
        $relative = [string]$entry.path
        if ($desired.ContainsKey($relative)) { continue }
        $target = Resolve-FullChildPath $script:RepositoryRoot $relative
        $existingHash = Get-FileHashValue $target
        if (-not $existingHash) { continue }
        if ($existingHash -ne [string]$entry.sha256) {
            $plan.Add([pscustomobject]@{ module = [string]$entry.module; path = $relative; action = 'Conflict'; reason = 'An obsolete managed file was modified locally and cannot be pruned.'; sourceHash = $null; existingHash = $existingHash })
        } else {
            $plan.Add([pscustomobject]@{ module = [string]$entry.module; path = $relative; action = 'Remove'; reason = 'The file belongs to a previously selected module that is no longer detected.'; sourceHash = $null; existingHash = $existingHash })
        }
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
        foreach ($module in $detectedModules) {
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
    selectedModules = $detectedIds
    managedModules = $selectedIds
    preservedModules = $preservedIds
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
        Write-Host "Selected modules: $($detectedIds -join ', ')"
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
# UTF-8 explicitly so Windows PowerShell 5.1 does not misread UTF-8 files
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

$stateFiles = foreach ($relative in @($desired.Keys | Sort-Object)) {
    $target = Resolve-FullChildPath $script:RepositoryRoot $relative
    [ordered]@{ path = $relative; module = $desired[$relative].module; sha256 = Get-FileHashValue $target }
}
$newState = [ordered]@{
    schemaVersion = 1
    templateVersion = '0.1.0-dev'
    modules = $selectedIds
    preservedModules = $preservedIds
    files = @($stateFiles)
    gitIgnoreLines = @($ignoreLines)
}
$stateJson = ($newState | ConvertTo-Json -Depth 6).Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
[IO.File]::WriteAllText($statePath, $stateJson, [Text.UTF8Encoding]::new($false))

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
