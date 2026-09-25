# SPDX-License-Identifier: MIT
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$appFleetTool = Join-Path $root 'scripts\Invoke-RepositoryQualityGateAppFleetUpdate.ps1'
$fleetWorkflow = Join-Path $root '.github\workflows\update-managed-repositories.yml'
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

    $appFleetText = Get-Content -LiteralPath $appFleetTool -Raw
    $workflowText = Get-Content -LiteralPath $fleetWorkflow -Raw
    Assert-True ($workflowText.Contains('timeout-minutes: 120')) 'The complete fleet rollout should allow up to 120 minutes.'
    Assert-True ($workflowText.Contains('name: Email Fleet Rollout Report')) 'The fleet workflow should send its configured completion report.'
    Assert-True ($workflowText.Contains('name: Preserve Fleet Rollout Report')) 'The updater should preserve its sanitized diagnostic report.'
    Assert-True (-not $workflowText.Contains('name: Retrieve Fleet Rollout Report')) 'The private email report must not pass through a downloadable artifact.'
    Assert-True (-not $workflowText.Contains('report_base64')) 'The detailed report should not use a secret-sensitive job output.'
    Assert-True ($workflowText.Contains("if (`$line -match '^::add-mask::(?<value>.+)`$')")) 'The report writer should recognize GitHub masking control lines.'
    Assert-True ($workflowText.Contains('$maskedValues.Add([string]$Matches.value)')) 'The report writer should retain every registered mask value in memory.'
    Assert-True ($workflowText.Contains("`$Line = `$Line.Replace(`$value, '***')")) 'The preserved report must replace masked credentials and private identifiers.'
    Assert-True ($workflowText.Contains('(ConvertTo-SanitizedReportLine $failure)')) 'Failure diagnostics must receive the same report sanitization.'
    Assert-True ($workflowText.Contains('actions/upload-artifact@330a01c490aca151604b8cf639adc76d48f6c5d4')) 'The report uploader should use the pinned Node.js 24 artifact action.'
    Assert-True (-not $workflowText.Contains('actions/download-artifact@')) 'The email-only repository table must not be downloaded from an artifact.'
    Assert-True ($workflowText.Contains('-PrivateReportPath $privateReportPath')) 'The App wrapper should receive a dedicated private report path.'
    Assert-True ($workflowText.Contains('PRIVATE_REPORT_PATH: ${{ github.workspace }}/.rqg-private/email-report.json')) 'The email step should read the private local report directly.'
    Assert-True ($workflowText.Contains('<table style=\"border-collapse:collapse;border:1px solid #999;width:100%\">')) 'The HTML email should outline the complete table.'
    Assert-True ($workflowText.Contains('<th style=\"border:1px solid #999;padding:6px;text-align:left;background:#f2f2f2\">Repository</th>')) 'The HTML email should contain a bordered Repository header.'
    Assert-True ($workflowText.Contains('<th style=\"border:1px solid #999;padding:6px;text-align:left;background:#f2f2f2\">Visibility</th>')) 'The HTML email should contain a bordered Visibility header.'
    Assert-True ($workflowText.Contains('<th style=\"border:1px solid #999;padding:6px;text-align:left;background:#f2f2f2\">Runner</th>')) 'The HTML email should contain a bordered Runner header.'
    Assert-True ($workflowText.Contains('<th style=\"border:1px solid #999;padding:6px;text-align:left;background:#f2f2f2\">Status</th>')) 'The HTML email should contain a bordered Status header.'
    Assert-True ($workflowText.Contains('<th style=\"border:1px solid #999;padding:6px;text-align:left;background:#f2f2f2\">Comment</th>')) 'The HTML email should contain a bordered Comment header.'
    Assert-True ($workflowText.Contains('<td style=\"border:1px solid #999;padding:6px;vertical-align:top\">')) 'Every HTML email data cell should have a visible border.'
    Assert-True ($workflowText.Contains('<h2>Status Summary</h2>')) 'The HTML email should include a status-count summary above the repository table.'
    Assert-True ($workflowText.Contains('Cloud Hub GitHub Repository Quality Gates')) 'The email should use the approved sender display name.'
    Assert-True ($workflowText.Contains('formataddr(("Terry Rogers", to_address))')) 'The email should use the approved recipient display name.'
    Assert-True ($workflowText.Contains("vars.RQG_REPORT_EMAIL_ENABLED == 'true'")) 'Email reporting should remain controlled by the repository variable.'
    Assert-True ($workflowText.Contains("steps.rollout.outcome == 'failure'")) 'A reported rollout failure should still fail the workflow.'

    Assert-True ((ConvertTo-RqgEmailComment -Status 'Current' -Detail '') -eq 'Already current.') 'Current repositories should use a short factual email comment.'
    Assert-True ((ConvertTo-RqgEmailComment -Status 'EmptyRepository' -Detail 'Long internal detail.') -eq 'Skipped: repository has no commits.') 'Empty repositories should use a short factual email comment.'
    Assert-True ((ConvertTo-RqgEmailComment -Status 'MergedCleanupRequired' -Detail 'Long cleanup detail.') -eq 'Update merged; temporary branch cleanup failed.') 'Cleanup failures should use a short factual email comment.'
    $checkFailureDetail = 'Stage: Pull-request quality checks. Cause: Pull-request quality checks failed: Build (failure), Build (failure), Require OP reference (failure) Context: Target RQG version: 1.5.4. Cleanup: Removed. Investigation: Review checks.'
    Assert-True ((ConvertTo-RqgEmailComment -Status 'Failed' -Detail $checkFailureDetail) -eq 'PR checks failed: Build; Require OP reference.') 'Failed check comments should be concise and deduplicate check names.'
    $generalFailureComment = ConvertTo-RqgEmailComment -Status 'Failed' -Detail 'Stage: Repository clone. Cause: Unable to clone the repository. Context: Target RQG version: 1.5.4. Cleanup: None. Investigation: Verify access.'
    Assert-True ($generalFailureComment -eq 'Repository clone failed: Unable to clone the repository.') 'Other failed comments should state only the failing stage and cause.'
    Assert-True ($generalFailureComment.Length -le 240) 'Email comments should remain concise.'

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
$status = if ($env:RQG_TEST_FAIL_FIRST -eq '1' -and $env:GH_TOKEN -eq 'installation-token-101') { 'Failed' } else { 'Current' }
$summary = [ordered]@{
    repositories = @($Repository | ForEach-Object { [pscustomobject]@{ repository = $_; status = $status; runners = if ($status -eq 'Failed') { @('rqg-win-one', 'rqg-linux-one') } else { @() }; detail = "Synthetic $status result. Token=$env:GH_TOKEN" } })
    failed = if ($status -eq 'Failed') { 1 } else { 0 }
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
        if ($joined -eq 'api --method DELETE /installation/token') {
            $global:LASTEXITCODE = 0
            return
        }
        throw "Unexpected gh invocation: $joined"
    }
    Assert-True ((Get-RqgRunnerDisplay ([pscustomobject]@{ status = 'Failed'; runners = @('rqg-win-test', 'rqg-linux-test') })) -eq 'rqg-linux-test, rqg-win-test') 'The email runner cell should list the downstream runners recorded by the repository result.'
    Assert-True ((Get-RqgRunnerDisplay ([pscustomobject]@{ status = 'Current' })) -eq 'Not Used') 'A result without executed checks should identify that no runner was used.'
    Assert-True ((Get-RqgRunnerDisplay ([pscustomobject]@{ status = 'Failed' })) -eq 'Unavailable') 'A failed result without runner metadata should remain explicit.'
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
        Assert-True (@($failureRows | Where-Object repository -eq 'first-owner/one')[0].status -eq 'Failed') 'The private report should retain a failed repository status.'
        Assert-True (@($failureRows | Where-Object repository -eq 'first-owner/one')[0].runner -eq 'rqg-linux-one, rqg-win-one') 'The private report should identify every downstream self-hosted runner used by the repository checks.'
        Assert-True (@($failureRows | Where-Object repository -eq 'first-owner/one')[0].comment -eq 'Failed: Synthetic Failed result. Token=***') 'A structured repository failure should provide a concise sanitized email comment.'
        Assert-True (@($failureRows | Where-Object repository -eq 'first-owner/one')[0].detail -eq 'Synthetic Failed result. Token=***') 'A structured repository failure should retain its complete sanitized diagnostic detail.'
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
        Assert-True (@($invalidResultRows | Where-Object repository -eq 'first-owner/one')[0].status -eq 'Failed') 'An invalid structured result should create a failed repository row.'
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
    }
    finally {
        $testRsa.Dispose()
        Remove-Item Function:\global:Invoke-RestMethod -ErrorAction SilentlyContinue
        Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
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
