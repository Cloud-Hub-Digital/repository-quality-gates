# SPDX-License-Identifier: MIT
[CmdletBinding()]
param(
    [string]$AppId = $env:RQG_APP_ID,
    [string]$PrivateKey = $env:RQG_APP_PRIVATE_KEY,
    [switch]$Apply,
    [string]$ResultPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$appHelper = Join-Path $PSScriptRoot 'Invoke-RepositoryQualityGateAppFleetUpdate.ps1'
$engine = Join-Path $PSScriptRoot 'Invoke-RepositoryRulesetEngine.ps1'
if (-not (Test-Path -LiteralPath $appHelper -PathType Leaf) -or -not (Test-Path -LiteralPath $engine -PathType Leaf)) { throw 'The ruleset App fleet dependencies are missing.' }
. $appHelper

$jwt = New-GitHubAppJwt $AppId $PrivateKey
Write-Host "::add-mask::$jwt"
$installations = @(Get-GitHubAppInstallations $jwt)
Remove-Variable jwt -ErrorAction SilentlyContinue
if (-not $installations.Count) { throw 'The GitHub App has no accessible installations.' }

$originalToken = $env:GH_TOKEN
$rows = [Collections.Generic.List[object]]::new()
$failures = 0
try {
    foreach ($installation in $installations) {
        $installationJwt = $null
        $token = $null
        try {
            $installationJwt = New-GitHubAppJwt $AppId $PrivateKey
            Write-Host "::add-mask::$installationJwt"
            $token = New-GitHubAppInstallationToken $installationJwt ([long]$installation.id)
            Write-Host "::add-mask::$token"
            $env:GH_TOKEN = $token
            $repositories = @(Get-GitHubAppInstallationRepositories $token | ForEach-Object { [string]$_.full_name } | Where-Object { $_ } | Sort-Object -Unique)
            if (-not $repositories.Count) { continue }
            $resultText = & $engine -Repository $repositories -Apply:$Apply -OutputFormat Json
            $result = $resultText | ConvertFrom-Json
            foreach ($row in @($result.repositories)) { $rows.Add($row) }
        }
        catch {
            $failures++
            Write-Warning 'A GitHub App installation could not complete ruleset reconciliation. Review the masked workflow error & App permissions.'
        }
        finally {
            if ($token) {
                $env:GH_TOKEN = $token
                $null = @(& gh api --method DELETE /installation/token 2>&1)
                if ($LASTEXITCODE -ne 0) { Write-Warning 'Unable to revoke a GitHub App installation token before its normal expiry.' }
            }
            if ($null -eq $originalToken) { Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue } else { $env:GH_TOKEN = $originalToken }
            Remove-Variable token -ErrorAction SilentlyContinue
            Remove-Variable installationJwt -ErrorAction SilentlyContinue
        }
    }
}
finally {
    if ($null -eq $originalToken) { Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue } else { $env:GH_TOKEN = $originalToken }
}

$result = [pscustomobject][ordered]@{
    schemaVersion = 1
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    mode = if ($Apply) { 'Apply' } else { 'Audit' }
    repositoryCount = $rows.Count
    compliant = @($rows | Where-Object status -in @('Compliant', 'AppliedAndVerified')).Count
    deferred = @($rows | Where-Object status -eq 'DeferredUnsupportedPlan').Count
    nonCompliant = @($rows | Where-Object status -in @('NonCompliant','MissingManagedState')).Count
    installationFailures = $failures
    repositories = @($rows | Sort-Object repository)
}
$json = $result | ConvertTo-Json -Depth 12
if ($ResultPath) {
    $resolved = [IO.Path]::GetFullPath($ResultPath)
    $parent = Split-Path -Parent $resolved
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllText($resolved, $json, [Text.UTF8Encoding]::new($false))
}
Write-Output "Ruleset reconciliation completed in $($result.mode) mode: $($result.repositoryCount) repositories, $($result.compliant) compliant, $($result.deferred) deferred, $($result.nonCompliant) non-compliant, $failures installation failures."
if ($failures -or ($Apply -and $result.nonCompliant)) { exit 1 }
