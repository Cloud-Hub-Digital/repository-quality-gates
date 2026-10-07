# SPDX-License-Identifier: MIT
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$appFleetTool = Join-Path $root 'scripts\Invoke-RepositoryQualityGateAppFleetUpdate.ps1'
$fleetWorkflow = Join-Path $root '.github\workflows\update-managed-repositories.yml'
$automaticReleaseWorkflow = Join-Path $root '.github\workflows\automatic-release.yml'
$cloneProbeWorkflow = Join-Path $root '.github\workflows\github-app-clone-probe.yml'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('rqg-app-fleet-tests-' + [guid]::NewGuid().ToString('N'))
$passed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:passed++
}

function ConvertFrom-Base64Url([string]$Value) {
    $base64 = $Value.Replace('-', '+').Replace('_', '/')
    while ($base64.Length % 4) { $base64 += '=' }
    return [Convert]::FromBase64String($base64)
}

try {
    . $appFleetTool
    & python (Join-Path $PSScriptRoot 'test_fleet_email.py')
    Assert-True ($LASTEXITCODE -eq 0) 'Actual preview and apply email rendering must pass with a mocked SMTP transport.'

    $appFleetText = Get-Content -LiteralPath $appFleetTool -Raw
    $workflowText = Get-Content -LiteralPath $fleetWorkflow -Raw
    $automaticReleaseWorkflowText = Get-Content -LiteralPath $automaticReleaseWorkflow -Raw
    $cloneProbeWorkflowText = Get-Content -LiteralPath $cloneProbeWorkflow -Raw
    Assert-True ($workflowText.Contains('default: preview')) 'Manual rollout requests should default to preview.'
    Assert-True ($workflowText.Contains('send_email:')) 'Manual rollout requests should expose an explicit email-report switch.'
    Assert-True ($workflowText -match '(?ms)^      send_email:\r?\n        description: Send the single final report; valid only for a full-fleet apply\.\r?\n        required: true\r?\n        default: false\r?\n        type: boolean\r?$') 'Manual email reporting should default to disabled.'
    Assert-True ($workflowText.Contains('-Apply:$applyWave -AutoMerge:$applyWave')) 'Preview must leave both mutation switches disabled.'
    Assert-True ($workflowText.Contains("vars.RQG_FLEET_AUTOMATION_PAUSED != 'true'")) 'Automatic events should respect the operational pause.'
    $waveNames = @(1..40 | ForEach-Object { "example/repository-$_" })
    $partition = @(0..3 | ForEach-Object { $index = $_; $waveNames | Where-Object { (Get-RqgRepositoryWave $_ 4) -eq $index } })
    Assert-True ($partition.Count -eq 40 -and @($partition | Sort-Object -Unique).Count -eq 40) 'The complete wave set must cover each discovered repository exactly once.'
    Assert-True ((Get-RqgRepositoryWave 'Example/Repository-1' 4) -eq (Get-RqgRepositoryWave 'example/repository-1' 4)) 'Repository-name casing must not change wave membership.'
    Assert-True ((Get-RqgRepositoryWave 'example/repository-1' 1) -eq 0) 'The default single wave should retain full-fleet behavior.'
    $invalidWaveRejected = $false
    try { Invoke-RepositoryQualityGateAppFleetUpdate -SelectedWaveCount 2 -SelectedWaveIndex 2 } catch { $invalidWaveRejected = $_.Exception.Message -eq 'Wave index must be smaller than wave count.' }
    Assert-True $invalidWaveRejected 'Invalid wave bounds must fail before authentication or mutation.'
    Assert-True ($cloneProbeWorkflowText.Contains('name: GitHub App Clone Probe')) 'A separate read-only GitHub App clone-probe workflow should exist.'
    Assert-True ($cloneProbeWorkflowText.Contains('repository_sha256:')) 'The clone probe should accept only a repository-name digest.'
    Assert-True (-not $cloneProbeWorkflowText.Contains('AutoEnroll') -and -not $cloneProbeWorkflowText.Contains('AutoMerge') -and -not $cloneProbeWorkflowText.Contains(' -Apply')) 'The clone-probe workflow must not enable fleet mutation.'
    Assert-True ($cloneProbeWorkflowText.Contains('-CloneProbeRepositorySha256 $env:RQG_CLONE_PROBE_REPOSITORY_SHA256')) 'The clone-probe workflow should pass the protected digest to the App wrapper.'
    Assert-True ($workflowText.Contains('timeout-minutes: 120')) 'The complete fleet rollout should allow up to 120 minutes.'
    Assert-True ($workflowText.Contains('name: Email Fleet Rollout Report')) 'The fleet workflow should send its configured completion report.'
    Assert-True ($workflowText.Contains('name: Preserve Fleet Rollout Report')) 'The updater should preserve its sanitized diagnostic report.'
    Assert-True (-not $workflowText.Contains('name: Retrieve Fleet Rollout Report')) 'The private email report must not pass through a downloadable artifact.'
    Assert-True (-not $workflowText.Contains('report_base64')) 'The detailed report should not use a secret-sensitive job output.'
    Assert-True ($workflowText.Contains("if (`$line -match '^::add-mask::(?<value>.+)`$')")) 'The report writer should recognize GitHub masking control lines.'
    Assert-True ($workflowText.Contains('$maskedValues.Add([string]$Matches.value)')) 'The report writer should retain every registered mask value in memory.'
    Assert-True ($workflowText.Contains("`$Line = `$Line.Replace(`$value, '***')")) 'The preserved report must replace masked credentials and private identifiers.'
    Assert-True ($workflowText.Contains('(ConvertTo-SanitizedReportLine $failure)')) 'Failure diagnostics must receive the same report sanitization.'
    Assert-True ($workflowText.Contains('actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a')) 'The report uploader should use the pinned Node.js 24 artifact action.'
    Assert-True (-not $workflowText.Contains('actions/download-artifact@')) 'The email-only repository table must not be downloaded from an artifact.'
    Assert-True ($workflowText.Contains('-PrivateReportPath $privateReportPath')) 'The App wrapper should receive a dedicated private report path.'
    Assert-True ($workflowText.Contains('PRIVATE_REPORT_PATH: ${{ github.workspace }}/.rqg-private/email-report.json')) 'The email step should read the private local report directly.'
    Assert-True ($workflowText.Contains('<table style=\"border-collapse:collapse;border:1px solid #999;width:100%;table-layout:fixed\">')) 'The HTML email should outline the complete table and use fixed column sizing.'
    Assert-True ($workflowText.Contains('<colgroup><col style=\"width:24%\"><col style=\"width:12%\"><col style=\"width:24%\"><col style=\"width:16%\"><col style=\"width:24%\"></colgroup>')) 'The HTML email should assign deliberate widths to every detail column.'
    Assert-True ($workflowText.Contains('background-color:#e6e6e6!important;color:#111111!important;font-weight:bold;white-space:nowrap')) 'Every HTML email header should define readable colours and keep its label on one line.'
    Assert-True ($workflowText.Contains('<td style=\"border:1px solid #999;padding:6px;vertical-align:top;overflow-wrap:anywhere\">')) 'Every HTML email data cell should have a visible border and controlled wrapping.'
    Assert-True ($workflowText.Contains('<h2>Status Summary</h2>')) 'The HTML email should include a status-count summary above the repository table.'
    Assert-True ($workflowText.Contains('<h2>Status Guide</h2>')) 'The HTML email should explain the rollout status names.'
    Assert-True ($workflowText.Contains('"UpdatedSuccessfully": "Updated Successfully"')) 'The email should render the successful update status consistently.'
    Assert-True ($workflowText.Contains('"RequiresLicenceDecision": "Requires Licence Decision"')) 'The email should render licence-decision failures explicitly.'
    Assert-True ($workflowText.Contains('"ManagedFileConflict": "Managed File Conflict"')) 'The email should render managed-file conflicts explicitly.'
    Assert-True ($workflowText.Contains('"RequiredChecksNotEnforced": "Required Checks Not Enforced"')) 'The email should render missing required-check enforcement explicitly.'
    Assert-True ($workflowText.Contains('"FailedChecks": "Failed Checks"')) 'The email should render required-check failures explicitly.'
    Assert-True ($workflowText.Contains('"CloneFailed": "Clone Failed"')) 'The email should render clone failures explicitly.'
    Assert-True ($workflowText.Contains("html.escape(row['runner']).replace(chr(10), '<br>')")) 'The HTML email should render each downstream runner on its own line.'
    Assert-True ($workflowText.Contains('MESSAGE_FROM_EMAIL: ${{ secrets.RQG_REPORT_FROM_EMAIL }}')) 'The sender address should use the renamed protected email secret.'
    Assert-True ($workflowText.Contains('MESSAGE_TO_EMAIL: ${{ secrets.RQG_REPORT_TO_EMAIL }}')) 'The recipient address should use the renamed protected email secret.'
    Assert-True ($workflowText.Contains('MESSAGE_FROM_NAME: ${{ secrets.RQG_REPORT_FROM_NAME }}')) 'The sender display name should use its optional protected secret.'
    Assert-True ($workflowText.Contains('MESSAGE_TO_NAME: ${{ secrets.RQG_REPORT_TO_NAME }}')) 'The recipient display name should use its optional protected secret.'
    Assert-True ($workflowText.Contains('from_name = os.environ.get("MESSAGE_FROM_NAME", "").strip() or from_address')) 'An absent or empty sender display name should fall back to the sender address.'
    Assert-True ($workflowText.Contains('to_name = os.environ.get("MESSAGE_TO_NAME", "").strip() or to_address')) 'An absent or empty recipient display name should fall back to the recipient address.'
    Assert-True ($workflowText.Contains('message["From"] = formataddr((from_name, from_address))')) 'The email should combine the resolved sender name and address.'
    Assert-True ($workflowText.Contains('message["To"] = formataddr((to_name, to_address))')) 'The email should combine the resolved recipient name and address.'
    Assert-True (-not $workflowText.Contains('secrets.RQG_REPORT_FROM }}')) 'The retired sender secret name should not remain in the workflow.'
    Assert-True (-not $workflowText.Contains('secrets.RQG_REPORT_TO }}')) 'The retired recipient secret name should not remain in the workflow.'
    Assert-True ($workflowText.Contains("vars.RQG_REPORT_EMAIL_ENABLED == 'true'")) 'Email reporting should remain controlled by the repository variable.'
    $emailCondition = "if: `${{ always() && vars.RQG_REPORT_EMAIL_ENABLED == 'true' && (github.event_name == 'release' || (github.event_name == 'workflow_dispatch' && inputs.mode == 'apply' && inputs.wave_count == '1' && inputs.wave_index == '0' && inputs.send_email == true)) }}"
    Assert-True ($workflowText.Contains($emailCondition)) 'Email reporting should run only for a release event or an explicitly requested full-fleet manual apply.'
    Assert-True (-not $workflowText.Contains("if: `${{ always() && vars.RQG_REPORT_EMAIL_ENABLED == 'true' }}")) 'Preview, schedule, and intermediate-wave runs must not send email automatically.'
    Assert-True ($automaticReleaseWorkflowText.Contains('-f mode=apply -f wave_count=1 -f wave_index=0 -f send_email=true')) 'The automatic release should request exactly one report from its full-fleet apply.'
    Assert-True ($workflowText.Contains("steps.rollout.outcome == 'failure'")) 'A reported rollout failure should still fail the workflow.'

    Assert-True ((ConvertTo-RqgEmailComment -Status 'Current' -Detail '') -eq 'Already current.') 'Current repositories should use a short factual email comment.'
    Assert-True ((ConvertTo-RqgEmailComment -Status 'EmptyRepository' -Detail 'Long internal detail.') -eq 'Skipped: repository has no commits.') 'Empty repositories should use a short factual email comment.'
    Assert-True ((ConvertTo-RqgEmailComment -Status 'MergedCleanupRequired' -Detail 'Long cleanup detail.') -eq 'Update merged; temporary branch cleanup failed.') 'Cleanup failures should use a short factual email comment.'
    Assert-True ((ConvertTo-RqgEmailComment -Status 'RequiresLicenceDecision' -Detail 'Long internal detail.') -eq 'Licence decision requires approval or correction.') 'Licence-decision failures should use a short actionable comment.'
    Assert-True ((ConvertTo-RqgEmailComment -Status 'ManagedFileConflict' -Detail 'Long internal detail.') -eq 'Managed-file conflict requires review.') 'Managed-file conflicts should use a short actionable comment.'
    $checkFailureDetail = 'Stage: Pull-request quality checks. Cause: Pull-request quality checks failed: Build (failure), Build (failure), Require OP reference (failure) Context: Target RQG version: 1.5.4. Cleanup: Removed. Investigation: Review checks.'
    Assert-True ((ConvertTo-RqgEmailComment -Status 'FailedChecks' -Detail $checkFailureDetail) -eq 'PR checks failed: Build; Require OP reference.') 'Failed check comments should be concise and deduplicate check names.'
    Assert-True ((ConvertTo-RqgEmailComment -Status 'MergedWithFailedChecks' -Detail $checkFailureDetail) -eq 'Update merged with failed checks: Build; Require OP reference.') 'Merged check failures should remain explicit and concise.'
    $generalFailureComment = ConvertTo-RqgEmailComment -Status 'CloneFailed' -Detail 'Stage: Repository clone. Cause: Unable to clone the repository. Context: Target RQG version: 1.5.4. Cleanup: None. Investigation: Verify access.'
    Assert-True ($generalFailureComment -eq 'Repository clone failed: Unable to clone the repository.') 'Other failed comments should state only the failing stage and cause.'
    Assert-True ($generalFailureComment.Length -le 240) 'Email comments should remain concise.'
    Assert-True ((Get-RqgInstallationFailureStatus 'Installation authentication') -eq 'InstallationAuthenticationFailed') 'Installation authentication failures should be classified precisely.'
    Assert-True ((Get-RqgInstallationFailureStatus 'Repository discovery') -eq 'RepositoryDiscoveryFailed') 'Repository discovery failures should be classified precisely.'
    Assert-True ((Get-RqgInstallationFailureStatus 'Structured result processing') -eq 'ResultProcessingFailed') 'Structured result failures should be classified precisely.'
    Assert-True ((Get-RqgInstallationFailureStatus 'Fleet execution') -eq 'FleetExecutionFailed') 'Fleet execution failures should be classified precisely.'
    Assert-True (-not $appFleetText.Contains("status = 'Failed'")) 'Installation-level rows should not collapse distinct failures into a broad Failed status.'

    $rsa = [Security.Cryptography.RSA]::Create(2048)
    try {
        $privateKey = $rsa.ExportPkcs8PrivateKeyPem()
        $jwt = New-GitHubAppJwt '12345' $privateKey
        $parts = $jwt.Split('.')
        Assert-True ($parts.Count -eq 3) 'The GitHub App JWT should contain three segments.'
        $verified = $rsa.VerifyData(
            [Text.Encoding]::UTF8.GetBytes("$($parts[0]).$($parts[1])"),
            (ConvertFrom-Base64Url $parts[2]),
            [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1
        )
        Assert-True $verified 'The GitHub App JWT should have a valid RSA-SHA256 signature.'
        $payload = [Text.Encoding]::UTF8.GetString((ConvertFrom-Base64Url $parts[1])) | ConvertFrom-Json
        Assert-True ([string]$payload.iss -eq '12345') 'The GitHub App JWT should identify the configured App.'
        Assert-True (([long]$payload.exp - [long]$payload.iat) -eq 600) 'The GitHub App JWT should use a ten-minute validity window.'
    }
    finally { $rsa.Dispose() }

    $script:jwtSequence = 0
    function New-GitHubAppJwt([string]$ApplicationId, [string]$PemPrivateKey) {
        $script:jwtSequence++
        return "synthetic-jwt-$script:jwtSequence"
    }
    $script:installationTokenJwtHeaders = [Collections.Generic.List[string]]::new()

    New-Item -ItemType Directory -Path (Join-Path $testRoot 'scripts') -Force | Out-Null
    $recordPath = Join-Path $testRoot 'fleet-records.jsonl'
$fakeFleet = @'
param([string[]]$Repository, [string]$TemplateRoot, [switch]$AutoEnroll, [switch]$Apply, [switch]$AutoMerge, [int]$TemporaryBranchLifetimeHours, [string]$ResultPath)
[pscustomobject]@{
    repositories = @($Repository)
    token = $env:GH_TOKEN
    gitConfigCount = $env:GIT_CONFIG_COUNT
    gitConfigKey = $env:GIT_CONFIG_KEY_0
    gitAuthorizationHeader = $env:GIT_CONFIG_VALUE_0
    autoEnroll = [bool]$AutoEnroll
    apply = [bool]$Apply
    autoMerge = [bool]$AutoMerge
    lifetime = $TemporaryBranchLifetimeHours
} | ConvertTo-Json -Compress | Add-Content -LiteralPath $env:RQG_TEST_RECORD_PATH -Encoding utf8
$status = if ($env:RQG_TEST_FAIL_FIRST -eq '1' -and $env:GH_TOKEN -eq 'installation-token-101') { 'FailedChecks' } else { 'Current' }
$summary = [ordered]@{
    repositories = @($Repository | ForEach-Object { [pscustomobject]@{ repository = $_; status = $status; runners = if ($status -eq 'FailedChecks') { @('rqg-win-one', 'rqg-linux-one') } else { @() }; detail = "Synthetic $status result. Token=$env:GH_TOKEN" } })
    failed = if ($status -eq 'FailedChecks') { 1 } else { 0 }
}
if ($env:RQG_TEST_INVALID_FIRST -eq '1' -and $env:GH_TOKEN -eq 'installation-token-101') {
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($ResultPath), '{', [Text.UTF8Encoding]::new($false))
}
else {
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($ResultPath), ($summary | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
}
$summary | ConvertTo-Json -Depth 4
if ($env:RQG_TEST_FAIL_FIRST -eq '1' -and $env:GH_TOKEN -eq 'installation-token-101') { throw 'Synthetic first-installation failure.' }
'@
    [IO.File]::WriteAllText((Join-Path $testRoot 'scripts\Invoke-RepositoryQualityGateFleetUpdate.ps1'), $fakeFleet, [Text.UTF8Encoding]::new($false))
    $fakeAdmin = @'
param([string[]]$Repository, [string]$ExpectedTemplateVersion, [string]$ExpectedCommit, [switch]$Apply, [string]$OutputFormat)
if ($ExpectedTemplateVersion -ne '3.2.0' -or $ExpectedCommit -ne ('a' * 40) -or -not $Apply) { throw 'Administration sequencing contract failed.' }
if ($env:RQG_TEST_ADMIN_FAIL -eq '1') { throw 'Synthetic administration permission failure.' }
[pscustomobject]@{ repositories = @([pscustomobject]@{repository=$Repository[0];status='AppliedAndVerified'}) } | ConvertTo-Json -Depth 4
'@
    [IO.File]::WriteAllText((Join-Path $testRoot 'scripts/Invoke-RepositoryRulesetEngine.ps1'), $fakeAdmin, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $testRoot 'scripts/Invoke-RepositoryQualityGates.ps1'), 'param([switch]$Version); "Repository Quality Gates 3.2.0"', [Text.UTF8Encoding]::new($false))

    function global:Invoke-RestMethod {
        param([string]$Method, [string]$Uri, [hashtable]$Headers, [string]$ContentType)
        if ($Method -eq 'Get' -and $Uri -match '/app/installations\?') {
            # Match Invoke-RestMethod's real treatment of a top-level JSON array:
            # one non-enumerated response object containing both installations.
            Write-Output -NoEnumerate @(
                [pscustomobject]@{ id = 101; account = [pscustomobject]@{ login = 'first-owner' } },
                [pscustomobject]@{ id = 202; account = [pscustomobject]@{ login = 'second-owner' } }
            )
            return
        }
        if ($Method -eq 'Post' -and $Uri -match '/app/installations/(?<id>\d+)/access_tokens$') {
            $script:installationTokenJwtHeaders.Add([string]$Headers.Authorization)
            if ($env:RQG_TEST_TOKEN_FAIL_FIRST -eq '1' -and $Matches.id -eq '101') { throw 'Synthetic token issuance failure.' }
            return [pscustomobject]@{ token = "installation-token-$($Matches.id)" }
        }
        if ($Method -eq 'Get' -and $Uri -match '/installation/repositories\?') {
            $token = ([string]$Headers.Authorization) -replace '^Bearer\s+', ''
            if ($token -eq 'installation-token-101') {
                return [pscustomobject]@{ repositories = @([pscustomobject]@{ full_name = 'first-owner/one'; private = $true }) }
            }
            if ($token -eq 'installation-token-202') {
                return [pscustomobject]@{ repositories = @([pscustomobject]@{ full_name = 'second-owner/two'; private = $false }) }
            }
            throw 'The installation token was not selected before repository discovery.'
        }
        throw "Unexpected Invoke-RestMethod request: $Method $Uri"
    }
    function global:gh {
        $joined = $args -join ' '
        if ($joined -match '^api repos/.+ --jq \.default_branch$') { 'main'; $global:LASTEXITCODE=0; return }
        if ($joined -match '/git/ref/heads/main --jq \.object.sha$') { 'a' * 40; $global:LASTEXITCODE=0; return }
        if ($joined -eq 'api --method DELETE /installation/token') {
            $global:LASTEXITCODE = 0
            return
        }
        throw "Unexpected gh invocation: $joined"
    }
    $script:cloneProbeRepositories = [Collections.Generic.List[string]]::new()
    $script:administrationContentProbes = [Collections.Generic.List[string]]::new()
    function Test-RqgAdministrationContent([string]$RepositoryName, [string]$Commit, [string]$TemplatePath) {
        if ($Commit -cne ('a' * 40)) { throw 'Unexpected exact administration commit.' }
        $script:administrationContentProbes.Add($RepositoryName)
    }
    function Invoke-RqgGitHubAppCloneProbe([string]$RepositoryName, [string]$Destination) {
        $script:cloneProbeRepositories.Add($RepositoryName)
        return '0123456789abcdef0123456789abcdef01234567'
    }
    Assert-True ((Get-RqgRunnerDisplay ([pscustomobject]@{ status = 'FailedChecks'; runners = @('rqg-win-test', 'rqg-linux-test') })) -eq "rqg-linux-test$([Environment]::NewLine)rqg-win-test") 'The email runner cell should list each downstream runner on its own line.'
    Assert-True ((Get-RqgRunnerDisplay ([pscustomobject]@{ status = 'Current' })) -eq 'Not Used') 'A result without executed checks should identify that no runner was used.'
    Assert-True ((Get-RqgRunnerDisplay ([pscustomobject]@{ status = 'FailedChecks' })) -eq 'Unavailable') 'A failed result without runner metadata should remain explicit.'
    Assert-True ($appFleetText.Contains('A GitHub App installation failed: $maskedInstallationFailureComment')) 'Installation failures should retain their sanitized stage and cause in the workflow log.'
    Assert-True ($appFleetText.Contains('A GitHub App installation produced an invalid structured result: $maskedInstallationFailureComment')) 'Structured-result failures should retain their actionable sanitized diagnostic detail.'

    $testRsa = [Security.Cryptography.RSA]::Create(2048)
    $oldToken = $env:GH_TOKEN
    $oldGitConfigCount = $env:GIT_CONFIG_COUNT
    $oldGitConfigKey0 = $env:GIT_CONFIG_KEY_0
    $oldGitConfigValue0 = $env:GIT_CONFIG_VALUE_0
    $env:GIT_CONFIG_COUNT = '7'
    $env:GIT_CONFIG_KEY_0 = 'test.original.key'
    $env:GIT_CONFIG_VALUE_0 = 'test-original-value'
    $oldRunnerName = $env:RUNNER_NAME
    $env:RUNNER_NAME = 'rqg-win-test'
    $env:RQG_TEST_RECORD_PATH = $recordPath
    $privateReportPath = Join-Path $testRoot 'private-report.json'
    try {
        Invoke-RepositoryQualityGateAppFleetUpdate -ApplicationId '12345' -PemPrivateKey $testRsa.ExportPkcs8PrivateKeyPem() -ResolvedTemplateRoot $testRoot -EnableAutoEnroll -EnableApply -EnableAutoMerge -ResolvedPrivateReportPath $privateReportPath -BranchLifetimeHours 24
        $records = @(Get-Content -LiteralPath $recordPath | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-True ($records.Count -eq 2) 'Every GitHub App installation should run the fleet updater once.'
        Assert-True ($records[0].repositories[0] -eq 'first-owner/one') 'The first installation should receive only its repository list.'
        Assert-True ($records[1].repositories[0] -eq 'second-owner/two') 'The second installation should receive only its repository list.'
        Assert-True ($records[0].token -eq 'installation-token-101' -and $records[1].token -eq 'installation-token-202') 'Each installation should use its own short-lived token.'
        Assert-True ($script:installationTokenJwtHeaders.Count -eq 2) 'Each installation should request its own installation token.'
        Assert-True ($script:installationTokenJwtHeaders[0] -ne $script:installationTokenJwtHeaders[1]) 'Each installation token request should use a freshly generated GitHub App JWT.'
        Assert-True ($records[0].gitConfigCount -eq '1' -and $records[1].gitConfigCount -eq '1') 'Git should receive one temporary authentication configuration entry.'
        Assert-True ($records[0].gitConfigKey -eq 'http.https://github.com/.extraheader') 'Git authentication should be scoped to HTTPS requests for github.com.'
        $expectedHeader = 'AUTHORIZATION: basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('x-access-token:installation-token-101'))
        Assert-True ($records[0].gitAuthorizationHeader -eq $expectedHeader -and $records[0].gitAuthorizationHeader -ne $records[1].gitAuthorizationHeader) 'Each installation should receive its own masked Git authorization header.'
        Assert-True ($records[0].autoEnroll -and $records[0].apply -and $records[0].autoMerge) 'The wrapper should forward the requested automation switches.'
        Assert-True ($records[0].lifetime -eq 24) 'The wrapper should forward the temporary branch lifetime.'
        Assert-True ($env:GIT_CONFIG_COUNT -eq '7' -and $env:GIT_CONFIG_KEY_0 -eq 'test.original.key' -and $env:GIT_CONFIG_VALUE_0 -eq 'test-original-value') 'The wrapper should restore the caller Git configuration environment.'
        $privateRows = @(Get-Content -LiteralPath $privateReportPath -Raw | ConvertFrom-Json)
        Assert-True ($privateRows.Count -eq 2) 'The private report should contain one row for each repository.'
        Assert-True ($privateRows[0].PSObject.Properties.Name -contains 'repository' -and $privateRows[0].PSObject.Properties.Name -contains 'visibility' -and $privateRows[0].PSObject.Properties.Name -contains 'runner' -and $privateRows[0].PSObject.Properties.Name -contains 'status' -and $privateRows[0].PSObject.Properties.Name -contains 'comment' -and $privateRows[0].PSObject.Properties.Name -contains 'detail') 'The private report should contain the email fields and retained diagnostic detail.'
        Assert-True ($privateRows.repository -contains 'first-owner/one' -and $privateRows.repository -contains 'second-owner/two') 'The private report should retain repository names for the email table.'
        Assert-True (@($privateRows | Where-Object repository -eq 'first-owner/one')[0].visibility -eq 'Private') 'The private report should identify private repositories.'
        Assert-True (@($privateRows | Where-Object repository -eq 'second-owner/two')[0].visibility -eq 'Public') 'The private report should identify public repositories.'
        Assert-True (@($privateRows | Where-Object repository -eq 'first-owner/one')[0].runner -eq 'Not Used') 'A current repository should report that no downstream runner was used.'
        Assert-True (@($privateRows | Where-Object repository -eq 'second-owner/two')[0].runner -eq 'Not Used') 'Every current repository should report that no downstream runner was used.'
        Assert-True (-not ((Get-Content -LiteralPath $privateReportPath -Raw) -match 'installation-token-')) 'The private email report must redact installation credentials from comments.'
        Assert-True (@($privateRows | Where-Object administrationStatus -eq 'AppliedAndVerified').Count -eq 2) 'Administration should follow verified current content under each installation token.'
        Assert-True ($script:administrationContentProbes.Count -eq 2) 'Administration must inspect exact destination content before either settings engine call.'
        $failureFixture = [pscustomobject]@{repositories=@([pscustomobject]@{repository='owner/failure';status='FailedChecks';detail='Failed checks.'})}
        $untouched = Complete-RqgFleetAdministration $failureFixture $testRoot $true
        Assert-True ($untouched.repositories[0].status -eq 'FailedChecks' -and $untouched.repositories[0].administrationStatus -eq 'NotAttempted') 'Failed content must never enter the administration engine.'
        $advancedFixture=[pscustomobject]@{repositories=@([pscustomobject]@{repository='owner/advanced';status='UpdatedSuccessfully';verifiedMergeSha='b'*40;detail='Prior merge succeeded.'})}
        $beforeProbes=$script:administrationContentProbes.Count
        $advanced=Complete-RqgFleetAdministration $advancedFixture $testRoot $true
        Assert-True ($advanced.repositories[0].status -eq 'AdministrationFailed' -and $advanced.repositories[0].detail -match 'checked merge outcome') 'Administration must reject a new unchecked default head after a successful update.'
        Assert-True ($script:administrationContentProbes.Count -eq $beforeProbes) 'A changed merge outcome must stop before settings or content inspection.'
        $exactFixture=[pscustomobject]@{repositories=@([pscustomobject]@{repository='owner/exact';status='UpdatedSuccessfully';verifiedMergeSha='a'*40;detail='Checked merge succeeded.'})}
        $exact=Complete-RqgFleetAdministration $exactFixture $testRoot $true
        Assert-True ($exact.repositories[0].status -eq 'UpdatedSuccessfully' -and $exact.repositories[0].administrationStatus -eq 'AppliedAndVerified') 'Administration may follow the exact checked merge outcome.'
        $env:RQG_TEST_ADMIN_FAIL='1'
        try {
            $fixture = [pscustomobject]@{repositories=@([pscustomobject]@{repository='owner/current';status='Current';detail='Current.'})}
            $failedAdmin = Complete-RqgFleetAdministration $fixture $testRoot $true
            Assert-True ($failedAdmin.repositories[0].status -eq 'AdministrationFailed' -and $failedAdmin.repositories[0].contentStatus -eq 'Current') 'An administration permission failure must retain the verified content outcome and fail accurately.'
        } finally { Remove-Item Env:\RQG_TEST_ADMIN_FAIL -ErrorAction SilentlyContinue }

        Remove-Item -LiteralPath $recordPath -Force
        $selectedIndex = Get-RqgRepositoryWave 'first-owner/one' 100
        Invoke-RepositoryQualityGateAppFleetUpdate -ApplicationId '12345' -PemPrivateKey $testRsa.ExportPkcs8PrivateKeyPem() -ResolvedTemplateRoot $testRoot -SelectedWaveCount 100 -SelectedWaveIndex $selectedIndex -ResolvedPrivateReportPath $privateReportPath -BranchLifetimeHours 24
        $waveRecords = @(Get-Content -LiteralPath $recordPath | ForEach-Object { $_ | ConvertFrom-Json })
        $selectedNames = @($waveRecords | ForEach-Object { $_.repositories })
        Assert-True ($selectedNames -contains 'first-owner/one') 'The selected wave must process its discovered repository.'
        Assert-True (@($selectedNames | Where-Object { (Get-RqgRepositoryWave $_ 100) -ne $selectedIndex }).Count -eq 0) 'Other waves must never reach the fleet updater.'
        Assert-True (@($waveRecords | Where-Object { $_.apply -or $_.autoMerge }).Count -eq 0) 'A preview wave must not forward apply or merge authorization.'

        Remove-Item -LiteralPath $recordPath -Force
        $env:RQG_TEST_FAIL_FIRST = '1'
        $aggregateFailure = $null
        try {
            Invoke-RepositoryQualityGateAppFleetUpdate -ApplicationId '12345' -PemPrivateKey $testRsa.ExportPkcs8PrivateKeyPem() -ResolvedTemplateRoot $testRoot -EnableAutoEnroll -EnableApply -EnableAutoMerge -ResolvedPrivateReportPath $privateReportPath -BranchLifetimeHours 24
        }
        catch { $aggregateFailure = $_ }
        $failureRecords = @(Get-Content -LiteralPath $recordPath | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-True ($null -ne $aggregateFailure) 'An installation failure should make the complete App fleet run fail after processing finishes.'
        Assert-True ($aggregateFailure.Exception.Message -match '^1 GitHub App installation\(s\) failed after all accessible installations were processed\.') 'The final error should report the aggregate installation failure count.'
        Assert-True ($failureRecords.Count -eq 2) 'A failed installation must not prevent a later installation from running.'
        Assert-True ($failureRecords[1].repositories[0] -eq 'second-owner/two') 'The later installation should still receive its repository list after an earlier failure.'
        $failureRows = @(Get-Content -LiteralPath $privateReportPath -Raw | ConvertFrom-Json)
        Assert-True (@($failureRows | Where-Object repository -eq 'first-owner/one')[0].status -eq 'FailedChecks') 'The private report should retain a precise repository failure status.'
        Assert-True (@($failureRows | Where-Object repository -eq 'first-owner/one')[0].runner -eq "rqg-linux-one$([Environment]::NewLine)rqg-win-one") 'The private report should identify every downstream self-hosted runner on its own line.'
        Assert-True (@($failureRows | Where-Object repository -eq 'first-owner/one')[0].comment -eq 'Synthetic FailedChecks result. Token=***') 'A structured repository failure should provide a concise sanitized email comment.'
        Assert-True (@($failureRows | Where-Object repository -eq 'first-owner/one')[0].detail -eq 'Synthetic FailedChecks result. Token=***') 'A structured repository failure should retain its complete sanitized diagnostic detail.'
        Assert-True (@($failureRows | Where-Object repository -eq 'second-owner/two')[0].status -eq 'Current') 'The private report should retain later successful installation results.'
        Remove-Item Env:\RQG_TEST_FAIL_FIRST -ErrorAction SilentlyContinue

        Remove-Item -LiteralPath $recordPath -Force
        $env:RQG_TEST_INVALID_FIRST = '1'
        $invalidResultFailure = $null
        try {
            Invoke-RepositoryQualityGateAppFleetUpdate -ApplicationId '12345' -PemPrivateKey $testRsa.ExportPkcs8PrivateKeyPem() -ResolvedTemplateRoot $testRoot -EnableAutoEnroll -EnableApply -EnableAutoMerge -ResolvedPrivateReportPath $privateReportPath -BranchLifetimeHours 24
        }
        catch { $invalidResultFailure = $_ }
        $invalidResultRecords = @(Get-Content -LiteralPath $recordPath | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-True ($invalidResultFailure.Exception.Message -match '^1 GitHub App installation\(s\) failed after all accessible installations were processed\.') 'An invalid structured result should produce an aggregate installation failure.'
        Assert-True ($invalidResultRecords.Count -eq 2) 'An invalid structured result must not prevent a later installation from running.'
        $invalidResultRows = @(Get-Content -LiteralPath $privateReportPath -Raw | ConvertFrom-Json)
        Assert-True (@($invalidResultRows | Where-Object repository -eq 'first-owner/one')[0].status -eq 'ResultProcessingFailed') 'An invalid structured result should create a precise failed repository row.'
        Assert-True (@($invalidResultRows | Where-Object repository -eq 'first-owner/one')[0].comment -match '^Structured result processing failed:') 'The failed row should provide a concise structured-result summary.'
        Assert-True (@($invalidResultRows | Where-Object repository -eq 'first-owner/one')[0].detail -match 'Investigation: Inspect the sanitized workflow artifact') 'The failed row should retain its actionable structured-result investigation detail.'
        Assert-True (@($invalidResultRows | Where-Object repository -eq 'second-owner/two')[0].status -eq 'Current') 'A later installation should still report its successful result.'
        Remove-Item Env:\RQG_TEST_INVALID_FIRST -ErrorAction SilentlyContinue

        Remove-Item -LiteralPath $recordPath -Force
        $env:RQG_TEST_TOKEN_FAIL_FIRST = '1'
        $tokenFailure = $null
        try {
            Invoke-RepositoryQualityGateAppFleetUpdate -ApplicationId '12345' -PemPrivateKey $testRsa.ExportPkcs8PrivateKeyPem() -ResolvedTemplateRoot $testRoot -EnableAutoEnroll -EnableApply -EnableAutoMerge -ResolvedPrivateReportPath $privateReportPath -BranchLifetimeHours 24
        }
        catch { $tokenFailure = $_ }
        $tokenFailureRecords = @(Get-Content -LiteralPath $recordPath | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-True ($tokenFailure.Exception.Message -match '^1 GitHub App installation\(s\) failed after all accessible installations were processed\.') 'A token-issuance failure should produce the aggregate installation failure without a strict-mode cleanup error.'
        Assert-True ($tokenFailureRecords.Count -eq 1) 'A token-issuance failure must not prevent the later installation from running.'
        Assert-True ($tokenFailureRecords[0].repositories[0] -eq 'second-owner/two') 'The later installation should still be processed after an earlier token-issuance failure.'
        Remove-Item Env:\RQG_TEST_TOKEN_FAIL_FIRST -ErrorAction SilentlyContinue

        Remove-Item -LiteralPath $recordPath -Force
        $probeDigest = Get-RqgRepositoryNameSha256 'first-owner/one'
        Invoke-RepositoryQualityGateAppFleetUpdate -ApplicationId '12345' -PemPrivateKey $testRsa.ExportPkcs8PrivateKeyPem() -ResolvedTemplateRoot $testRoot -RepositoryCloneProbeSha256 $probeDigest -BranchLifetimeHours 24
        Assert-True ($script:cloneProbeRepositories.Count -eq 1 -and $script:cloneProbeRepositories[0] -eq 'first-owner/one') 'The clone probe should select exactly the repository matching the supplied digest.'
        Assert-True (-not (Test-Path -LiteralPath $recordPath)) 'The clone probe must not invoke the mutating fleet updater.'

        $missingProbeFailure = $null
        try {
            Invoke-RepositoryQualityGateAppFleetUpdate -ApplicationId '12345' -PemPrivateKey $testRsa.ExportPkcs8PrivateKeyPem() -ResolvedTemplateRoot $testRoot -RepositoryCloneProbeSha256 ('0' * 64) -BranchLifetimeHours 24
        }
        catch { $missingProbeFailure = $_ }
        Assert-True ($null -ne $missingProbeFailure -and $missingProbeFailure.Exception.Message -match 'No accessible GitHub App repository matched') 'A digest that matches no accessible repository should fail closed.'
    }
    finally {
        $testRsa.Dispose()
        Remove-Item Function:\global:Invoke-RestMethod -ErrorAction SilentlyContinue
        Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
        Remove-Item Function:\Invoke-RqgGitHubAppCloneProbe -ErrorAction SilentlyContinue
        Remove-Item Env:\RQG_TEST_RECORD_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:\RQG_TEST_FAIL_FIRST -ErrorAction SilentlyContinue
        Remove-Item Env:\RQG_TEST_INVALID_FIRST -ErrorAction SilentlyContinue
        Remove-Item Env:\RQG_TEST_TOKEN_FAIL_FIRST -ErrorAction SilentlyContinue
        if ($null -eq $oldRunnerName) { Remove-Item Env:\RUNNER_NAME -ErrorAction SilentlyContinue } else { $env:RUNNER_NAME = $oldRunnerName }
        if ($null -eq $oldToken) { Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue } else { $env:GH_TOKEN = $oldToken }
        if ($null -eq $oldGitConfigCount) { Remove-Item Env:\GIT_CONFIG_COUNT -ErrorAction SilentlyContinue } else { $env:GIT_CONFIG_COUNT = $oldGitConfigCount }
        if ($null -eq $oldGitConfigKey0) { Remove-Item Env:\GIT_CONFIG_KEY_0 -ErrorAction SilentlyContinue } else { $env:GIT_CONFIG_KEY_0 = $oldGitConfigKey0 }
        if ($null -eq $oldGitConfigValue0) { Remove-Item Env:\GIT_CONFIG_VALUE_0 -ErrorAction SilentlyContinue } else { $env:GIT_CONFIG_VALUE_0 = $oldGitConfigValue0 }
    }

    Write-Host "$passed assertions passed."
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

exit 0
