$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$lock = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'gitleaks-lock.json') -Raw | ConvertFrom-Json
if (-not [Environment]::Is64BitOperatingSystem) { throw 'The scanner requires 64-bit Windows.' }
$destination = Join-Path $root '.tools\gitleaks'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('repository-gitleaks-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $archive = Join-Path $scratch 'gitleaks.zip'
    $url = "https://github.com/gitleaks/gitleaks/releases/download/v$($lock.version)/gitleaks_$($lock.version)_windows_x64.zip"
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $archive
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $lock.archiveSha256) {
        throw 'Gitleaks archive checksum mismatch.'
    }
    Expand-Archive -LiteralPath $archive -DestinationPath $scratch
    $executable = Join-Path $scratch 'gitleaks.exe'
    if ((Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash -ne $lock.executableSha256) {
        throw 'Gitleaks executable checksum mismatch.'
    }
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Copy-Item -LiteralPath $executable -Destination (Join-Path $destination 'gitleaks.exe') -Force
    Write-Host "Installed verified Gitleaks $($lock.version)."
} finally {
    # Only this invocation's generated temporary directory is removed.
    if ([IO.Path]::GetFullPath($scratch).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $scratch -Recurse -Force
    }
}
