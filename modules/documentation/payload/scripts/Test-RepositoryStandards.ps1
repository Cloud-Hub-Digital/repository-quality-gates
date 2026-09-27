# SPDX-License-Identifier: MIT
[CmdletBinding()]
param(
    [string]$Repository = '.',
    [ValidateSet('Text', 'Json')][string]$OutputFormat = 'Text'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RelativePath([string]$Base, [string]$Path) {
    $baseFull = [IO.Path]::GetFullPath($Base).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $pathFull = [IO.Path]::GetFullPath($Path)
    return ([Uri]::UnescapeDataString(([Uri]$baseFull).MakeRelativeUri([Uri]$pathFull).ToString()) -replace '\\', '/').TrimStart('/')
}

function Get-TrackedPaths([string]$Root) {
    $paths = @(& git -C $Root ls-files --cached --others --exclude-standard 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Unable to enumerate repository files: $($paths -join [Environment]::NewLine)" }
    return @($paths | ForEach-Object { ([string]$_ -replace '\\', '/').TrimStart('/') })
}

function Get-FirstLine([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return [string](Get-Content -LiteralPath $Path -TotalCount 1)
}

function Test-ProvenanceMarker([string]$FirstLine, [string]$Scope, [string]$Owner, [string]$Path) {
    if (-not $FirstLine) { return $false }
    $prefix = if ($Path.EndsWith('.yml', [StringComparison]::OrdinalIgnoreCase) -or $Path.EndsWith('.yaml', [StringComparison]::OrdinalIgnoreCase)) { '# repository-standard:' } else { '<!-- repository-standard:' }
    if (-not $FirstLine.StartsWith($prefix, [StringComparison]::Ordinal)) { return $false }
    $required = @('schema=1', 'standard=Repository Standards', "owner=$Owner", "scope=$Scope", 'override=local-file')
    foreach ($value in $required) { if (-not $FirstLine.Contains($value, [StringComparison]::Ordinal)) { return $false } }
    if ($Scope -eq 'account-default') {
        if (-not $FirstLine.Contains('source=https://github.com/', [StringComparison]::Ordinal)) { return $false }
    } else {
        if (-not $FirstLine.Contains('source=local', [StringComparison]::Ordinal)) { return $false }
        if (-not $FirstLine.Contains('overrides=https://github.com/', [StringComparison]::Ordinal)) { return $false }
    }
    return $true
}

$root = [IO.Path]::GetFullPath($Repository)
$gitRoot = @(& git -C $root rev-parse --show-toplevel 2>&1)
if ($LASTEXITCODE -ne 0) { throw 'The target is not a Git repository.' }
$root = [IO.Path]::GetFullPath(([string]$gitRoot[0]).Trim())
$configPath = Join-Path $root '.repository-standards.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw 'The required .repository-standards.json file is missing.' }
try { $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json }
catch { throw 'The .repository-standards.json file is invalid JSON.' }

foreach ($property in @($config.PSObject.Properties.Name)) {
    if ($property -notin @('schemaVersion', 'profile', 'account', 'centralRepository', 'licence', 'supportRoute', 'conductRoute')) { throw "Unsupported repository-standards property: $property" }
}
if ($config.schemaVersion -ne 1) { throw 'The repository-standards schema is unsupported.' }
$profile = [string]$config.profile
if ($profile -notin @('account-default', 'downstream')) { throw 'The repository-standards profile must be account-default or downstream.' }
$account = [string]$config.account
if (-not $account -or $account -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$') { throw 'The repository-standards account is unresolved or invalid.' }
$centralRepository = [string]$config.centralRepository
if ($centralRepository -ne "https://github.com/$account/.github") { throw 'The centralRepository must identify the account public .github repository.' }
foreach ($name in @('licence', 'supportRoute', 'conductRoute')) {
    if (-not $config.PSObject.Properties[$name] -or -not ([string]$config.$name).Trim()) { throw "The repository-standards $name input is unresolved." }
}

$errors = [Collections.Generic.List[string]]::new()
$tracked = @(Get-TrackedPaths $root)
$lifecycleNames = @('AGENTS.md', 'PROJECT.md', 'GOALS.md', 'STATUS.md', 'DECISIONS.md', 'HANDOFFS.md')
foreach ($path in $tracked) {
    if ([IO.Path]::GetFileName($path) -in $lifecycleNames) { $errors.Add("Private lifecycle file is repository-visible: $path") }
}

$requiredLocal = @('README.md', 'CHANGELOG.md', '.gitignore', '.github/CODEOWNERS', '.github/dependabot.yml', '.repository-standards.json')
foreach ($path in $requiredLocal) { if (-not (Test-Path -LiteralPath (Join-Path $root $path) -PathType Leaf)) { $errors.Add("Required repository-local file is missing: $path") } }
$licenceFiles = @(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(LICENSE|LICENCE)(\..+)?$' })
if ($licenceFiles.Count -eq 0) { $errors.Add('A repository-local licence file is missing.') }

$ignorePath = Join-Path $root '.gitignore'
if (Test-Path -LiteralPath $ignorePath -PathType Leaf) {
    $ignoreLines = @(Get-Content -LiteralPath $ignorePath | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    foreach ($name in $lifecycleNames) { if ($name -notin $ignoreLines -and "/$name" -notin $ignoreLines) { $errors.Add(".gitignore does not explicitly protect $name") } }
}

$codeOwnersPath = Join-Path $root '.github/CODEOWNERS'
if (Test-Path -LiteralPath $codeOwnersPath -PathType Leaf) {
    $codeOwnersText = [IO.File]::ReadAllText($codeOwnersPath)
    if ($codeOwnersText -notmatch '(?m)^\*\s+@[A-Za-z0-9][A-Za-z0-9-]*(?:/[A-Za-z0-9][A-Za-z0-9_-]*)?\s*$') { $errors.Add('CODEOWNERS does not contain a valid default owner rule.') }
}

$dependabotPath = Join-Path $root '.github/dependabot.yml'
if (Test-Path -LiteralPath $dependabotPath -PathType Leaf) {
    $dependabotText = [IO.File]::ReadAllText($dependabotPath)
    if ($dependabotText -notmatch '(?m)^\s*-?\s*package-ecosystem:\s*["'']?github-actions["'']?\s*$') { $errors.Add('Dependabot must monitor the github-actions ecosystem.') }
}

$supported = @(
    'CONTRIBUTING.md',
    'CODE_OF_CONDUCT.md',
    'SUPPORT.md',
    'SECURITY.md',
    '.github/PULL_REQUEST_TEMPLATE.md',
    '.github/ISSUE_TEMPLATE/bug_report.yml',
    '.github/ISSUE_TEMPLATE/feature_request.yml',
    '.github/ISSUE_TEMPLATE/config.yml'
)
if ($profile -eq 'account-default') {
    foreach ($path in $supported) {
        $fullPath = Join-Path $root $path
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { $errors.Add("Central default is missing: $path"); continue }
        if (-not (Test-ProvenanceMarker (Get-FirstLine $fullPath) 'account-default' $account $path)) { $errors.Add("Central default has an invalid provenance marker: $path") }
    }
} else {
    $localIssueFiles = @($supported | Where-Object { $_.StartsWith('.github/ISSUE_TEMPLATE/', [StringComparison]::Ordinal) -and (Test-Path -LiteralPath (Join-Path $root $_) -PathType Leaf) })
    if ($localIssueFiles.Count -gt 0 -and $localIssueFiles.Count -ne 3) { $errors.Add('A local issue-template override must provide bug_report.yml, feature_request.yml, and config.yml together.') }
    foreach ($path in $supported) {
        $fullPath = Join-Path $root $path
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }
        $line = Get-FirstLine $fullPath
        if ($line -match 'scope=account-default') { $errors.Add("A downstream file falsely claims central provenance: $path"); continue }
        if (-not (Test-ProvenanceMarker $line 'local-override' $account $path)) { $errors.Add("Local override has an invalid provenance marker: $path") }
    }
}

$result = [ordered]@{
    status = if ($errors.Count -eq 0) { 'Passed' } else { 'Failed' }
    profile = $profile
    account = $account
    centralRepository = $centralRepository
    inherited = if ($profile -eq 'downstream') { @($supported | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_) -PathType Leaf) }) } else { @() }
    localOverrides = if ($profile -eq 'downstream') { @($supported | Where-Object { Test-Path -LiteralPath (Join-Path $root $_) -PathType Leaf }) } else { @() }
    errors = @($errors)
}
if ($OutputFormat -eq 'Json') { $result | ConvertTo-Json -Depth 5 }
else {
    Write-Host "Repository Standards: $($result.status)"
    Write-Host "Profile: $profile"
    foreach ($failure in $errors) { Write-Error $failure }
}
if ($errors.Count -gt 0) { exit 1 }
