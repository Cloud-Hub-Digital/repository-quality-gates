# SPDX-License-Identifier: MIT
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $root 'modules\release-governance\payload\scripts\Get-RepositoryReleasePlan.ps1'
$versionTool = Join-Path $root 'modules\release-governance\payload\scripts\Get-RepositoryReleaseVersion.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('rqg-release-' + [guid]::NewGuid().ToString('N'))
$sha = '1111111111111111111111111111111111111111'; $other = '2222222222222222222222222222222222222222'; $passed = 0
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:passed++ }
function Fixture([string]$Version = '2.0.0') {
    $path = Join-Path $temp ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $path | Out-Null
    $Version | Set-Content (Join-Path $path VERSION) -NoNewline
    "# Changelog`n`n## $Version - 2026-10-07`n`n### Changed`n`n- Enforced governed releases. (#12)`n" | Set-Content (Join-Path $path CHANGELOG.md) -NoNewline
    New-Item -ItemType Directory -Path (Join-Path $path '.github/workflows') | Out-Null
    'name: Governed Release' | Set-Content (Join-Path $path '.github/workflows/managed-automatic-release.yml')
    [ordered]@{ schemaVersion = 3; issueGovernance = [ordered]@{ recordRequired = $true; classifications = @('bug','feature','security','documentation','dependency','maintenance','compatibility','question','other'); confidentialSecurityRecord = 'github-security-advisory'; targetVersionMilestone = 'required-for-accepted-delivery'; openProjectCorrelation = 'private-one-way'; permittedOpenProjectShorthand = @('[<WORK_PACKAGE_DISPLAY_ID>]','OP#<WORK_PACKAGE_DISPLAY_ID>') }; releaseGovernance = [ordered]@{ changelogPath = 'CHANGELOG.md'; unreleasedHeading = 'Unreleased'; categories = @('Added','Changed','Deprecated','Removed','Fixed','Security'); issueReferenceRequired = $true; versionSources = @('VERSION'); workflowPath = '.github/workflows/managed-automatic-release.yml'; trigger = 'pushed-new-canonical-version'; tagFormat = 'v{version}'; releaseNameFormat = '{version}'; notesPolicy = 'comprehensive-since-previous-release'; issueClosurePolicy = 'verified-delivered-issues-only'; requiredGates = @('Tests') } } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $path .repository-standards.json)
    @([ordered]@{ name = 'Tests'; path = '.github/workflows/tests.yml'; status = 'completed'; conclusion = 'success' }) | ConvertTo-Json | Set-Content (Join-Path $path checks.json)
    @([ordered]@{ reference = '#12'; number = 12; type = 'issue'; classification = 'feature'; targetVersion = $Version; delivered = $true }) | ConvertTo-Json | Set-Content (Join-Path $path issues.json)
    'abc123 release change' | Set-Content (Join-Path $path commits.txt)
    [pscustomobject]@{ Path = $path; Version = $Version }
}
function Run($Fixture, [hashtable]$Extra = @{}) { $arguments = @{ RepositoryRoot = $Fixture.Path; CommitSha = $sha; RemoteMainSha = $sha; CheckRunsPath = (Join-Path $Fixture.Path checks.json); IssueRecordsPath = (Join-Path $Fixture.Path issues.json); PreviousVersion = '1.9.0'; CommitRangePath = (Join-Path $Fixture.Path commits.txt) }; foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }; try { $plan = & $tool @arguments 2>&1; [pscustomobject]@{ Ok = $true; Plan = $plan; Error = '' } } catch { [pscustomobject]@{ Ok = $false; Plan = $null; Error = $_.Exception.Message } } }
try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    $fixture = Fixture; $result = Run $fixture; Assert ($result.Ok -and $result.Plan.action -eq 'CreateTagAndRelease') ('New version should release. ' + $result.Error); Assert ($result.Plan.releaseName -eq '2.0.0') 'Release name must be exact version.'; Assert ($result.Plan.releaseNotes.Contains('#12')) 'Notes must cover issue.'
    $result = Run $fixture @{ PreviousVersion = '2.0.0' }; Assert ($result.Ok -and $result.Plan.action -eq 'NoRelease') 'Non-version push should not release.'
    $result = Run $fixture @{ RemoteMainSha = $other }; Assert ($result.Ok -and $result.Plan.action -eq 'Superseded') 'Stale commit should not release.'
    $result = Run $fixture @{ TagCommitSha = $other }; Assert (-not $result.Ok) 'Reused tag must fail.'
    $result = Run $fixture @{ TagCommitSha = $sha }; Assert ($result.Ok -and $result.Plan.action -eq 'CreateRelease') 'Correct tag can recover Release.'
    $pre = Fixture '2.0.0-rc.1'; $result = Run $pre; Assert ($result.Ok -and $result.Plan.prerelease -and $result.Plan.tag -eq 'v2.0.0-rc.1') 'Prerelease must be exact.'
    $advisory = Fixture; (Get-Content (Join-Path $advisory.Path CHANGELOG.md) -Raw).Replace('(#12)', '(GHSA-abcd-1234-efgh)') | Set-Content (Join-Path $advisory.Path CHANGELOG.md) -NoNewline; @([ordered]@{ reference = 'GHSA-ABCD-1234-EFGH'; number = $null; type = 'advisory'; classification = 'security'; targetVersion = '2.0.0'; delivered = $true }) | ConvertTo-Json | Set-Content (Join-Path $advisory.Path issues.json); $result = Run $advisory; Assert ($result.Ok -and $result.Plan.deliveredIssues[0].type -eq 'advisory') ('Confidential advisory authority should pass without issue closure. ' + $result.Error); Assert (-not $result.Plan.releaseNotes.Contains('GHSA-')) 'Release notes must not expose a confidential advisory identifier.'
    (Get-Content (Join-Path $fixture.Path CHANGELOG.md) -Raw).Replace(' (#12)', '') | Set-Content (Join-Path $fixture.Path CHANGELOG.md) -NoNewline; Assert (-not (Run $fixture).Ok) 'Missing issue must fail.'
    $fixture = Fixture; (Get-Content (Join-Path $fixture.Path CHANGELOG.md) -Raw).Replace('## 2.0.0 - 2026-10-07', '## Unreleased') | Set-Content (Join-Path $fixture.Path CHANGELOG.md) -NoNewline; Assert (-not (Run $fixture).Ok) 'Missing changelog section must fail.'
    $fixture = Fixture; $check = Get-Content (Join-Path $fixture.Path checks.json) -Raw | ConvertFrom-Json; $check.conclusion = 'failure'; $check | ConvertTo-Json | Set-Content (Join-Path $fixture.Path checks.json); Assert (-not (Run $fixture).Ok) 'Failed gate must fail.'
    $fixture = Fixture; $issue = Get-Content (Join-Path $fixture.Path issues.json) -Raw | ConvertFrom-Json; $issue.targetVersion = '1.9.0'; $issue | ConvertTo-Json | Set-Content (Join-Path $fixture.Path issues.json); Assert (-not (Run $fixture).Ok) 'Wrong milestone must fail.'
    $fixture = Fixture; $profile = Get-Content (Join-Path $fixture.Path .repository-standards.json) -Raw | ConvertFrom-Json; $profile.issueGovernance.classifications = @('feature'); $profile | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $fixture.Path .repository-standards.json); Assert (-not (Run $fixture).Ok) 'Incomplete schema-3 issue governance must fail.'
    $fixture = Fixture; $prohibitedLocator = 'https://example.invalid/' + 'work_' + 'packages/1'; "abc123 $prohibitedLocator" | Set-Content (Join-Path $fixture.Path commits.txt); Assert (-not (Run $fixture).Ok) 'OpenProject locators in release commit evidence must fail.'
    $fixture = Fixture; 'abc123 internal.cloudhub.digital' | Set-Content (Join-Path $fixture.Path commits.txt); Assert (-not (Run $fixture).Ok) 'Internal domains in release commit evidence must fail.'
    $fixture = Fixture; 'abc123 A:\private\record.md' | Set-Content (Join-Path $fixture.Path commits.txt); Assert (-not (Run $fixture).Ok) 'Absolute paths in release commit evidence must fail.'
    $fixture = Fixture; 'abc123 \\private-host\share\record.md' | Set-Content (Join-Path $fixture.Path commits.txt); Assert (-not (Run $fixture).Ok) 'UNC paths in release commit evidence must fail.'
    $outsideVersion = Join-Path $temp 'outside-version.txt'; '9.9.9' | Set-Content $outsideVersion -NoNewline
    $fixture = Fixture; $profile = Get-Content (Join-Path $fixture.Path .repository-standards.json) -Raw | ConvertFrom-Json; $profile.releaseGovernance.versionSources = @('..\outside-version.txt'); $profile | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $fixture.Path .repository-standards.json); $escaped = $false; try { & $versionTool -RepositoryRoot $fixture.Path | Out-Null } catch { $escaped = $true }; Assert $escaped 'Windows backslash traversal in a version source must fail.'
    $outsideDirectory = Join-Path $temp 'outside-version-directory'; New-Item -ItemType Directory -Path $outsideDirectory | Out-Null; '9.9.9' | Set-Content (Join-Path $outsideDirectory VERSION) -NoNewline
    $fixture = Fixture; $link = Join-Path $fixture.Path linked; New-Item -ItemType Junction -Path $link -Target $outsideDirectory | Out-Null; $profile = Get-Content (Join-Path $fixture.Path .repository-standards.json) -Raw | ConvertFrom-Json; $profile.releaseGovernance.versionSources = @('linked/VERSION'); $profile | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $fixture.Path .repository-standards.json); $linked = $false; try { & $versionTool -RepositoryRoot $fixture.Path | Out-Null } catch { $linked = $true }; Assert $linked 'A version source that traverses a junction must fail.'
    $fixture = Fixture; Assert (-not (Run $fixture @{ TagCommitSha = $sha; ReleaseExists = $true; ExistingReleaseTag = 'v2.0.0'; ExistingReleaseName = 'Product 2.0.0'; ExistingReleaseIsPrerelease = $false; ExistingReleaseNotes = 'wrong' }).Ok) 'Contradictory Release must fail.'
    Write-Host "$passed assertions passed."
} finally { if (Test-Path $temp) { Remove-Item $temp -Recurse -Force } }
