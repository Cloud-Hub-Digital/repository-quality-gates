# SPDX-License-Identifier: MIT
Set-StrictMode -Version Latest

function Get-RqgRelativePath {
    param(
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][string]$Path
    )

    $baseFull = [IO.Path]::GetFullPath($Base).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $pathFull = [IO.Path]::GetFullPath($Path)
    $baseUri = [Uri]$baseFull
    $pathUri = [Uri]$pathFull
    return ([Uri]::UnescapeDataString($baseUri.MakeRelativeUri($pathUri).ToString()) -replace '\\', '/').TrimStart('/')
}

function Resolve-RqgChildPath {
    param(
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][string]$Relative
    )

    $baseFull = [IO.Path]::GetFullPath($Base).TrimEnd('\', '/')
    $candidate = [IO.Path]::GetFullPath((Join-Path $baseFull ($Relative -replace '/', [IO.Path]::DirectorySeparatorChar)))
    if (-not $candidate.StartsWith($baseFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "A repository path escapes its allowed root: $Relative"
    }
    $current = $baseFull
    $remainder = $candidate.Substring($baseFull.Length).TrimStart('\', '/')
    foreach ($segment in @($remainder -split '[\\/]')) {
        if (-not $segment) { continue }
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) { break }
        $attributes = (Get-Item -LiteralPath $current -Force).Attributes
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "A repository path traverses a symbolic link, junction, or other reparse point: $Relative"
        }
    }
    return $candidate
}

function Get-RqgRepositoryFiles {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string[]]$ExcludedRelativePaths = @()
    )

    $excludedDirectories = '[\\/](\.git|node_modules|vendor|bin|obj|\.tools)[\\/]'
    $excludedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($relative in @($ExcludedRelativePaths)) {
        if ($relative) { [void]$excludedPaths.Add(($relative -replace '\\', '/').TrimStart('/')) }
    }

    $relativeFiles = @(& git -C $RepositoryRoot -c core.quotepath=false ls-files --cached --others --exclude-standard 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Unable to enumerate repository files: $($relativeFiles -join [Environment]::NewLine)" }

    $files = foreach ($relative in $relativeFiles) {
        if (-not $relative) { continue }
        if ($relative.StartsWith('"')) { throw 'Unsupported quoted filename; review the repository filename before continuing.' }
        $normalized = ($relative -replace '\\', '/').TrimStart('/')
        if ($excludedPaths.Contains($normalized)) { continue }
        $fullPath = Resolve-RqgChildPath -Base $RepositoryRoot -Relative $normalized
        if ((Test-Path -LiteralPath $fullPath -PathType Leaf) -and $fullPath -notmatch $excludedDirectories) {
            [IO.FileInfo]$fullPath
        }
    }
    return @($files)
}

function Test-RqgModuleDetection {
    param(
        [Parameter(Mandatory)]$Module,
        [Parameter(Mandatory)][array]$Files
    )

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

function Get-RqgDetectedModules {
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][array]$Files
    )

    return @($Catalog.modules | Where-Object { Test-RqgModuleDetection -Module $_ -Files $Files })
}

function Repair-RqgManagedIndexCasing {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot)

    # Normalize only managed index entries. Product-owned paths and working files stay intact.
    $statePath = Join-Path $RepositoryRoot '.repository-quality-gates.json'
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $entries = @(& git -C $RepositoryRoot -c core.quotepath=false ls-files --stage)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect the staged managed paths.' }
    $index = @($entries | ForEach-Object {
        if ($_ -notmatch '^(?<mode>[0-9]{6}) (?<blob>[a-f0-9]{40,64}) (?<stage>[0-3])\t(?<path>.+)$') { throw 'Unsupported Git index entry.' }
        [pscustomobject]@{ Mode = $Matches.mode; Blob = $Matches.blob; Stage = $Matches.stage; Path = $Matches.path }
    })
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $repairs = @($state.files | ForEach-Object {
        $path = [string]$_.path
        if ($path -notmatch '^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$' -or @($path.Split('/') | Where-Object { $_ -in @('.', '..') }).Count) { throw 'Unsafe managed index path.' }
        if (-not $seen.Add($path)) { throw 'Ambiguous managed path aliases.' }
        $aliases = @($index | Where-Object { [string]::Equals($_.Path, $path, [StringComparison]::OrdinalIgnoreCase) })
        if ($aliases.Count -ne 1 -or $aliases[0].Stage -ne '0' -or $aliases[0].Mode -notin @('100644', '100755')) { throw "Missing, ambiguous, or unmerged managed index entry: $path" }
        if (-not [string]::Equals($aliases[0].Path, $path, [StringComparison]::Ordinal)) {
            [pscustomobject]@{ OldPath = $aliases[0].Path; Path = $path; Mode = $aliases[0].Mode; Blob = $aliases[0].Blob }
        }
    })
    foreach ($repair in $repairs) {
        & git -C $RepositoryRoot update-index --force-remove -- $repair.OldPath
        if ($LASTEXITCODE -ne 0) { throw 'Unable to remove a managed index casing alias.' }
        & git -C $RepositoryRoot update-index --add --cacheinfo "$($repair.Mode),$($repair.Blob),$($repair.Path)"
        if ($LASTEXITCODE -ne 0) { throw 'Unable to stage the canonical managed path.' }
        $repair.OldPath
        $repair.Path
    }
}
