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

function Test-LocalIssueTemplateMarker([string]$FirstLine, [string]$Owner, [string]$Path) {
    if (-not $FirstLine) { return $false }
    if (Test-ProvenanceMarker $FirstLine 'local-override' $Owner $Path) { return $true }
    foreach ($value in @('# repository-standard:', 'schema=1', 'standard=Repository Standards', 'version=1.2.0', 'source=Repository Quality Gates', 'scope=local-required', 'override=local-file')) {
        if (-not $FirstLine.Contains($value, [StringComparison]::Ordinal)) { return $false }
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

if ($config.schemaVersion -notin @(2, 3)) { throw 'The repository-standards schema must be version 2 or 3.' }
$allowedProperties = @('schemaVersion', 'profile', 'account', 'centralRepository', 'licence', 'supportRoute', 'conductRoute', 'featureExceptions')
if ($config.schemaVersion -eq 3) { $allowedProperties += @('issueGovernance', 'releaseGovernance') }
foreach ($property in @($config.PSObject.Properties.Name)) {
    if ($property -notin $allowedProperties) { throw "Unsupported repository-standards property: $property" }
}
if ($config.schemaVersion -eq 3) {
    # Reuse the canonical managed contract validator in its read-only NoRelease path.
    $versionTool = Join-Path $root 'scripts/Get-RepositoryReleaseVersion.ps1'
    $plannerTool = Join-Path $root 'scripts/Get-RepositoryReleasePlan.ps1'
    if (-not (Test-Path -LiteralPath $versionTool -PathType Leaf) -or -not (Test-Path -LiteralPath $plannerTool -PathType Leaf)) { throw 'Schema-3 release validators are missing.' }
    $version = & $versionTool -RepositoryRoot $root
    $placeholderSha = '0000000000000000000000000000000000000000'
    $plan = & $plannerTool -RepositoryRoot $root -CommitSha $placeholderSha -RemoteMainSha $placeholderSha -PreviousVersion $version -CheckRunsPath (Join-Path $root 'checks.json') -IssueRecordsPath (Join-Path $root 'issues.json')
    if ($plan.action -cne 'NoRelease') { throw 'The schema-3 release contract could not be validated without publication.' }
}
$profile = [string]$config.profile
if ($profile -notin @('account-default', 'downstream')) { throw 'The repository-standards profile must be account-default or downstream.' }
$account = [string]$config.account
if (-not $account -or $account -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$') { throw 'The repository-standards account is unresolved or invalid.' }
$centralRepository = [string]$config.centralRepository
if ($centralRepository -ne "https://github.com/$account/.github") { throw 'The centralRepository must identify the account public .github repository.' }
foreach ($name in @('supportRoute', 'conductRoute')) {
    if (-not $config.PSObject.Properties[$name] -or -not ([string]$config.$name).Trim()) { throw "The repository-standards $name input is unresolved." }
}
if ([string]$config.supportRoute -cne 'github-issues') { throw 'The repository support route must be github-issues.' }
$featureExceptions = if ($config.PSObject.Properties['featureExceptions']) { @($config.featureExceptions) } else { @() }
$seenFeatures = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($exception in $featureExceptions) {
    $allowed = @('id','feature','enabled','owner','reason','approvalStatus','reviewCondition')
    if (@($exception.PSObject.Properties.Name | Where-Object { $_ -notin $allowed }).Count) { throw 'A feature exception contains an unsupported property.' }
    if ([string]$exception.id -notmatch '^[A-Z0-9][A-Z0-9._-]+$') { throw 'A feature exception has an invalid identifier.' }
    if ([string]$exception.feature -notin @('discussions','wiki','pages')) { throw 'A feature exception names an unsupported feature.' }
    if (-not $seenFeatures.Add([string]$exception.feature)) { throw 'More than one exception exists for the same repository feature.' }
    if ($exception.enabled -isnot [bool]) { throw 'A feature exception must define a Boolean enabled state.' }
    foreach ($name in @('owner','reason','reviewCondition')) { if ([string]::IsNullOrWhiteSpace([string]$exception.$name)) { throw "A feature exception has an incomplete $name." } }
    if ([string]$exception.approvalStatus -cne 'approved') { throw 'A feature exception is not approved.' }
}
if (-not $config.PSObject.Properties['licence'] -or $null -eq $config.licence -or $config.licence -isnot [pscustomobject]) { throw 'The approved project licence decision is missing.' }
$allowedLicenceProperties = @('class', 'identifier', 'rightsHolder', 'decisionStatus', 'templateVersion', 'overrideReason')
foreach ($property in @($config.licence.PSObject.Properties.Name)) {
    if ($property -notin $allowedLicenceProperties) { throw "Unsupported licence decision property: $property" }
}
$licenceClass = if ($config.licence.PSObject.Properties['class']) { ([string]$config.licence.class).Trim() } else { '' }
$licenceIdentifier = if ($config.licence.PSObject.Properties['identifier']) { ([string]$config.licence.identifier).Trim() } else { '' }
$licenceRightsHolder = if ($config.licence.PSObject.Properties['rightsHolder']) { ([string]$config.licence.rightsHolder).Trim() } else { '' }
$licenceDecisionStatus = if ($config.licence.PSObject.Properties['decisionStatus']) { ([string]$config.licence.decisionStatus).Trim() } else { '' }
if ($licenceClass -notin @('open-source', 'proprietary')) { throw 'The approved licence class must be open-source or proprietary.' }
if (-not $licenceIdentifier) { throw 'The approved licence identifier is missing.' }
if (-not $licenceRightsHolder) { throw 'The approved licence rights holder is missing.' }
if ($licenceDecisionStatus -ne 'approved') { throw 'The project licence decision is unresolved or not approved.' }
if ($licenceClass -eq 'open-source') {
    if ($config.licence.PSObject.Properties['templateVersion'] -and $null -ne $config.licence.templateVersion) { throw 'An open-source licence decision must not define a proprietary template.' }
}
if ($licenceClass -eq 'proprietary') {
    if ($licenceIdentifier -notmatch '^LicenseRef-[A-Za-z0-9.-]+$') { throw 'A proprietary licence must use a valid LicenseRef identifier.' }
    if (-not $config.licence.PSObject.Properties['templateVersion'] -or -not ([string]$config.licence.templateVersion).Trim()) { throw 'A proprietary licence template version is missing.' }
}

$errors = [Collections.Generic.List[string]]::new()
$tracked = @(Get-TrackedPaths $root)
$lifecycleNames = @('PROJECT.md', 'GOALS.md', 'STATUS.md', 'DECISIONS.md', 'HANDOFFS.md')
foreach ($path in $tracked) {
    if ([IO.Path]::GetFileName($path) -in $lifecycleNames) { $errors.Add("Private lifecycle file is repository-visible: $path") }
}

$requiredLocal = @('AGENTS.md', 'README.md', 'CHANGELOG.md', '.gitignore', '.github/CODEOWNERS', '.github/dependabot.yml', '.repository-standards.json')
foreach ($path in $requiredLocal) { if (-not (Test-Path -LiteralPath (Join-Path $root $path) -PathType Leaf)) { $errors.Add("Required repository-local file is missing: $path") } }
$licenceFiles = @(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(LICENSE|LICENCE)(\..+)?$' })
if ($licenceFiles.Count -eq 0) { $errors.Add('A repository-local licence file is missing.') }

$agentsPath = Join-Path $root 'AGENTS.md'
if (Test-Path -LiteralPath $agentsPath -PathType Leaf) {
    $agentsText = [IO.File]::ReadAllText($agentsPath)
    $agentsFirstLine = Get-FirstLine $agentsPath
    $requiredAgentMarkerValues = @('schema=1', 'standard=Repository Standards', 'version=1.1.0', 'scope=local-required', 'source=local')
    if (-not $agentsFirstLine -or -not $agentsFirstLine.StartsWith('<!-- repository-standard:', [StringComparison]::Ordinal)) {
        $errors.Add('AGENTS.md does not start with the required repository-standard provenance marker.')
    } else {
        foreach ($value in $requiredAgentMarkerValues) {
            if (-not $agentsFirstLine.Contains($value, [StringComparison]::Ordinal)) { $errors.Add("AGENTS.md provenance marker is missing: $value") }
        }
    }
    if ([regex]::Matches($agentsText, '(?m)^## Code Review Rules\s*$').Count -ne 1) { $errors.Add('AGENTS.md must contain exactly one Code Review Rules section.') }
    $specificMatches = [regex]::Matches($agentsText, '(?m)^## Repository-Specific Review Rules\s*$')
    if ($specificMatches.Count -ne 1) {
        $errors.Add('AGENTS.md must contain exactly one Repository-Specific Review Rules section.')
    } else {
        $specificStart = $specificMatches[0].Index + $specificMatches[0].Length
        $nextHeading = [regex]::Match($agentsText.Substring($specificStart), '(?m)^##\s+')
        $specificBody = if ($nextHeading.Success) { $agentsText.Substring($specificStart, $nextHeading.Index) } else { $agentsText.Substring($specificStart) }
        if ($specificBody -notmatch '(?m)^-\s+\S') { $errors.Add('AGENTS.md must contain at least one repository-specific review rule.') }
    }
    if ($agentsText -match '\{\{[^}]+\}\}') { $errors.Add('AGENTS.md contains an unresolved template placeholder.') }
}

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
    '.github/ISSUE_TEMPLATE/question.yml',
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
    if ($localIssueFiles.Count -ne 4) { $errors.Add('Every repository must provide local bug_report.yml, feature_request.yml, question.yml, and config.yml issue forms.') }
    foreach ($path in $supported) {
        $fullPath = Join-Path $root $path
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }
        $line = Get-FirstLine $fullPath
        if ($line -match 'scope=account-default') { $errors.Add("A downstream file falsely claims central provenance: $path"); continue }
        if ($path.StartsWith('.github/ISSUE_TEMPLATE/', [StringComparison]::Ordinal)) {
            if (-not (Test-LocalIssueTemplateMarker $line $account $path)) { $errors.Add("Local issue template has an invalid provenance marker: $path") }
        } elseif (-not (Test-ProvenanceMarker $line 'local-override' $account $path)) { $errors.Add("Local override has an invalid provenance marker: $path") }
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
