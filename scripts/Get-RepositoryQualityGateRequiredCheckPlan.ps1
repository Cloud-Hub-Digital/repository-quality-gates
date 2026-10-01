# SPDX-License-Identifier: MIT
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$Repository,
    [string]$RequiredCheckPolicyPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'policy\required-check-enforcement.json'),
    [ValidateSet('Objects', 'Json')][string]$OutputFormat = 'Objects',
    [string]$ResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-RequiredCheckPolicy([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'The required-check enforcement policy file is missing.' }
    try { $policy = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { throw 'The required-check enforcement policy is invalid JSON.' }
    if ([int]$policy.schemaVersion -ne 1 -or [string]$policy.public.mode -cne 'github-rules-required' -or [string]$policy.private.mode -cne 'rqg-verified-merge-exception' -or $policy.private.enabled -ne $true) {
        throw 'The required-check enforcement policy is not an approved schema 1 policy.'
    }
    $requiredControls = @(
        'expected-checks-derived-from-deployed-modules',
        'all-expected-checks-observed',
        'all-observed-executions-accepted',
        'stable-check-set',
        'exact-head-and-base-reverified',
        'merge-pinned-to-verified-head',
        'default-branch-version-verified',
        'unverified-state-fails-closed'
    )
    $actualControls = @($policy.private.requiredControls | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Sort-Object -Unique)
    if (@($requiredControls | Where-Object { $_ -notin $actualControls }).Count -or @($actualControls | Where-Object { $_ -notin $requiredControls }).Count -or $actualControls.Count -ne $requiredControls.Count) {
        throw 'The private required-check enforcement exception does not contain the exact approved control set.'
    }
    return $policy
}

function Test-PrivatePlanLimitation([string]$Message) {
    return -not [string]::IsNullOrWhiteSpace($Message) -and $Message -match '(?i)(upgrade\s+to\s+GitHub\s+(?:Pro|Team|Enterprise)|branch protection rules are not available for private repositories|protected branches are available (?:to|for).*(?:Pro|Team|Enterprise)|endpoint is unavailable for private repositories on (?:the|your) current plan)'
}

function Get-ExpectedChecks([object]$State) {
    $checkNamesByModule = @{
        documentation = 'Markdown Hygiene'
        dotnet = '.NET Build And Test'
        go = 'Go Format, Vet, Test, And Build'
        licensing = 'Licence Decision'
        'module-drift' = 'Report Required Quality Gates'
        node = 'JavaScript Syntax, Test, And Build'
        php = 'PHP Syntax And Project Test'
        platformio = 'Firmware Build'
        powershell = 'PowerShell And Regression Tests'
        python = 'Python Compile And Test'
        'secret-scanning' = 'Secret Scan'
        shell = 'Shell Syntax'
    }
    $checks = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($module in @($State.modules)) {
        $moduleName = [string]$module
        if ($checkNamesByModule.ContainsKey($moduleName)) { $null = $checks.Add([string]$checkNamesByModule[$moduleName]) }
    }
    if (-not $checks.Count) { throw 'The managed state does not identify any expected quality checks.' }
    return @($checks | Sort-Object)
}

function Invoke-Gh([string[]]$Arguments, [string]$FailureMessage) {
    $output = @(& gh @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "$FailureMessage $($output -join [Environment]::NewLine)" }
    return ($output -join [Environment]::NewLine)
}

$policy = Get-RequiredCheckPolicy $RequiredCheckPolicyPath
$rows = [Collections.Generic.List[object]]::new()

foreach ($repositoryName in @($Repository | Sort-Object -Unique)) {
    if ($repositoryName -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw "Invalid repository name: $repositoryName" }
    $metadataText = Invoke-Gh @('api', "repos/$repositoryName", '--jq', '{defaultBranch:.default_branch,visibility:.visibility,private:.private}') 'Unable to read repository metadata.'
    try { $metadata = $metadataText | ConvertFrom-Json }
    catch { throw "GitHub returned invalid metadata for $repositoryName." }
    $defaultBranch = ([string]$metadata.defaultBranch).Trim()
    if (-not $defaultBranch) { throw "$repositoryName does not identify a default branch." }
    $visibilityValue = if ($metadata.PSObject.Properties.Name -contains 'visibility') { [string]$metadata.visibility } else { '' }
    $privateValue = if ($metadata.PSObject.Properties.Name -contains 'private') { $metadata.private } else { $false }
    $visibility = if ($visibilityValue -in @('public', 'private')) { (Get-Culture).TextInfo.ToTitleCase($visibilityValue) } elseif ($privateValue -eq $true) { 'Private' } else { 'Public' }

    $encodedStatePath = [Uri]::EscapeDataString('.repository-quality-gates.json')
    $stateBase64 = Invoke-Gh @('api', "repos/$repositoryName/contents/$encodedStatePath`?ref=$([Uri]::EscapeDataString($defaultBranch))", '--jq', '.content') 'Unable to read the managed state.'
    try { $state = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($stateBase64 -replace '\s', ''))) | ConvertFrom-Json }
    catch { throw "GitHub returned invalid managed state for $repositoryName." }
    $expectedChecks = @(Get-ExpectedChecks $state)

    $encodedBranch = [Uri]::EscapeDataString($defaultBranch)
    $ruleOutput = @(& gh api -H 'Accept: application/vnd.github+json' "repos/$repositoryName/rules/branches/$encodedBranch`?per_page=100" 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $ruleError = ($ruleOutput -join [Environment]::NewLine).Trim()
        if ($visibility -eq 'Private' -and (Test-PrivatePlanLimitation $ruleError)) {
            $rows.Add([pscustomobject][ordered]@{
                repository = $repositoryName
                visibility = $visibility
                defaultBranch = $defaultBranch
                expectedChecks = $expectedChecks
                requiredChecks = @()
                missingChecks = @()
                control = [string]$policy.private.mode
                exceptionId = [string]$policy.private.exceptionId
                action = 'UseVerifiedMergeException'
            })
            continue
        }
        throw "Unable to inspect active default-branch rules for $repositoryName. $ruleError"
    }
    try { $rules = @((($ruleOutput -join [Environment]::NewLine) | ConvertFrom-Json)) }
    catch { throw "GitHub returned invalid active default-branch rule data for $repositoryName." }
    if ($rules.Count -ge 100) { throw "$repositoryName reached the active-rule API page limit." }
    $requiredContexts = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($rule in @($rules | Where-Object { [string]$_.type -eq 'required_status_checks' })) {
        foreach ($requiredCheck in @($rule.parameters.required_status_checks)) {
            $context = ([string]$requiredCheck.context).Trim()
            if ($context) { $null = $requiredContexts.Add($context) }
        }
    }
    $requiredChecks = @($requiredContexts | Sort-Object)
    $missingChecks = @($expectedChecks | Where-Object { -not $requiredContexts.Contains($_) })
    $rows.Add([pscustomobject][ordered]@{
        repository = $repositoryName
        visibility = $visibility
        defaultBranch = $defaultBranch
        expectedChecks = $expectedChecks
        requiredChecks = $requiredChecks
        missingChecks = $missingChecks
        control = [string]$policy.public.mode
        exceptionId = $null
        action = if ($missingChecks.Count) { 'ConfigureGitHubRules' } else { 'None' }
    })
}

$result = [pscustomobject][ordered]@{
    schemaVersion = 1
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    repositories = @($rows)
    configurationRequired = @($rows | Where-Object action -eq 'ConfigureGitHubRules').Count
    verifiedMergeExceptions = @($rows | Where-Object action -eq 'UseVerifiedMergeException').Count
}
$json = $result | ConvertTo-Json -Depth 10
if ($ResultPath) {
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($ResultPath))
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Set-Content -LiteralPath $ResultPath -Value $json -Encoding utf8NoBOM
}
if ($OutputFormat -eq 'Json') { $json } else { $result }
