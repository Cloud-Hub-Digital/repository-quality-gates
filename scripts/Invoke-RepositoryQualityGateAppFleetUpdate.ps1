# SPDX-License-Identifier: MIT
[CmdletBinding()]
param(
    [string]$AppId = $env:RQG_APP_ID,
    [string]$PrivateKey = $env:RQG_APP_PRIVATE_KEY,
    [string]$TemplateRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$AutoEnroll,
    [switch]$Apply,
    [switch]$AutoMerge,
    [string]$PrivateReportPath,
    [ValidateRange(1, 168)][int]$TemporaryBranchLifetimeHours = 24
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-Base64Url([byte[]]$Bytes) {
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-GitHubAppJwt([string]$ApplicationId, [string]$PemPrivateKey) {
    if ($ApplicationId -notmatch '^[1-9]\d*$') { throw 'RQG_APP_ID must be a positive numeric GitHub App ID.' }
    if ([string]::IsNullOrWhiteSpace($PemPrivateKey)) { throw 'RQG_APP_PRIVATE_KEY must contain the GitHub App private key.' }

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes('{"alg":"RS256","typ":"JWT"}'))
    $payloadObject = [ordered]@{ iat = $now - 60; exp = $now + 540; iss = $ApplicationId }
    $payload = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes(($payloadObject | ConvertTo-Json -Compress)))
    $unsignedToken = "$header.$payload"

    $rsa = [Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportFromPem($PemPrivateKey)
        $signature = $rsa.SignData(
            [Text.Encoding]::UTF8.GetBytes($unsignedToken),
            [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.RSASignaturePadding]::Pkcs1
        )
    }
    catch { throw 'Unable to use the configured GitHub App private key.' }
    finally { $rsa.Dispose() }

    return "$unsignedToken.$(ConvertTo-Base64Url $signature)"
}

function Get-GitHubAppInstallations([string]$Jwt) {
    $headers = @{
        Accept = 'application/vnd.github+json'
        Authorization = "Bearer $Jwt"
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $all = [Collections.Generic.List[object]]::new()
    for ($page = 1; ; $page++) {
        # Invoke-RestMethod deliberately returns JSON arrays without enumerating
        # them. Capture the response first so @() normalizes both a JSON array
        # and a single installation into the same flat collection.
        $response = Invoke-RestMethod -Method Get -Uri "https://api.github.com/app/installations?per_page=100&page=$page" -Headers $headers
        $batch = @($response)
        foreach ($installation in $batch) { $all.Add($installation) }
        if ($batch.Count -lt 100) { break }
    }
    return @($all)
}

function New-GitHubAppInstallationToken([string]$Jwt, [long]$InstallationId) {
    if ($InstallationId -le 0) { throw 'GitHub returned an invalid App installation ID.' }
    $headers = @{
        Accept = 'application/vnd.github+json'
        Authorization = "Bearer $Jwt"
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $response = Invoke-RestMethod -Method Post -Uri "https://api.github.com/app/installations/$InstallationId/access_tokens" -Headers $headers -ContentType 'application/json'
    if (-not $response.token) { throw 'GitHub did not return an installation token.' }
    return [string]$response.token
}

function New-RqgInstallationFailureComment([string]$Stage, [string]$Cause) {
    $action = switch -Regex ($Stage) {
        '^Installation authentication' { 'Verify the GitHub App ID, private-key secret, installation state, and permission grants, then rerun the fleet workflow.' }
        '^Repository discovery' { 'Verify the GitHub App installation can list its selected repositories and that repository access has not been suspended or removed, then rerun.' }
        '^Fleet execution' { 'Review the per-repository rows in this email first. For any repository without a structured row, inspect the sanitized workflow artifact and the fleet job log for the earliest reported failure.' }
        '^Structured result processing' { 'Inspect the sanitized workflow artifact for the installation-level error, confirm the fleet result file is valid JSON, and rerun after correcting the producer failure.' }
        default { 'Inspect the sanitized workflow artifact and the fleet job log, correct the installation-level blocker, and rerun the workflow.' }
    }
    return "Stage: $Stage. Cause: $Cause Investigation: $action"
}

function Invoke-RepositoryQualityGateAppFleetUpdate {
    param(
        [string]$ApplicationId,
        [string]$PemPrivateKey,
        [string]$ResolvedTemplateRoot,
        [switch]$EnableAutoEnroll,
        [switch]$EnableApply,
        [switch]$EnableAutoMerge,
        [string]$ResolvedPrivateReportPath,
        [int]$BranchLifetimeHours
    )

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI is required.' }
    $fleetTool = Join-Path ([IO.Path]::GetFullPath($ResolvedTemplateRoot)) 'scripts\Invoke-RepositoryQualityGateFleetUpdate.ps1'
    if (-not (Test-Path -LiteralPath $fleetTool -PathType Leaf)) { throw 'The fleet updater is missing.' }

    $jwt = New-GitHubAppJwt $ApplicationId $PemPrivateKey
    $installations = @(Get-GitHubAppInstallations $jwt)
    if (-not $installations.Count) { throw 'The GitHub App has no accessible installations.' }

    $originalToken = $env:GH_TOKEN
    $originalGitConfigCount = $env:GIT_CONFIG_COUNT
    $originalGitConfigKey0 = $env:GIT_CONFIG_KEY_0
    $originalGitConfigValue0 = $env:GIT_CONFIG_VALUE_0
    $installationFailureCount = 0
    $privateReportRows = [Collections.Generic.List[object]]::new()
    try {
        foreach ($installation in $installations) {
            $token = $null
            $repositories = @()
            $installationResultPath = [IO.Path]::GetTempFileName()
            $installationRowsAdded = 0
            $installationFailureComment = $null
            $installationFailed = $false
            $installationStage = 'Installation authentication'
            try {
                $token = New-GitHubAppInstallationToken $jwt ([long]$installation.id)
                $env:GH_TOKEN = $token
                $basicCredential = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("x-access-token:$token"))
                $authorizationHeader = "AUTHORIZATION: basic $basicCredential"
                Write-Host "::add-mask::$token"
                Write-Host "::add-mask::$authorizationHeader"
                $env:GIT_CONFIG_COUNT = '1'
                $env:GIT_CONFIG_KEY_0 = 'http.https://github.com/.extraheader'
                $env:GIT_CONFIG_VALUE_0 = $authorizationHeader
                $installationStage = 'Repository discovery'
                $repositories = @(& gh api --paginate /installation/repositories --jq '.repositories[].full_name' 2>$null | Where-Object { $_ } | Sort-Object -Unique)
                if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate repositories for a GitHub App installation.' }
                foreach ($repositoryName in $repositories) {
                    if ($repositoryName -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'GitHub returned an invalid repository name.' }
                    Write-Host "::add-mask::$repositoryName"
                    Write-Host "::add-mask::$($repositoryName.Split('/')[0])"
                }
                if (-not $repositories.Count) { continue }

                $fleetArguments = @{
                    Repository = $repositories
                    TemplateRoot = $ResolvedTemplateRoot
                    TemporaryBranchLifetimeHours = $BranchLifetimeHours
                    OutputFormat = 'Json'
                    ResultPath = $installationResultPath
                }
                if ($EnableAutoEnroll) { $fleetArguments.AutoEnroll = $true }
                if ($EnableApply) { $fleetArguments.Apply = $true }
                if ($EnableAutoMerge) { $fleetArguments.AutoMerge = $true }
                $installationStage = 'Fleet execution'
                & $fleetTool @fleetArguments
            }
            catch {
                $installationFailureCount++
                $installationFailed = $true
                $installationFailureComment = New-RqgInstallationFailureComment -Stage $installationStage -Cause $_.Exception.Message
                Write-Warning 'A GitHub App installation failed; processing will continue with the remaining installations.'
            }
            finally {
                try {
                    if (Test-Path -LiteralPath $installationResultPath -PathType Leaf) {
                        $resultBytes = [IO.File]::ReadAllText($installationResultPath)
                        if (-not [string]::IsNullOrWhiteSpace($resultBytes)) {
                            $installationResult = $resultBytes | ConvertFrom-Json
                            foreach ($repositoryResult in @($installationResult.repositories)) {
                                $privateComment = [string]$repositoryResult.detail
                                foreach ($secretValue in @($token, $authorizationHeader, $basicCredential)) {
                                    if (-not [string]::IsNullOrWhiteSpace([string]$secretValue)) {
                                        $privateComment = $privateComment.Replace([string]$secretValue, '***')
                                    }
                                }
                                $privateReportRows.Add([pscustomobject][ordered]@{
                                    repository = [string]$repositoryResult.repository
                                    status = [string]$repositoryResult.status
                                    comment = $privateComment
                                })
                                $installationRowsAdded++
                            }
                        }
                    }
                }
                catch {
                    if (-not $installationFailed) {
                        $installationFailureCount++
                        $installationFailed = $true
                    }
                    $installationFailureComment = New-RqgInstallationFailureComment -Stage 'Structured result processing' -Cause $_.Exception.Message
                    Write-Warning 'A GitHub App installation produced an invalid structured result; processing will continue with the remaining installations.'
                }
                finally {
                    Remove-Item -LiteralPath $installationResultPath -Force -ErrorAction SilentlyContinue
                }
                if ($installationFailureComment -and $installationRowsAdded -eq 0) {
                    foreach ($secretValue in @($token, $authorizationHeader, $basicCredential)) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$secretValue)) {
                            $installationFailureComment = $installationFailureComment.Replace([string]$secretValue, '***')
                        }
                    }
                    foreach ($repositoryName in $repositories) {
                        $privateReportRows.Add([pscustomobject][ordered]@{
                            repository = [string]$repositoryName
                            status = 'Failed'
                            comment = [string]$installationFailureComment
                        })
                    }
                }
                if (-not [string]::IsNullOrWhiteSpace($token)) {
                    $env:GH_TOKEN = $token
                    $null = @(& gh api --method DELETE /installation/token 2>&1)
                    if ($LASTEXITCODE -ne 0) { Write-Warning 'Unable to revoke a GitHub App installation token before its normal expiry.' }
                }
                if ($null -eq $originalToken) { Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue }
                else { $env:GH_TOKEN = $originalToken }
                if ($null -eq $originalGitConfigCount) { Remove-Item Env:\GIT_CONFIG_COUNT -ErrorAction SilentlyContinue }
                else { $env:GIT_CONFIG_COUNT = $originalGitConfigCount }
                if ($null -eq $originalGitConfigKey0) { Remove-Item Env:\GIT_CONFIG_KEY_0 -ErrorAction SilentlyContinue }
                else { $env:GIT_CONFIG_KEY_0 = $originalGitConfigKey0 }
                if ($null -eq $originalGitConfigValue0) { Remove-Item Env:\GIT_CONFIG_VALUE_0 -ErrorAction SilentlyContinue }
                else { $env:GIT_CONFIG_VALUE_0 = $originalGitConfigValue0 }
                Remove-Variable token -ErrorAction SilentlyContinue
                Remove-Variable basicCredential -ErrorAction SilentlyContinue
                Remove-Variable authorizationHeader -ErrorAction SilentlyContinue
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($ResolvedPrivateReportPath)) {
            $resolvedReportPath = [IO.Path]::GetFullPath($ResolvedPrivateReportPath)
            $reportParent = Split-Path -Parent $resolvedReportPath
            if (-not (Test-Path -LiteralPath $reportParent -PathType Container)) { throw 'The private report parent directory does not exist.' }
            $reportJson = ConvertTo-Json -InputObject @($privateReportRows | Sort-Object repository) -Depth 4
            [IO.File]::WriteAllText($resolvedReportPath, $reportJson, [Text.UTF8Encoding]::new($false))
        }
        if ($installationFailureCount) {
            throw "$installationFailureCount GitHub App installation(s) failed after all accessible installations were processed. Review the masked per-repository results above."
        }
    }
    finally {
        if ($null -eq $originalToken) { Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue }
        else { $env:GH_TOKEN = $originalToken }
        if ($null -eq $originalGitConfigCount) { Remove-Item Env:\GIT_CONFIG_COUNT -ErrorAction SilentlyContinue }
        else { $env:GIT_CONFIG_COUNT = $originalGitConfigCount }
        if ($null -eq $originalGitConfigKey0) { Remove-Item Env:\GIT_CONFIG_KEY_0 -ErrorAction SilentlyContinue }
        else { $env:GIT_CONFIG_KEY_0 = $originalGitConfigKey0 }
        if ($null -eq $originalGitConfigValue0) { Remove-Item Env:\GIT_CONFIG_VALUE_0 -ErrorAction SilentlyContinue }
        else { $env:GIT_CONFIG_VALUE_0 = $originalGitConfigValue0 }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-RepositoryQualityGateAppFleetUpdate -ApplicationId $AppId -PemPrivateKey $PrivateKey -ResolvedTemplateRoot $TemplateRoot -EnableAutoEnroll:$AutoEnroll -EnableApply:$Apply -EnableAutoMerge:$AutoMerge -ResolvedPrivateReportPath $PrivateReportPath -BranchLifetimeHours $TemporaryBranchLifetimeHours
}
