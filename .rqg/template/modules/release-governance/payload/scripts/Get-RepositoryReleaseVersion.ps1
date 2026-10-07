# SPDX-License-Identifier: MIT
[CmdletBinding()]
param([string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version Latest

function Resolve-RepositoryFilePath([string]$Root, [string]$Relative) {
    if (-not $Relative -or [IO.Path]::IsPathRooted($Relative)) { throw 'A version-source path is missing or unsafe.' }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootFull ($Relative -replace '[\\/]', [IO.Path]::DirectorySeparatorChar)))
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $candidate.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, $comparison)) { throw 'A version-source path escapes the repository.' }
    $current = $rootFull
    foreach ($segment in @(($candidate.Substring($rootFull.Length).TrimStart('\', '/')) -split '[\\/]')) {
        if (-not $segment) { continue }
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) { break }
        if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'A version-source path traverses a symbolic link, junction, or other reparse point.' }
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw 'A version source is missing.' }
    $candidate
}

$profile = Get-Content -LiteralPath (Join-Path $RepositoryRoot '.repository-standards.json') -Raw | ConvertFrom-Json
if ($profile.schemaVersion -lt 3 -or -not $profile.releaseGovernance) { throw 'Schema-3 release governance is not configured.' }
$values = @()
foreach ($source in @($profile.releaseGovernance.versionSources)) {
    if ($source -is [string]) { $relative = [string]$source; $kind = 'plain-text' }
    else { $relative = [string]$source.path; $kind = [string]$source.kind }
    $path = Resolve-RepositoryFilePath $RepositoryRoot $relative
    $text = [IO.File]::ReadAllText($path).Trim([char]0xFEFF)
    switch ($kind) {
        'plain-text' { $values += $text.Trim() }
        'powershell-variable' { $pattern = '(?m)^\s*\$' + [regex]::Escape([string]$source.variable) + "\s*=\s*'(?<version>[^']+)'\s*$"; $match = [regex]::Match($text, $pattern); if (-not $match.Success) { throw 'Version variable unresolved.' }; $values += $match.Groups['version'].Value }
        'json-property' { $node = $text | ConvertFrom-Json; foreach ($segment in ([string]$source.property -split '\.')) { $node = $node.$segment }; $values += [string]$node }
        default { throw 'Unsupported version-source kind.' }
    }
}
if (-not $values.Count -or @($values | Select-Object -Unique).Count -ne 1) { throw 'Canonical versions are missing or inconsistent.' }
$values[0]
