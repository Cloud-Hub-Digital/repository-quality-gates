# SPDX-License-Identifier: MIT
[CmdletBinding()]
param(
    [string]$Repository = '.',
    [string]$GitHubSpdxId = $env:RQG_GITHUB_LICENSE_SPDX_ID,
    [ValidateSet('', 'Public', 'Private')][string]$RepositoryVisibility = $env:RQG_REPOSITORY_VISIBILITY,
    [ValidateSet('Text', 'Json')][string]$OutputFormat = 'Text'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Add-Failure([Collections.Generic.List[string]]$Failures, [string]$Message) {
    if (-not $Failures.Contains($Message)) { $Failures.Add($Message) }
}

function Get-NormalizedText([string]$Path) {
    return [IO.File]::ReadAllText($Path).Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd() + "`n"
}

function Get-Sha256([string]$Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

$root = [IO.Path]::GetFullPath($Repository)
$gitRoot = @(& git -C $root rev-parse --show-toplevel 2>&1)
if ($LASTEXITCODE -ne 0) { throw 'The target is not a Git repository.' }
$root = [IO.Path]::GetFullPath(([string]$gitRoot[0]).Trim())
$failures = [Collections.Generic.List[string]]::new()

$configPath = Join-Path $root '.repository-standards.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw 'The required .repository-standards.json file is missing.' }
try { $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json }
catch { throw 'The .repository-standards.json file is invalid JSON.' }

if ($config.schemaVersion -notin @(2, 3)) { Add-Failure $failures 'The repository-standards schema must be version 2 or 3.' }
if (-not $config.PSObject.Properties['licence'] -or $null -eq $config.licence -or $config.licence -isnot [pscustomobject]) {
    Add-Failure $failures 'The approved project licence decision is missing.'
    $licence = [pscustomobject]@{}
} else { $licence = $config.licence }

$allowedLicenceProperties = @('class', 'identifier', 'rightsHolder', 'decisionStatus', 'templateVersion', 'overrideReason')
foreach ($property in @($licence.PSObject.Properties.Name)) {
    if ($property -notin $allowedLicenceProperties) { Add-Failure $failures "Unsupported licence decision property: $property" }
}

$class = if ($licence.PSObject.Properties['class']) { ([string]$licence.class).Trim() } else { '' }
$identifier = if ($licence.PSObject.Properties['identifier']) { ([string]$licence.identifier).Trim() } else { '' }
$rightsHolder = if ($licence.PSObject.Properties['rightsHolder']) { ([string]$licence.rightsHolder).Trim() } else { '' }
$decisionStatus = if ($licence.PSObject.Properties['decisionStatus']) { ([string]$licence.decisionStatus).Trim() } else { '' }
$templateVersion = if ($licence.PSObject.Properties['templateVersion'] -and $null -ne $licence.templateVersion) { ([string]$licence.templateVersion).Trim() } else { '' }
$overrideReason = if ($licence.PSObject.Properties['overrideReason'] -and $null -ne $licence.overrideReason) { ([string]$licence.overrideReason).Trim() } else { '' }
$visibility = ([string]$RepositoryVisibility).Trim()

if ($class -notin @('open-source', 'proprietary')) { Add-Failure $failures 'The approved licence class must be open-source or proprietary.' }
if (-not $identifier) { Add-Failure $failures 'The approved licence identifier is missing.' }
if (-not $rightsHolder) { Add-Failure $failures 'The approved licence rights holder is missing.' }
if ($decisionStatus -ne 'approved') { Add-Failure $failures 'The project licence decision is unresolved or not approved.' }
if ($visibility -notin @('Public', 'Private')) {
    Add-Failure $failures 'The repository visibility is missing or unresolved.'
} else {
    $usesVisibilityDefault = if ($visibility -eq 'Public') {
        $class -eq 'open-source' -and $identifier -eq 'MIT' -and -not $templateVersion
    } else {
        $class -eq 'proprietary' -and $identifier -eq 'LicenseRef-TR-Proprietary-1.0' -and $templateVersion -eq '1.0'
    }
    if ($usesVisibilityDefault -and $overrideReason) {
        Add-Failure $failures 'The visibility-default licence must not declare a local override reason.'
    } elseif (-not $usesVisibilityDefault -and -not $overrideReason) {
        Add-Failure $failures "A $($visibility.ToLowerInvariant()) repository must use its visibility-default licence or record an approved local licence override reason."
    }
}

$licenceFiles = @(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(LICENSE|LICENCE)(\..+)?$' })
if ($licenceFiles.Count -eq 0) { Add-Failure $failures 'A repository-local licence file is missing.' }
if ($licenceFiles.Count -gt 1) { Add-Failure $failures 'Multiple repository-local licence files create an unresolved licence decision.' }
$licenceText = if ($licenceFiles.Count -eq 1) { Get-NormalizedText $licenceFiles[0].FullName } else { '' }

if ($licenceText -and $rightsHolder) {
    $escapedHolder = [regex]::Escape($rightsHolder)
    if ($licenceText -notmatch "(?im)^.*copyright.*$escapedHolder.*$") { Add-Failure $failures 'The repository licence does not identify the approved rights holder.' }
}

$markers = @([regex]::Matches($licenceText, '(?im)^\s*SPDX-License-Identifier:\s*([^\s]+)\s*$') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
if ($markers.Count -gt 1) { Add-Failure $failures 'The repository licence contains contradictory SPDX identifiers.' }
if ($markers.Count -eq 1 -and $identifier -and $markers[0] -cne $identifier) { Add-Failure $failures 'The repository licence SPDX identifier contradicts the approved project decision.' }

$detectedId = ([string]$GitHubSpdxId).Trim()
if (-not $detectedId) { Add-Failure $failures 'The GitHub licence presentation is missing or unresolved.' }

if ($class -eq 'open-source') {
    if ($templateVersion) { Add-Failure $failures 'An open-source licence decision must not define a proprietary template version.' }
    $acceptedDetectorIds = @($identifier)
    $spdxPath = Join-Path $root '.rqg/licensing/spdx-license-identifiers.json'
    if (-not (Test-Path -LiteralPath $spdxPath -PathType Leaf)) {
        Add-Failure $failures 'The managed SPDX identifier policy is missing.'
    } else {
        try { $spdx = Get-Content -LiteralPath $spdxPath -Raw | ConvertFrom-Json }
        catch { $spdx = $null; Add-Failure $failures 'The managed SPDX identifier policy is invalid JSON.' }
        if ($null -ne $spdx) {
            if ($spdx.schemaVersion -ne 1 -or -not ([string]$spdx.licenseListVersion).Trim()) { Add-Failure $failures 'The managed SPDX identifier policy is invalid.' }
            if ($identifier -and $identifier -notin @($spdx.licenseIds)) { Add-Failure $failures 'The approved open-source licence identifier is not an active SPDX identifier.' }
            if ($spdx.PSObject.Properties['githubDetectorAliases'] -and $spdx.githubDetectorAliases.PSObject.Properties[$identifier]) {
                $acceptedDetectorIds += @($spdx.githubDetectorAliases.$identifier)
            }
        }
    }
    if ($detectedId -and $identifier -and $detectedId -notin @($acceptedDetectorIds)) { Add-Failure $failures 'GitHub licence detection contradicts the approved open-source SPDX decision.' }
}

if ($class -eq 'proprietary') {
    if ($identifier -notmatch '^LicenseRef-[A-Za-z0-9.-]+$') { Add-Failure $failures 'A proprietary licence must use a valid LicenseRef identifier.' }
    if (-not $templateVersion) { Add-Failure $failures 'A proprietary licence template version is missing.' }
    if ($detectedId -and $detectedId.ToUpperInvariant() -notin @('NOASSERTION', 'OTHER')) { Add-Failure $failures 'GitHub licence detection contradicts the approved proprietary decision.' }
    if ($licenceText -and $licenceText -notmatch '(?is)third[- ]party.*subject to (?:their|the applicable) (?:respective )?licen[cs]es?') { Add-Failure $failures 'The proprietary licence does not preserve the third-party-material licence boundary.' }
    $usesStandardTemplate = $identifier -ceq 'LicenseRef-TR-Proprietary-1.0' -and $templateVersion -ceq '1.0' -and -not $overrideReason
    if ($usesStandardTemplate) {
        $expectedHash = 'd9b4b1506a5fb7b8018ddee20b88395cbc289b316248916670ec60268127f0a3'
        if ($licenceText -and (Get-Sha256 $licenceText) -cne $expectedHash) { Add-Failure $failures 'The proprietary licence does not exactly match TR Proprietary License 1.0.' }
    } else {
        if (-not $overrideReason) { Add-Failure $failures 'A proprietary licence that differs from the standard template requires an approved override reason.' }
        if ($markers.Count -ne 1 -or ($identifier -and $markers[0] -cne $identifier)) { Add-Failure $failures 'An approved proprietary override must contain its exact LicenseRef identifier.' }
    }
}

$result = [ordered]@{
    status = if ($failures.Count -eq 0) { 'Passed' } else { 'Failed' }
    visibility = $visibility
    class = $class
    identifier = $identifier
    rightsHolder = $rightsHolder
    decisionStatus = $decisionStatus
    githubSpdxId = $detectedId
    licenceFile = if ($licenceFiles.Count -eq 1) { $licenceFiles[0].Name } else { $null }
    localOverride = [bool]$overrideReason
    proprietaryOverride = [bool]($class -eq 'proprietary' -and $overrideReason)
    errors = @($failures)
}

if ($OutputFormat -eq 'Json') { $result | ConvertTo-Json -Depth 5 }
else {
    Write-Host "Repository Licence: $($result.status)"
    Write-Host "Class: $class"
    Write-Host "Identifier: $identifier"
    foreach ($failure in $failures) { Write-Error $failure }
}
if ($failures.Count -gt 0) { exit 1 }
