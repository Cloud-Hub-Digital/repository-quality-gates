param(
    [Parameter(Mandatory)][string]$PrivateConfigPath
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$privateFullPath = [IO.Path]::GetFullPath($PrivateConfigPath)
$repositoryRoot = [IO.Path]::GetFullPath($root).TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath $privateFullPath -PathType Leaf)) { throw 'The private publication-safety policy does not exist.' }
if ($privateFullPath.StartsWith($repositoryRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The private publication-safety policy must remain outside the repository.'
}
& (Join-Path $PSScriptRoot 'Install-Gitleaks.ps1')
& git -C $root config --local publicationSafety.privateConfig $privateFullPath
if ($LASTEXITCODE -ne 0) { throw 'Failed to record the local private-policy path.' }
& (Join-Path $PSScriptRoot 'Install-GitHooks.ps1')
& (Join-Path $PSScriptRoot 'Test-Secrets.ps1') -Mode WorkingTree
Write-Host 'Secret scanning is configured. The private policy remains outside the repository.'
