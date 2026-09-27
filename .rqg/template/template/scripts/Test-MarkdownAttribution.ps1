# SPDX-License-Identifier: MIT
param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryPath,
    [Parameter(Mandatory = $true)]
    [string]$ApprovedName
)
$ErrorActionPreference = 'Stop'

$root = [IO.Path]::GetFullPath($RepositoryPath).TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'The repository path does not exist.' }
$files = @(git -C $root -c core.quotepath=false ls-files -- '*.md' '*.markdown')
if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate tracked Markdown files.' }

$headingPattern = '^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$'
$sectionPattern = '(?i)\b(?:licen[cs]e?s?|attribution)\b'
$namePattern = '(?<!\w)' + [regex]::Escape($ApprovedName) + '(?!\w)'
$violations = [System.Collections.Generic.List[string]]::new()

foreach ($relative in $files) {
    if (-not $relative -or $relative -ne 'README.md') { continue }
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    $heading = $null
    $lineNumber = 0
    foreach ($line in (Get-Content -LiteralPath $path)) {
        $lineNumber++
        $headingMatch = [regex]::Match($line, $headingPattern)
        if ($headingMatch.Success) { $heading = $headingMatch.Groups[1].Value.Trim() }
        if ($line -match $namePattern -and ($null -eq $heading -or $heading -notmatch $sectionPattern)) {
            $violations.Add("$relative`:$lineNumber is outside an approved licence/license/attribution section.")
        }
    }
}

if ($violations.Count -gt 0) {
    $violations | ForEach-Object { Write-Error $_ }
    exit 1
}
Write-Host "PASS: Approved Markdown attribution placement for '$ApprovedName'."
exit 0
