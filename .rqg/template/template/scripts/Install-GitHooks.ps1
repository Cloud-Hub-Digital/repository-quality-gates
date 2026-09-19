$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$current = & git -C $root config --get core.hooksPath
if ($LASTEXITCODE -notin @(0, 1)) { throw 'Unable to inspect Git hook configuration.' }
if ($current -and $current -ne '.githooks') { throw 'An existing hooksPath is configured. Integrate its hooks before replacing it.' }
if (-not $current) {
    $hookDirectory = & git -C $root rev-parse --path-format=absolute --git-path hooks
    if ($LASTEXITCODE -ne 0) { throw 'Unable to locate existing Git hooks.' }
    $active = @(Get-ChildItem -LiteralPath $hookDirectory -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.sample' })
    if ($active.Count -gt 0) { throw 'Existing hooks found. Integrate them before enabling repository hooks.' }
}
& (Join-Path $PSScriptRoot 'Test-Secrets.ps1') -Mode Staged
& git -C $root config --local core.hooksPath .githooks
if ($LASTEXITCODE -ne 0) { throw 'Failed to configure repository hooks.' }
Write-Host 'Enabled repository-local pre-commit and pre-push secret checks.'
