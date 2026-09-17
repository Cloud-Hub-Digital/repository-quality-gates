$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scanner = Join-Path $root '.tools\gitleaks\gitleaks.exe'
$config = Join-Path $root 'security\gitleaks-portable.toml'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('repository-policy-tests-' + [guid]::NewGuid().ToString('N'))
$checks = 0

function Invoke-Case {
    param(
        [string]$Name,
        [string]$RuleId,
        [string]$RelativePath,
        [string]$Content,
        [bool]$ShouldFind
    )
    $caseRoot = Join-Path $scratch $Name
    $target = Join-Path $caseRoot $RelativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    [IO.File]::WriteAllText($target, $Content, [Text.UTF8Encoding]::new($false))
    $report = Join-Path $scratch ($Name + '.json')
    $ErrorActionPreference = 'Continue'
    & $scanner '--config' $config '--enable-rule' $RuleId '--redact=100' '--no-banner' '--no-color' '--report-format' 'json' '--report-path' $report 'dir' $caseRoot 2>&1 | Out-Null
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $findings = if (Test-Path -LiteralPath $report) { @(Get-Content -LiteralPath $report -Raw | ConvertFrom-Json) } else { @() }
    $found = @($findings | Where-Object RuleID -eq $RuleId).Count -gt 0
    if ($found -ne $ShouldFind) { throw "Unexpected detection result for $Name ($RuleId); expected finding=$ShouldFind." }
    if ($ShouldFind -and $exitCode -ne 1) { throw "Expected a Gitleaks finding for $Name." }
    if (-not $ShouldFind -and $exitCode -ne 0) { throw "Unexpected Gitleaks error for $Name." }
    $script:checks++
}

if (-not (Test-Path -LiteralPath $scanner -PathType Leaf)) { throw 'Install the pinned Gitleaks binary first.' }
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $canary = ('Q7m~2Lp+' + '9Vx=4Ka.' + 'R8t_6Nz-' + '3Hs5Df0')
    Invoke-Case 'connection-positive' 'portable-connection-string-password' 'app.config' ('Server=db.example.invalid;Password=' + $canary) $true
    Invoke-Case 'connection-negative' 'portable-connection-string-password' 'docs/example.txt' 'Server=db.example.invalid;Password=<PASSWORD>' $false
    Invoke-Case 'uri-positive' 'portable-credentialed-uri' 'settings.txt' ('postgresql://service:' + $canary + '@db.example.invalid/app') $true
    Invoke-Case 'authorization-positive' 'portable-authorization-header' 'request.http' ('Authorization: Bearer ' + $canary) $true
    Invoke-Case 'client-positive' 'portable-client-secret' 'oauth.env' ('client_secret=' + $canary) $true
    Invoke-Case 'refresh-positive' 'portable-refresh-token' 'oauth.env' ('refresh_token=' + $canary) $true
    Invoke-Case 'session-positive' 'portable-session-secret' 'session.env' ('session_token=' + $canary) $true
    Invoke-Case 'key-file-positive' 'portable-sensitive-key-file' 'keys/application.jks' 'synthetic placeholder' $true
    Invoke-Case 'key-file-negative' 'portable-sensitive-key-file' 'keys/public.crt' 'public certificate documentation' $false
    Write-Host "PASS: $checks portable detection-policy checks. No real credentials used."
} finally {
    $scratchFull = [IO.Path]::GetFullPath($scratch)
    $tempFull = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($scratchFull.StartsWith($tempFull, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $scratchFull -Recurse -Force
    }
}
exit 0
