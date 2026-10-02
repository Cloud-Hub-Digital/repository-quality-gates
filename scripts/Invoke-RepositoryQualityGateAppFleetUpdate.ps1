# SPDX-License-Identifier: MIT
[CmdletBinding()]
param(
    [string]$AppId = $env:RQG_APP_ID,
    [string]$PrivateKey = $env:RQG_APP_PRIVATE_KEY,
    [string]$TemplateRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$AutoEnroll,
    [switch]$Apply,
    [switch]$AutoMerge,
    [ValidateRange(1, 100)][int]$WaveCount = 1,
    [ValidateRange(0, 99)][int]$WaveIndex = 0,
    [ValidatePattern('^[a-f0-9]{64}$')][string]$CloneProbeRepositorySha256,
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

function Get-GitHubAppInstallationRepositories([string]$Token) {
    if ([string]::IsNullOrWhiteSpace($Token)) { throw 'The GitHub App installation token is empty.' }
    $headers = @{
        Accept = 'application/vnd.github+json'
        Authorization = "Bearer $Token"
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $all = [Collections.Generic.List[object]]::new()
    for ($page = 1; ; $page++) {
        $response = Invoke-RestMethod -Method Get -Uri "https://api.github.com/installation/repositories?per_page=100&page=$page" -Headers $headers
        $batch = @($response.repositories)
        foreach ($repository in $batch) { $all.Add($repository) }
        if ($batch.Count -lt 100) { break }
    }
    return @($all)
}

function Get-RqgRepositoryNameSha256([string]$RepositoryName) {
    if ($RepositoryName -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'The repository name is invalid.' }
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        return ([Convert]::ToHexString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($RepositoryName.ToLowerInvariant())))).ToLowerInvariant()
    }
    finally { $hasher.Dispose() }
}

function Invoke-RqgGitHubAppCloneProbe([string]$RepositoryName, [string]$Destination) {
    & git clone --quiet --single-branch -- "https://github.com/$RepositoryName.git" $Destination
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $Destination '.git') -PathType Container)) {
        throw 'The GitHub App repository clone probe failed.'
    }
    $head = (& git -C $Destination rev-parse HEAD 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[a-f0-9]{40}$') { throw 'The cloned repository HEAD could not be verified.' }
    return $head
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

function Get-RqgInstallationFailureStatus([string]$Stage) {
    switch -Regex ($Stage) {
        '^Installation authentication' { return 'InstallationAuthenticationFailed' }
        '^Repository discovery' { return 'RepositoryDiscoveryFailed' }
        '^Structured result processing' { return 'ResultProcessingFailed' }
        default { return 'FleetExecutionFailed' }
    }
}

function Get-RqgStructuredFailureSummary([string]$Detail) {
    $summary = $null
    if ($Detail -match '^Stage:\s*(?<stage>.+?)\.\s+Cause:\s*(?<cause>.+?)(?:\s+Context:|\s+Cleanup:|\s+Investigation:|$)') {
        $summary = "$([string]$Matches.stage) failed: $([string]$Matches.cause)"
    }
    elseif ($Detail) { $summary = $Detail }
    else { $summary = 'No diagnostic summary was available.' }
    if ($summary.Length -gt 240) { return $summary.Substring(0, 237).TrimEnd() + '...' }
    return $summary
}

function Get-RqgCheckFailureSummary([string]$Detail, [string]$Prefix) {
    if ($Detail -match 'Cause:\s*Pull-request quality checks failed:\s*(?<checks>.+?)(?:\s+Context:|\s+Cleanup:|\s+Investigation:|$)') {
        $checkNames = [Collections.Generic.List[string]]::new()
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($match in [regex]::Matches([string]$Matches.checks, '(?<name>.*?)(?:\s+\([^)]+\))(?:,\s*|$)')) {
            $name = ([string]$match.Groups['name'].Value).Trim()
            if ($name -and $seen.Add($name)) { $checkNames.Add($name) }
        }
        if ($checkNames.Count) {
            $shown = @($checkNames | Select-Object -First 4)
            $remaining = $checkNames.Count - $shown.Count
            $suffix = if ($remaining -gt 0) { "; +$remaining more" } else { '' }
            return "$Prefix$($shown -join '; ')$suffix."
        }
    }
    return Get-RqgStructuredFailureSummary $Detail
}

function ConvertTo-RqgEmailComment([string]$Status, [string]$Detail) {
    $cleanDetail = [regex]::Replace(([string]$Detail).Trim(), '\s+', ' ')

    if ($Status -eq 'RequiresLicenceDecision') { return 'Licence decision requires approval or correction.' }
    if ($Status -eq 'ManagedFileConflict') { return 'Managed-file conflict requires review.' }
    if ($Status -eq 'FailedChecks') { return Get-RqgCheckFailureSummary -Detail $cleanDetail -Prefix 'PR checks failed: ' }
    if ($Status -eq 'MergedWithFailedChecks') { return Get-RqgCheckFailureSummary -Detail $cleanDetail -Prefix 'Update merged with failed checks: ' }
    if ($Status -match 'Failed$' -or $Status -eq 'MergeOutcomeUnverified') { return Get-RqgStructuredFailureSummary $cleanDetail }

    switch ($Status) {
        'Current' { return 'Already current.' }
        'EmptyRepository' { return 'Skipped: repository has no commits.' }
        'EnrollmentOptOut' { return 'Skipped: automatic enrolment is disabled.' }
        'ChecksPending' { return 'Update pull request created; checks pending.' }
        'PullRequest' { return 'Update pull request created.' }
        'EnrollmentAvailable' { return 'Automatic enrolment is available.' }
        'Available' { return 'Update is available.' }
        'MergedCleanupRequired' { return 'Update merged; temporary branch cleanup failed.' }
        'UpdatedSuccessfully' {
            if ($cleanDetail -match '(?<count>[0-9]+) reported quality check\(s\) passed') {
                return "$($Matches.count) quality checks passed; update merged."
            }
            return 'Quality checks passed; update merged.'
        }
        'DeferredOpenPullRequests' {
            if ($cleanDetail -match '^(?<count>[0-9]+) (?:open )?pull request\(s\)') {
                return "Deferred: $($Matches.count) open pull requests."
            }
            return 'Deferred: open pull requests require attention.'
        }
        default {
            if (-not $cleanDetail) { return $Status }
            if ($cleanDetail.Length -gt 240) { return $cleanDetail.Substring(0, 237).TrimEnd() + '...' }
            return $cleanDetail
        }
    }
}

function Get-RqgRunnerDisplay([object]$RepositoryResult) {
    [string[]]$runnerNames = @()
    if ($RepositoryResult.PSObject.Properties['runners']) {
        $runnerNames = @($RepositoryResult.runners | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Sort-Object -Unique)
    }
    if ($runnerNames.Count) { return $runnerNames -join [Environment]::NewLine }
    if ([string]$RepositoryResult.status -in @('Current', 'EmptyRepository', 'EnrollmentOptOut', 'DeferredOpenPullRequests', 'EnrollmentAvailable', 'Available')) { return 'Not Used' }
    return 'Unavailable'
}

function Get-RqgRepositoryWave([string]$RepositoryName, [ValidateRange(1, 100)][int]$Count) {
    # Hash-based membership is independent of discovery order or other repositories.
    $digest = Get-RqgRepositoryNameSha256 $RepositoryName.ToLowerInvariant()
    return [int]([Convert]::ToUInt32($digest.Substring(0, 8), 16) % $Count)
}

function Invoke-RepositoryQualityGateAppFleetUpdate {
    param(
        [string]$ApplicationId,
        [string]$PemPrivateKey,
        [string]$ResolvedTemplateRoot,
        [switch]$EnableAutoEnroll,
        [switch]$EnableApply,
        [switch]$EnableAutoMerge,
        [ValidateRange(1, 100)][int]$SelectedWaveCount = 1,
        [ValidateRange(0, 99)][int]$SelectedWaveIndex = 0,
        [string]$RepositoryCloneProbeSha256,
        [string]$ResolvedPrivateReportPath,
        [int]$BranchLifetimeHours
    )

    if ($SelectedWaveIndex -ge $SelectedWaveCount) { throw 'Wave index must be smaller than wave count.' }
    if ($RepositoryCloneProbeSha256 -and ($SelectedWaveCount -ne 1 -or $SelectedWaveIndex -ne 0)) { throw 'Clone probes cannot be combined with rollout waves.' }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI is required.' }
    $fleetTool = Join-Path ([IO.Path]::GetFullPath($ResolvedTemplateRoot)) 'scripts\Invoke-RepositoryQualityGateFleetUpdate.ps1'
    if (-not (Test-Path -LiteralPath $fleetTool -PathType Leaf)) { throw 'The fleet updater is missing.' }

    $discoveryJwt = New-GitHubAppJwt $ApplicationId $PemPrivateKey
    Write-Host "::add-mask::$discoveryJwt"
    $installations = @(Get-GitHubAppInstallations $discoveryJwt)
    Remove-Variable discoveryJwt -ErrorAction SilentlyContinue
    if (-not $installations.Count) { throw 'The GitHub App has no accessible installations.' }

    $originalToken = $env:GH_TOKEN
    $originalGitConfigCount = $env:GIT_CONFIG_COUNT
    $originalGitConfigKey0 = $env:GIT_CONFIG_KEY_0
    $originalGitConfigValue0 = $env:GIT_CONFIG_VALUE_0
    $installationFailureCount = 0
    $cloneProbeMatched = $false
    $privateReportRows = [Collections.Generic.List[object]]::new()
    try {
        foreach ($installation in $installations) {
            if ($cloneProbeMatched) { break }
            $installationJwt = $null
            $token = $null
            $basicCredential = $null
            $authorizationHeader = $null
            $repositories = @()
            $repositoryMetadata = @{}
            $installationResultPath = [IO.Path]::GetTempFileName()
            $installationRowsAdded = 0
            $installationFailureComment = $null
            $installationFailureStatus = $null
            $installationFailed = $false
            $installationStage = 'Installation authentication'
            try {
                $installationOwner = [string]$installation.account.login
                if ($installationOwner) { Write-Host "::add-mask::$installationOwner" }
                # GitHub App JWTs are valid for at most ten minutes. A fleet can
                # spend hours processing one installation, so create a fresh JWT
                # immediately before requesting each installation token.
                $installationJwt = New-GitHubAppJwt $ApplicationId $PemPrivateKey
                Write-Host "::add-mask::$installationJwt"
                $token = New-GitHubAppInstallationToken $installationJwt ([long]$installation.id)
                $env:GH_TOKEN = $token
                $basicCredential = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("x-access-token:$token"))
                $authorizationHeader = "AUTHORIZATION: basic $basicCredential"
                Write-Host "::add-mask::$token"
                Write-Host "::add-mask::$authorizationHeader"
                $env:GIT_CONFIG_COUNT = '1'
                $env:GIT_CONFIG_KEY_0 = 'http.https://github.com/.extraheader'
                $env:GIT_CONFIG_VALUE_0 = $authorizationHeader
                $installationStage = 'Repository discovery'
                $discoveredRepositories = @(Get-GitHubAppInstallationRepositories $token)
                foreach ($repository in $discoveredRepositories) {
                    $repositoryName = [string]$repository.full_name
                    if ($repositoryName -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'GitHub returned an invalid repository name.' }
                    $repositoryMetadata[$repositoryName] = [pscustomobject]@{
                        visibility = if ([bool]$repository.private) { 'Private' } else { 'Public' }
                    }
                    Write-Host "::add-mask::$repositoryName"
                    Write-Host "::add-mask::$($repositoryName.Split('/')[0])"
                }
                $repositories = @($repositoryMetadata.Keys | Sort-Object -Unique)
                if (-not $repositories.Count) { continue }

                if (-not [string]::IsNullOrWhiteSpace($RepositoryCloneProbeSha256)) {
                    $matchingRepositories = @($repositories | Where-Object {
                        (Get-RqgRepositoryNameSha256 ([string]$_)) -eq $RepositoryCloneProbeSha256
                    })
                    if ($matchingRepositories.Count -gt 1) { throw 'The repository clone-probe digest matched more than one accessible repository.' }
                    if ($matchingRepositories.Count -eq 0) { continue }

                    $cloneProbeMatched = $true
                    $probeRepository = [string]$matchingRepositories[0]
                    $probeDirectory = Join-Path ([IO.Path]::GetTempPath()) ("rqg-app-clone-probe-" + [Guid]::NewGuid().ToString('N'))
                    try {
                        $null = Invoke-RqgGitHubAppCloneProbe -RepositoryName $probeRepository -Destination $probeDirectory
                        Write-Host 'GitHub App repository clone probe passed.'
                    }
                    finally {
                        Remove-Item -LiteralPath $probeDirectory -Recurse -Force -ErrorAction SilentlyContinue
                        if (Test-Path -LiteralPath $probeDirectory) { throw 'The GitHub App repository clone-probe cleanup failed.' }
                    }
                    continue
                }

                $repositories = @($repositories | Where-Object {
                    (Get-RqgRepositoryWave ([string]$_) $SelectedWaveCount) -eq $SelectedWaveIndex
                })
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
                $installationFailureStatus = Get-RqgInstallationFailureStatus $installationStage
                $installationFailureComment = New-RqgInstallationFailureComment -Stage $installationStage -Cause $_.Exception.Message
                $maskedInstallationFailureComment = $installationFailureComment
                foreach ($secretValue in @($installationJwt, $token, $authorizationHeader, $basicCredential)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$secretValue)) {
                        $maskedInstallationFailureComment = $maskedInstallationFailureComment.Replace([string]$secretValue, '***')
                    }
                }
                Write-Warning "A GitHub App installation failed: $maskedInstallationFailureComment Processing will continue with the remaining installations."
            }
            finally {
                try {
                    if (Test-Path -LiteralPath $installationResultPath -PathType Leaf) {
                        $resultBytes = [IO.File]::ReadAllText($installationResultPath)
                        if (-not [string]::IsNullOrWhiteSpace($resultBytes)) {
                            $installationResult = $resultBytes | ConvertFrom-Json
                            foreach ($repositoryResult in @($installationResult.repositories)) {
                                $privateDetail = [string]$repositoryResult.detail
                                foreach ($secretValue in @($installationJwt, $token, $authorizationHeader, $basicCredential)) {
                                    if (-not [string]::IsNullOrWhiteSpace([string]$secretValue)) {
                                        $privateDetail = $privateDetail.Replace([string]$secretValue, '***')
                                    }
                                }
                                $privateReportRows.Add([pscustomobject][ordered]@{
                                    repository = [string]$repositoryResult.repository
                                    visibility = [string]$repositoryMetadata[[string]$repositoryResult.repository].visibility
                                    runner = Get-RqgRunnerDisplay $repositoryResult
                                    status = [string]$repositoryResult.status
                                    comment = ConvertTo-RqgEmailComment -Status ([string]$repositoryResult.status) -Detail $privateDetail
                                    detail = $privateDetail
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
                    $installationFailureStatus = Get-RqgInstallationFailureStatus 'Structured result processing'
                    $maskedInstallationFailureComment = $installationFailureComment
                    foreach ($secretValue in @($installationJwt, $token, $authorizationHeader, $basicCredential)) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$secretValue)) {
                            $maskedInstallationFailureComment = $maskedInstallationFailureComment.Replace([string]$secretValue, '***')
                        }
                    }
                    Write-Warning "A GitHub App installation produced an invalid structured result: $maskedInstallationFailureComment Processing will continue with the remaining installations."
                }
                finally {
                    Remove-Item -LiteralPath $installationResultPath -Force -ErrorAction SilentlyContinue
                }
                if ($installationFailureComment -and $installationRowsAdded -eq 0) {
                    foreach ($secretValue in @($installationJwt, $token, $authorizationHeader, $basicCredential)) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$secretValue)) {
                            $installationFailureComment = $installationFailureComment.Replace([string]$secretValue, '***')
                        }
                    }
                    foreach ($repositoryName in $repositories) {
                        $privateReportRows.Add([pscustomobject][ordered]@{
                            repository = [string]$repositoryName
                            visibility = [string]$repositoryMetadata[[string]$repositoryName].visibility
                            runner = 'Not Used'
                            status = [string]$installationFailureStatus
                            comment = ConvertTo-RqgEmailComment -Status ([string]$installationFailureStatus) -Detail ([string]$installationFailureComment)
                            detail = [string]$installationFailureComment
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
                Remove-Variable installationJwt -ErrorAction SilentlyContinue
                Remove-Variable basicCredential -ErrorAction SilentlyContinue
                Remove-Variable authorizationHeader -ErrorAction SilentlyContinue
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($RepositoryCloneProbeSha256) -and -not $cloneProbeMatched) {
            throw 'No accessible GitHub App repository matched the requested clone-probe digest.'
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
    Invoke-RepositoryQualityGateAppFleetUpdate -ApplicationId $AppId -PemPrivateKey $PrivateKey -ResolvedTemplateRoot $TemplateRoot -EnableAutoEnroll:$AutoEnroll -EnableApply:$Apply -EnableAutoMerge:$AutoMerge -SelectedWaveCount $WaveCount -SelectedWaveIndex $WaveIndex -RepositoryCloneProbeSha256 $CloneProbeRepositorySha256 -ResolvedPrivateReportPath $PrivateReportPath -BranchLifetimeHours $TemporaryBranchLifetimeHours
}
