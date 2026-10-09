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
    $tokens = $null; $parseErrors = $null
    $plannerAst = [Management.Automation.Language.Parser]::ParseFile($tool, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw 'Release planner source could not be parsed.' }
    $publicTextGuard = $plannerAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-PublicReleaseText' }, $true)
    if (-not $publicTextGuard) { throw 'Release text guard is missing.' }
    $domainRules = @($publicTextGuard.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('(?=$|[^A-Za-z0-9.-])') }, $true))
    if ($domainRules.Count -ne 1) { throw 'Release domain deny rule is unresolved.' }
    $domainGroup = [regex]::Match($domainRules[0].Value, '\(\?:([^()]+)\)\(\?=\$\|')
    if (-not $domainGroup.Success) { throw 'Release domain deny catalogue is unresolved.' }
    foreach ($deniedDomain in $domainGroup.Groups[1].Value -split '\|') {
        $fixture = Fixture
        $syntheticHost = 'probe.' + [regex]::Unescape($deniedDomain)
        ('abc123 ' + $syntheticHost) | Set-Content (Join-Path $fixture.Path commits.txt)
        $result = Run $fixture
        Assert (-not $result.Ok -and $result.Error.Contains('prohibited internal domain')) 'Configured denied domains in release commit evidence must fail.'
    }
    $fixture = Fixture; 'abc123 A:\private\record.md' | Set-Content (Join-Path $fixture.Path commits.txt); Assert (-not (Run $fixture).Ok) 'Absolute paths in release commit evidence must fail.'
    $fixture = Fixture; 'abc123 \\private-host\share\record.md' | Set-Content (Join-Path $fixture.Path commits.txt); Assert (-not (Run $fixture).Ok) 'UNC paths in release commit evidence must fail.'
    $outsideVersion = Join-Path $temp 'outside-version.txt'; '9.9.9' | Set-Content $outsideVersion -NoNewline
    $fixture = Fixture; $profile = Get-Content (Join-Path $fixture.Path .repository-standards.json) -Raw | ConvertFrom-Json; $profile.releaseGovernance.versionSources = @('..\outside-version.txt'); $profile | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $fixture.Path .repository-standards.json); $escaped = $false; try { & $versionTool -RepositoryRoot $fixture.Path | Out-Null } catch { $escaped = $true }; Assert $escaped 'Windows backslash traversal in a version source must fail.'
    $outsideDirectory = Join-Path $temp 'outside-version-directory'; New-Item -ItemType Directory -Path $outsideDirectory | Out-Null; '9.9.9' | Set-Content (Join-Path $outsideDirectory VERSION) -NoNewline
    $fixture = Fixture; $link = Join-Path $fixture.Path linked; New-Item -ItemType Junction -Path $link -Target $outsideDirectory | Out-Null; $profile = Get-Content (Join-Path $fixture.Path .repository-standards.json) -Raw | ConvertFrom-Json; $profile.releaseGovernance.versionSources = @('linked/VERSION'); $profile | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $fixture.Path .repository-standards.json); $linked = $false; try { & $versionTool -RepositoryRoot $fixture.Path | Out-Null } catch { $linked = $true }; Assert $linked 'A version source that traverses a junction must fail.'
    $fixture = Fixture; Assert (-not (Run $fixture @{ TagCommitSha = $sha; ReleaseExists = $true; ExistingReleaseTag = 'v2.0.0'; ExistingReleaseName = 'Product 2.0.0'; ExistingReleaseIsPrerelease = $false; ExistingReleaseNotes = 'wrong' }).Ok) 'Contradictory Release must fail.'
    # Exercise the real central contract without network access or publishing.
    $central = Join-Path $temp 'central-contract'; New-Item -ItemType Directory -Path $central | Out-Null
    $profile = Get-Content -LiteralPath (Join-Path $root '.repository-standards.json') -Raw | ConvertFrom-Json
    foreach ($relative in @('.repository-standards.json','CHANGELOG.md',$profile.releaseGovernance.workflowPath) + @($profile.releaseGovernance.versionSources.path)) {
        $destination = Join-Path $central $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $destination
    }
    @($profile.releaseGovernance.requiredGates | ForEach-Object { [ordered]@{ name=$_.name; path=$_.path; status='completed'; conclusion='success' } }) | ConvertTo-Json | Set-Content (Join-Path $central checks.json)
    @(4,5,6,7 | ForEach-Object { [ordered]@{ reference="#$_"; number=$_; type='issue'; classification=if ($_ -eq 7) { 'bug' } else { 'feature' }; targetVersion='3.2.0'; delivered=$true } }) | ConvertTo-Json | Set-Content (Join-Path $central issues.json)
    'abc123 Adopt governed release contract' | Set-Content (Join-Path $central commits.txt)
    $centralFixture = [pscustomobject]@{ Path=$central; Version='3.2.0' }
    $centralPlan = Run $centralFixture @{ PreviousVersion='3.1.4' }
    Assert ($centralPlan.Ok -and $centralPlan.Plan.action -eq 'CreateTagAndRelease') ('Central release contract should be ready. ' + $centralPlan.Error)
    Assert ($centralPlan.Plan.releaseName -ceq '3.2.0' -and $centralPlan.Plan.tag -ceq 'v3.2.0') 'Central release identity must match the canonical version.'
    Assert ((@($centralPlan.Plan.deliveredIssues.number | Sort-Object) -join ',') -ceq '4,5,6,7') 'Central release must cover exactly its delivered issues.'
    Assert ((Run $centralFixture @{ PreviousVersion='3.2.0' }).Plan.action -eq 'NoRelease') 'An unchanged central version must not publish again.'
    $centralChecks = @(Get-Content (Join-Path $central checks.json) -Raw | ConvertFrom-Json); $centralChecks[0].conclusion='failure'; $centralChecks | ConvertTo-Json | Set-Content (Join-Path $central checks.json)
    Assert (-not (Run $centralFixture @{ PreviousVersion='3.1.4' }).Ok) 'A failed exact central gate must block release.'

    # Execute the actual post-publication workflow step with a fake CLI.
    $workflow = Get-Content -LiteralPath (Join-Path $root '.github/workflows/managed-automatic-release.yml') -Raw
    $verification = [regex]::Match($workflow, '(?s)- name: Verify Release & Close Delivered Issues.*?run: \|\r?\n(?<body>.*?)(?=\r?\n      - name:)')
    Assert $verification.Success 'Release verification step must be present.'
    $body = (($verification.Groups['body'].Value -split '\r?\n' | ForEach-Object { $_ -replace '^          ', '' }) -join "`n").Replace('${{ github.sha }}', $sha)
    $verificationStep = [scriptblock]::Create($body)
    $baselineReleaseEvidence = @{ tagName='v3.2.0'; name='3.2.0'; isPrerelease=$false; body='verified notes'; isDraft=$false; isImmutable=$true }
    $testPlan = @{ tag='v3.2.0'; version='3.2.0'; prerelease=$false; releaseNotes='verified notes'; deliveredIssues=@(@{type='issue';number=12},@{type='advisory';number=$null}) }
    $testPlan | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $temp release-plan.json)
    function gh {
        $global:LASTEXITCODE=0
        if ($args[0] -eq 'api' -and $args[1] -match '/git/ref/') { return (@{object=@{type='tag';sha=$other}} | ConvertTo-Json -Depth 4) }
        if ($args[0] -eq 'api' -and $args[1] -match '/git/tags/') { $global:LASTEXITCODE=$script:tagExit; return (@{object=@{type='commit';sha=$script:tagSha}} | ConvertTo-Json -Depth 4) }
        if ($args[0] -eq 'release') { return ($script:releaseEvidence | ConvertTo-Json) }
        if ($args[0] -eq 'issue') { $script:closed += [int]$args[2]; return }
        throw 'Unexpected CLI call in release verification fixture.'
    }
    Push-Location $temp
    try {
        foreach ($case in @('immutable','draft','mutable','wrong-tag','tag-api-failure')) {
            $script:closed=@(); $script:tagSha=$sha; $script:tagExit=0; $script:releaseEvidence=$baselineReleaseEvidence.Clone()
            if ($case -eq 'draft') { $script:releaseEvidence.isDraft=$true }
            if ($case -eq 'mutable') { $script:releaseEvidence.isImmutable=$false }
            if ($case -eq 'wrong-tag') { $script:tagSha=$other }
            if ($case -eq 'tag-api-failure') { $script:tagExit=1 }
            $accepted=$true; try { & $verificationStep } catch { $accepted=$false }
            if ($case -eq 'immutable') { Assert ($accepted -and ($script:closed -join ',') -ceq '12') 'A verified immutable Release should close delivered issues only.' }
            else { Assert (-not $accepted -and $script:closed.Count -eq 0) "Unsafe Release evidence must prevent issue closure: $case" }
        }
    } finally { Pop-Location; Remove-Item Function:gh }
    Write-Host "$passed assertions passed."
} finally { if (Test-Path $temp) { Remove-Item $temp -Recurse -Force } }
