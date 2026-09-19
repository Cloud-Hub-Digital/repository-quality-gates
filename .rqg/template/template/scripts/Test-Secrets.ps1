param(
    [ValidateSet('Staged', 'Push', 'History', 'WorkingTree')][string]$Mode = 'History',
    [string]$Repository = (Split-Path -Parent $PSScriptRoot),
    [string]$PushUpdatesPath,
    [string]$PrivateConfigPath
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scanner = Join-Path $root '.tools\gitleaks\gitleaks.exe'
$publicConfig = Join-Path $root '.gitleaks.toml'

function Get-Sha256([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose(); $stream.Dispose() }
}

$lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'gitleaks-lock.json') -Raw | ConvertFrom-Json
if (-not (Test-Path -LiteralPath $scanner)) { throw 'Run scripts\Install-Gitleaks.ps1 before using secret checks.' }
if ((Get-Sha256 $scanner) -ne $lock.executableSha256) {
    throw 'Scanner integrity check failed. Reinstall using scripts\Install-Gitleaks.ps1.'
}
if (-not (Test-Path -LiteralPath $publicConfig -PathType Leaf)) { throw 'Public Gitleaks configuration is missing.' }

$repositoryRoot = [IO.Path]::GetFullPath($Repository).TrimEnd('\', '/')
if (-not $PrivateConfigPath) {
    $configuredPath = (& git -C $repositoryRoot config --local --get publicationSafety.privateConfig 2>$null)
    if ($LASTEXITCODE -eq 0 -and $configuredPath) { $PrivateConfigPath = $configuredPath.Trim() }
}

$policyConfigs = @(
    [pscustomobject]@{ Name = 'portable and project'; Path = [IO.Path]::GetFullPath($publicConfig) }
)
if ($PrivateConfigPath) {
    $privateFullPath = [IO.Path]::GetFullPath($PrivateConfigPath)
    $repositoryPrefix = $repositoryRoot + [IO.Path]::DirectorySeparatorChar
    if ($privateFullPath.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The private publication-safety configuration must remain outside the repository.'
    }
    if (-not (Test-Path -LiteralPath $privateFullPath -PathType Leaf)) {
        throw 'The configured private publication-safety configuration is unavailable.'
    }
    $policyConfigs += [pscustomobject]@{ Name = 'private publication safety'; Path = $privateFullPath }
}

function Invoke-PolicyScan {
    param(
        [string[]]$Arguments,
        [string]$Location,
        [string]$FailureMessage
    )
    Push-Location $Location
    try {
        foreach ($policy in $policyConfigs) {
            $scannerArguments = @(
                '--config', $policy.Path,
                '--redact=100',
                '--no-banner',
                '--no-color',
                '--ignore-gitleaks-allow',
                '--timeout', '180'
            ) + $Arguments
            & $scanner @scannerArguments
            if ($LASTEXITCODE -ne 0) {
                throw "$FailureMessage Policy layer: $($policy.Name)."
            }
        }
    } finally {
        Pop-Location
    }
}

$snapshot = $null
try {
    switch ($Mode) {
        'Staged' {
            Invoke-PolicyScan -Arguments @('git', '--pre-commit', '--staged', $repositoryRoot) -Location $repositoryRoot -FailureMessage 'Staged secret check failed; review the redacted findings or scanner error.'
            Write-Host "Secret check passed for staged content using $($policyConfigs.Count) policy layer(s)."
            return
        }
        'Push' {
            if ($PushUpdatesPath) {
                $pushInput = Get-Content -LiteralPath $PushUpdatesPath -Raw
            } else {
                $pushInput = [Console]::In.ReadToEnd()
            }
            $updates = @($pushInput -split "`r?`n" | Where-Object { $_.Trim() })
            foreach ($update in $updates) {
                $fields = @($update.Trim() -split '\s+')
                if ($fields.Count -ne 4) { throw 'Invalid pre-push update input.' }
                $localObject = $fields[1]
                $remoteObject = $fields[3]
                if ($localObject -match '^0+$') { continue }
                if ($localObject -notmatch '^[0-9a-fA-F]{40,64}$') { throw 'Invalid local object ID in pre-push input.' }
                $localCommit = (& git -C $repositoryRoot rev-parse --verify "$localObject`^{commit}" 2>$null)
                if ($LASTEXITCODE -ne 0 -or -not $localCommit) { throw 'Outgoing object does not resolve to a commit.' }
                $logRange = $localCommit.Trim()
                if ($remoteObject -notmatch '^0+$') {
                    if ($remoteObject -notmatch '^[0-9a-fA-F]{40,64}$') { throw 'Invalid remote object ID in pre-push input.' }
                    $remoteCommit = (& git -C $repositoryRoot rev-parse --verify "$remoteObject`^{commit}" 2>$null)
                    if ($LASTEXITCODE -eq 0 -and $remoteCommit) { $logRange = $remoteCommit.Trim() + '..' + $logRange }
                }
                Invoke-PolicyScan -Arguments @('git', "--log-opts=$logRange --full-history", $repositoryRoot) -Location $repositoryRoot -FailureMessage 'Secret check failed for an outgoing push object; review the redacted findings or scanner error.'
            }
            Write-Host "Secret check passed for $($updates.Count) outgoing ref update(s) using $($policyConfigs.Count) policy layer(s)."
            return
        }
        'History' {
            $shallow = & git -C $repositoryRoot rev-parse --is-shallow-repository
            if ($LASTEXITCODE -ne 0 -or $shallow -ne 'false') { throw 'A complete, non-shallow Git repository is required for history scanning.' }
            Invoke-PolicyScan -Arguments @('git', '--log-opts=--all --full-history', $repositoryRoot) -Location $repositoryRoot -FailureMessage 'History secret check failed; review the redacted findings or scanner error.'
            Write-Host "Secret check passed for full history using $($policyConfigs.Count) policy layer(s)."
            return
        }
        'WorkingTree' {
            $snapshot = Join-Path ([IO.Path]::GetTempPath()) ('repository-scan-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $snapshot | Out-Null
            $files = & git -C $repositoryRoot -c core.quotepath=false ls-files --cached --others --exclude-standard
            if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate source files.' }
            foreach ($file in ($files | Select-Object -Unique)) {
                if ($file.StartsWith('"')) { throw 'Unsupported quoted filename; scan this file explicitly before proceeding.' }
                $source = Join-Path $repositoryRoot $file
                if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
                $target = [IO.Path]::GetFullPath((Join-Path $snapshot $file))
                if (-not $target.StartsWith($snapshot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid source path.' }
                New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
                Copy-Item -LiteralPath $source -Destination $target
            }
            Invoke-PolicyScan -Arguments @('dir', '.') -Location $snapshot -FailureMessage 'Working-tree secret check failed.'
            Write-Host "Secret check passed for the working tree using $($policyConfigs.Count) policy layer(s)."
            return
        }
    }
} finally {
    if ($snapshot -and [IO.Path]::GetFullPath($snapshot).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $snapshot -Recurse -Force
    }
}
