# SPDX-License-Identifier: MIT
[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$CommitSha,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$RemoteMainSha,
    [Parameter(Mandatory)][string]$CheckRunsPath,
    [Parameter(Mandatory)][string]$IssueRecordsPath,
    [string]$PreviousVersion,
    [string]$CommitRangePath,
    [string]$TagCommitSha,
    [switch]$ReleaseExists,
    [string]$ExistingReleaseName,
    [string]$ExistingReleaseTag,
    [Nullable[bool]]$ExistingReleaseIsPrerelease,
    [string]$ExistingReleaseNotes
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Value($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) { return $Default }
    $Object.$Name
}
function Read-Json([string]$Path, [string]$Description) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Description is missing: $Path" }
    try { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { throw "$Description is invalid JSON: $Path" }
}
function Test-Version([string]$Value) {
    if ($Value -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$') { return $false }
    if ($Matches[4]) { foreach ($id in $Matches[4] -split '\.') { if ($id -match '^\d+$' -and $id.Length -gt 1 -and $id[0] -eq '0') { return $false } } }
    $true
}
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
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw "Version source missing: $Relative" }
    $candidate
}
function Assert-PublicReleaseText([string]$Text, [string]$Description) {
    if ($Text -match '(?i)https?://\S*(?:openproject|/wp/|/work_packages/)') { throw "$Description contains a prohibited OpenProject locator." }
    if ($Text -match '(?i)(?:^|[^A-Za-z0-9.-])(?:[A-Za-z0-9-]+\.)*(?:cloudhub\.digital|thetechwizard\.uk|mrhandy\.support|terryrogers\.me)(?=$|[^A-Za-z0-9.-])') { throw "$Description contains a prohibited internal domain or identifier." }
    if ($Text -match '(?<![A-Za-z0-9])[A-Za-z]:[\\/]' -or $Text -match '(?<!\\)\\\\[A-Za-z0-9._$-]+[\\/]') { throw "$Description contains a prohibited absolute or UNC path." }
    if ($Text -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]') { throw "$Description contains prohibited control characters." }
}
function Resolve-Version([string]$Root, $Source) {
    if ($Source -is [string]) { $relative = [string]$Source; $kind = 'plain-text' }
    else { $relative = [string](Get-Value $Source 'path' ''); $kind = [string](Get-Value $Source 'kind' '') }
    $path = Resolve-RepositoryFilePath $Root $relative
    $text = [IO.File]::ReadAllText($path).Trim([char]0xFEFF)
    switch ($kind) {
        'plain-text' { $version = $text.Trim() }
        'powershell-variable' {
            $pattern = '(?m)^\s*\$' + [regex]::Escape([string](Get-Value $Source 'variable' '')) + "\s*=\s*'(?<version>[^']+)'\s*$"
            $match = [regex]::Match($text, $pattern)
            if (-not $match.Success) { throw "Version variable unresolved: $relative" }
            $version = $match.Groups['version'].Value
        }
        'json-property' {
            $node = $text | ConvertFrom-Json
            foreach ($segment in ([string](Get-Value $Source 'property' '') -split '\.')) { if (-not $node.PSObject.Properties[$segment]) { throw "Version property unresolved: $relative" }; $node = $node.$segment }
            $version = [string]$node
        }
        default { throw "Unsupported version-source kind: $relative" }
    }
    if (-not (Test-Version $version)) { throw "Noncanonical semantic version '$version'." }
    $version
}
function New-Plan([string]$Action, [string]$Reason, [string]$Version = '', [string]$Notes = '', [object[]]$Issues = @()) {
    [pscustomobject]@{ action = $Action; reason = $Reason; version = $Version; tag = if ($Version) { "v$Version" } else { '' }; releaseName = $Version; prerelease = if ($Version) { $Version.Contains('-') } else { $false }; commitSha = $CommitSha.ToLowerInvariant(); releaseNotes = $Notes; deliveredIssues = @($Issues) }
}

$root = [IO.Path]::GetFullPath($RepositoryRoot)
$profile = Read-Json (Join-Path $root '.repository-standards.json') 'Repository profile'
if ([int](Get-Value $profile 'schemaVersion' 0) -lt 3 -or -not $profile.PSObject.Properties['releaseGovernance']) { New-Plan 'NotManaged' 'Schema-3 release governance is not configured.'; exit 0 }
$issueGovernance = Get-Value $profile 'issueGovernance' $null
$canonicalClassifications = @('bug', 'feature', 'security', 'documentation', 'dependency', 'maintenance', 'compatibility', 'question', 'other')
if ($null -eq $issueGovernance -or (Get-Value $issueGovernance 'recordRequired' $false) -ne $true -or [string](Get-Value $issueGovernance 'confidentialSecurityRecord' '') -ne 'github-security-advisory' -or [string](Get-Value $issueGovernance 'targetVersionMilestone' '') -ne 'required-for-accepted-delivery' -or [string](Get-Value $issueGovernance 'openProjectCorrelation' '') -ne 'private-one-way') { throw 'Issue governance is incomplete or unsupported.' }
if ((@((Get-Value $issueGovernance 'classifications' @())) -join '|') -cne ($canonicalClassifications -join '|')) { throw 'Issue governance classifications do not match the canonical taxonomy.' }
if ((@((Get-Value $issueGovernance 'permittedOpenProjectShorthand' @())) -join '|') -cne ('[<WORK_PACKAGE_DISPLAY_ID>]|OP#<WORK_PACKAGE_DISPLAY_ID>')) { throw 'Issue governance contains unsupported OpenProject shorthand.' }
$governance = $profile.releaseGovernance
if ([string](Get-Value $governance 'changelogPath' '') -ne 'CHANGELOG.md' -or [string](Get-Value $governance 'unreleasedHeading' '') -ne 'Unreleased' -or (Get-Value $governance 'issueReferenceRequired' $false) -ne $true -or [string](Get-Value $governance 'trigger' '') -ne 'pushed-new-canonical-version' -or [string](Get-Value $governance 'tagFormat' '') -ne 'v{version}' -or [string](Get-Value $governance 'releaseNameFormat' '') -ne '{version}' -or [string](Get-Value $governance 'notesPolicy' '') -ne 'comprehensive-since-previous-release' -or [string](Get-Value $governance 'issueClosurePolicy' '') -ne 'verified-delivered-issues-only') { throw 'Release governance is incomplete or unsupported.' }
if ((@((Get-Value $governance 'categories' @())) -join '|') -cne 'Added|Changed|Deprecated|Removed|Fixed|Security') { throw 'Release governance categories do not match the canonical changelog taxonomy.' }
$workflowPath = [string](Get-Value $governance 'workflowPath' '')
if ($workflowPath -notmatch '^\.github/workflows/.+\.ya?ml$' -or -not (Test-Path -LiteralPath (Join-Path $root $workflowPath) -PathType Leaf)) { throw 'The governed automatic-release workflow is missing or unsafe.' }
$sources = @(Get-Value $governance 'versionSources' @())
if (-not $sources.Count) { throw 'At least one canonical version source is required.' }
$versions = @($sources | ForEach-Object { Resolve-Version $root $_ })
if (@($versions | Select-Object -Unique).Count -ne 1) { throw 'Canonical version sources disagree.' }
$version = $versions[0]
if ($PreviousVersion) { if (-not (Test-Version $PreviousVersion)) { throw 'The previous version is invalid.' }; if ($PreviousVersion -eq $version) { New-Plan 'NoRelease' 'The push does not introduce a new canonical version.' $version; exit 0 } }
if ($CommitSha -ine $RemoteMainSha) { New-Plan 'Superseded' 'The evaluated commit is no longer current.' $version; exit 0 }

$changelogPath = Join-Path $root ([string](Get-Value $governance 'changelogPath' ''))
if (-not (Test-Path -LiteralPath $changelogPath -PathType Leaf)) { throw 'The governed changelog is missing.' }
$changelog = [IO.File]::ReadAllText($changelogPath)
$heading = [regex]::Match($changelog, "(?m)^##\s+$([regex]::Escape($version))\s+-\s+\d{4}-\d{2}-\d{2}\s*$")
if (-not $heading.Success) { throw "The changelog lacks a dated $version section." }
$start = $heading.Index + $heading.Length
$next = [regex]::Match($changelog.Substring($start), '(?m)^##\s+')
$section = if ($next.Success) { $changelog.Substring($start, $next.Index) } else { $changelog.Substring($start) }
$entries = @([regex]::Matches($section, '(?m)^\s*-\s+(?<text>\S.*)$') | ForEach-Object { $_.Groups['text'].Value.Trim() })
if (-not $entries.Count) { throw 'The release changelog section has no entries.' }
$references = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $entries) {
    $found = @([regex]::Matches($entry, '(?<![A-Za-z0-9])#(?<n>[1-9]\d*)\b') | ForEach-Object { "#$($_.Groups['n'].Value)" })
    $found += @([regex]::Matches($entry, '\bGHSA-[A-Za-z0-9]{4}-[A-Za-z0-9]{4}-[A-Za-z0-9]{4}\b') | ForEach-Object Value)
    if (-not $found.Count) { throw "Changelog entry lacks an issue or advisory: $entry" }
    foreach ($reference in $found) { $null = $references.Add($reference) }
    Assert-PublicReleaseText $entry 'Release content'
}
$records = @(Read-Json $IssueRecordsPath 'Issue evidence' | ForEach-Object { $_ })
$delivered = [Collections.Generic.List[object]]::new()
foreach ($reference in $references) {
    $match = @($records | Where-Object { [string]$_.reference -ieq $reference })
    if ($match.Count -ne 1) { throw "Issue evidence is missing or ambiguous: $reference" }
    $record = $match[0]
    if ([string](Get-Value $record 'classification' '') -notin $canonicalClassifications) { throw "Issue classification is unresolved: $reference" }
    if ([string](Get-Value $record 'targetVersion' '') -ne $version) { throw "Issue target version does not match: $reference" }
    if (-not [bool](Get-Value $record 'delivered' $false)) { throw "Issue is not verified as delivered: $reference" }
    $delivered.Add([pscustomobject]@{ reference = $reference; classification = [string]$record.classification; number = Get-Value $record 'number' $null; type = [string](Get-Value $record 'type' 'issue') })
}
$checks = @(Read-Json $CheckRunsPath 'Gate evidence' | ForEach-Object { $_ })
$required = @(Get-Value $governance 'requiredGates' @())
if (-not $required.Count) { throw 'Required release gates are missing.' }
foreach ($gate in $required) {
    if ($gate -is [string]) { $name = [string]$gate; $path = '' } else { $name = [string](Get-Value $gate 'name' ''); $path = [string](Get-Value $gate 'path' '') }
    $match = @($checks | Where-Object { [string]$_.name -ceq $name -and (-not $path -or [string]$_.path -ceq $path) })
    if ($match.Count -ne 1) { throw "Gate evidence is missing or ambiguous: $name" }
    if ([string]$match[0].status -ne 'completed' -or [string]$match[0].conclusion -ne 'success') { throw "Required gate failed: $name" }
}
$commits = @(if ($CommitRangePath) { if (-not (Test-Path -LiteralPath $CommitRangePath -PathType Leaf)) { throw 'Commit evidence is missing.' }; Get-Content -LiteralPath $CommitRangePath | Where-Object { $_ } })
foreach ($commit in $commits) { Assert-PublicReleaseText $commit 'Commit evidence' }
$advisoryPattern = '\bGHSA-[A-Za-z0-9]{4}-[A-Za-z0-9]{4}-[A-Za-z0-9]{4}\b'
$publicEntries = @($entries | ForEach-Object { [regex]::Replace($_, $advisoryPattern, '[confidential security advisory]', 'IgnoreCase') })
$publicCommits = @($commits | ForEach-Object { [regex]::Replace($_, $advisoryPattern, '[confidential security advisory]', 'IgnoreCase') })
$lines = @("# $version", '', '## Changes', '') + @($publicEntries | ForEach-Object { "- $_" })
if ($publicCommits.Count) { $lines += @('', '## Commits', '') + @($publicCommits | ForEach-Object { "- $_" }) }
$notes = ($lines -join [Environment]::NewLine).Trim() + [Environment]::NewLine
$prerelease = $version.Contains('-'); $tag = "v$version"
if ($TagCommitSha) {
    if ($TagCommitSha -notmatch '^[0-9a-fA-F]{40}$' -or $TagCommitSha -ine $CommitSha) { throw "$tag is reused by another commit." }
    if (-not $ReleaseExists) { New-Plan 'CreateRelease' 'The correct tag exists; recover the missing Release.' $version $notes $delivered; exit 0 }
    if ($ExistingReleaseTag -ne $tag -or $ExistingReleaseName -ne $version -or $ExistingReleaseIsPrerelease -ne $prerelease -or $ExistingReleaseNotes -cne $notes) { throw 'Existing Release evidence contradicts the governed release.' }
    New-Plan 'Current' 'The tag and Release exactly match.' $version $notes $delivered; exit 0
}
if ($ReleaseExists) { throw 'A Release exists without its immutable tag.' }
New-Plan 'CreateTagAndRelease' 'A new canonical version passed every gate.' $version $notes $delivered
