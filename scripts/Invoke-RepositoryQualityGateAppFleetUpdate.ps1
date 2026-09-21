# SPDX-License-Identifier: MIT
[CmdletBinding()]
param(
    [string]$AppId = $env:RQG_APP_ID,
    [string]$PrivateKey = $env:RQG_APP_PRIVATE_KEY,
    [string]$TemplateRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$AutoEnroll,
    [switch]$Apply,
    [switch]$AutoMerge,
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

function Invoke-RepositoryQualityGateAppFleetUpdate {
    param(
        [string]$ApplicationId,
        [string]$PemPrivateKey,
        [string]$ResolvedTemplateRoot,
        [switch]$EnableAutoEnroll,
        [switch]$EnableApply,
        [switch]$EnableAutoMerge,
        [int]$BranchLifetimeHours
    )

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI is required.' }
    $fleetTool = Join-Path ([IO.Path]::GetFullPath($ResolvedTemplateRoot)) 'scripts\Invoke-RepositoryQualityGateFleetUpdate.ps1'
    if (-not (Test-Path -LiteralPath $fleetTool -PathType Leaf)) { throw 'The fleet updater is missing.' }

    $jwt = New-GitHubAppJwt $ApplicationId $PemPrivateKey
    $installations = @(Get-GitHubAppInstallations $jwt)
    if (-not $installations.Count) { throw 'The GitHub App has no accessible installations.' }

    $originalToken = $env:GH_TOKEN
    try {
        foreach ($installation in $installations) {
            $token = New-GitHubAppInstallationToken $jwt ([long]$installation.id)
            try {
                $env:GH_TOKEN = $token
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
                }
                if ($EnableAutoEnroll) { $fleetArguments.AutoEnroll = $true }
                if ($EnableApply) { $fleetArguments.Apply = $true }
                if ($EnableAutoMerge) { $fleetArguments.AutoMerge = $true }
                & $fleetTool @fleetArguments
            }
            finally {
                if ($env:GH_TOKEN) {
                    $null = @(& gh api --method DELETE /installation/token 2>&1)
                    if ($LASTEXITCODE -ne 0) { Write-Warning 'Unable to revoke a GitHub App installation token before its normal expiry.' }
                }
                Remove-Variable token -ErrorAction SilentlyContinue
            }
        }
    }
    finally {
        if ($null -eq $originalToken) { Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue }
        else { $env:GH_TOKEN = $originalToken }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-RepositoryQualityGateAppFleetUpdate -ApplicationId $AppId -PemPrivateKey $PrivateKey -ResolvedTemplateRoot $TemplateRoot -EnableAutoEnroll:$AutoEnroll -EnableApply:$Apply -EnableAutoMerge:$AutoMerge -BranchLifetimeHours $TemporaryBranchLifetimeHours
}
