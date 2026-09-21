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

    $workflowText = Get-Content -LiteralPath $fleetWorkflow -Raw
    Assert-True ($workflowText.Contains('timeout-minutes: 120')) 'The complete fleet rollout should allow up to 120 minutes.'
    Assert-True ($workflowText.Contains('name: Email Fleet Rollout Report')) 'The fleet workflow should send its configured completion report.'
    Assert-True ($workflowText.Contains("vars.RQG_REPORT_EMAIL_ENABLED == 'true'")) 'Email reporting should remain controlled by the repository variable.'
    Assert-True ($workflowText.Contains("steps.rollout.outcome == 'failure'")) 'A reported rollout failure should still fail the workflow.'

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
param([string[]]$Repository, [string]$TemplateRoot, [switch]$AutoEnroll, [switch]$Apply, [switch]$AutoMerge, [int]$TemporaryBranchLifetimeHours)
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
if ($env:RQG_TEST_FAIL_FIRST -eq '1' -and $env:GH_TOKEN -eq 'installation-token-101') { throw 'Synthetic first-installation failure.' }
'@
    [IO.File]::WriteAllText((Join-Path $testRoot 'scripts\Invoke-RepositoryQualityGateFleetUpdate.ps1'), $fakeFleet, [Text.UTF8Encoding]::new($false))

    function global:Invoke-RestMethod {
        param([string]$Method, [string]$Uri, [hashtable]$Headers, [string]$ContentType)
        if ($Method -eq 'Get' -and $Uri -match '/app/installations\?') {
            # Match Invoke-RestMethod's real treatment of a top-level JSON array:
            # one non-enumerated response object containing both installations.
            Write-Output -NoEnumerate @([pscustomobject]@{ id = 101 }, [pscustomobject]@{ id = 202 })
            return
        }
        if ($Method -eq 'Post' -and $Uri -match '/app/installations/(?<id>\d+)/access_tokens$') {
            return [pscustomobject]@{ token = "installation-token-$($Matches.id)" }
        }
        throw "Unexpected Invoke-RestMethod request: $Method $Uri"
    }
    function global:gh {
        $joined = $args -join ' '
        if ($joined -match '^api --paginate /installation/repositories') {
            if ($env:GH_TOKEN -eq 'installation-token-101') { 'first-owner/one' }
            elseif ($env:GH_TOKEN -eq 'installation-token-202') { 'second-owner/two' }
            else { throw 'The installation token was not selected before repository discovery.' }
            $global:LASTEXITCODE = 0
            return
        }
        if ($joined -eq 'api --method DELETE /installation/token') {
            $global:LASTEXITCODE = 0
            return
        }
        throw "Unexpected gh invocation: $joined"
    }

    $testRsa = [Security.Cryptography.RSA]::Create(2048)
    $oldToken = $env:GH_TOKEN
    $oldGitConfigCount = $env:GIT_CONFIG_COUNT
    $oldGitConfigKey0 = $env:GIT_CONFIG_KEY_0
    $oldGitConfigValue0 = $env:GIT_CONFIG_VALUE_0
    $env:GIT_CONFIG_COUNT = '7'
    $env:GIT_CONFIG_KEY_0 = 'test.original.key'
    $env:GIT_CONFIG_VALUE_0 = 'test-original-value'
    $env:RQG_TEST_RECORD_PATH = $recordPath
    try {
        Invoke-RepositoryQualityGateAppFleetUpdate -ApplicationId '12345' -PemPrivateKey $testRsa.ExportPkcs8PrivateKeyPem() -ResolvedTemplateRoot $testRoot -EnableAutoEnroll -EnableApply -EnableAutoMerge -BranchLifetimeHours 24
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

        Remove-Item -LiteralPath $recordPath -Force
        $env:RQG_TEST_FAIL_FIRST = '1'
        $aggregateFailure = $null
        try {
            Invoke-RepositoryQualityGateAppFleetUpdate -ApplicationId '12345' -PemPrivateKey $testRsa.ExportPkcs8PrivateKeyPem() -ResolvedTemplateRoot $testRoot -EnableAutoEnroll -EnableApply -EnableAutoMerge -BranchLifetimeHours 24
        }
        catch { $aggregateFailure = $_ }
        $failureRecords = @(Get-Content -LiteralPath $recordPath | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-True ($null -ne $aggregateFailure) 'An installation failure should make the complete App fleet run fail after processing finishes.'
        Assert-True ($aggregateFailure.Exception.Message -match '^1 GitHub App installation\(s\) failed after all accessible installations were processed\.') 'The final error should report the aggregate installation failure count.'
        Assert-True ($failureRecords.Count -eq 2) 'A failed installation must not prevent a later installation from running.'
        Assert-True ($failureRecords[1].repositories[0] -eq 'second-owner/two') 'The later installation should still receive its repository list after an earlier failure.'
        Remove-Item Env:\RQG_TEST_FAIL_FIRST -ErrorAction SilentlyContinue
    }
    finally {
        $testRsa.Dispose()
        Remove-Item Function:\global:Invoke-RestMethod -ErrorAction SilentlyContinue
        Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
        Remove-Item Env:\RQG_TEST_RECORD_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:\RQG_TEST_FAIL_FIRST -ErrorAction SilentlyContinue
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
