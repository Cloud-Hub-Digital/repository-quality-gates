$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$deploymentTool = Join-Path $root 'scripts\Invoke-RepositoryQualityGates.ps1'
$updateTool = Join-Path $root 'scripts\Update-RepositoryQualityGates.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('rqg-update-tests-' + [guid]::NewGuid().ToString('N'))
$passed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:passed++
}

function Invoke-Update([string]$RepositoryPath, [switch]$Apply) {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $updateTool, '-RepositoryPath', $RepositoryPath, '-TemplateRoot', $root, '-OutputFormat', 'Json')
    if ($Apply) { $arguments += '-Apply' }
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& powershell.exe @arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    [pscustomobject]@{ ExitCode = $exitCode; Output = $output -join [Environment]::NewLine }
}

function Commit-All([string]$RepositoryPath, [string]$Message) {
    & git -C $RepositoryPath add -A
    & git -C $RepositoryPath commit -m $Message | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to commit the fixture.' }
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $managed = Join-Path $testRoot 'managed'
    New-Item -ItemType Directory -Path $managed | Out-Null
    & git -C $managed init -q
    & git -C $managed config user.name 'Fixture'
    & git -C $managed config user.email 'fixture@example.invalid'
    '# Managed fixture' | Set-Content -LiteralPath (Join-Path $managed 'README.md') -Encoding ascii
    Commit-All $managed 'initial fixture'

    $null = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $deploymentTool -RepositoryPath $managed -Apply -OutputFormat Json 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) 'The update fixture should accept its initial deployment.'
    Commit-All $managed 'install quality gates'

    $statePath = Join-Path $managed '.repository-quality-gates.json'
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $state.templateVersion = '1.0.1'
    $stateJson = ($state | ConvertTo-Json -Depth 8).Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
    [IO.File]::WriteAllText($statePath, $stateJson, [Text.UTF8Encoding]::new($false))
    Commit-All $managed 'simulate previous stable template'

    $preview = Invoke-Update $managed
    Assert-True ($preview.ExitCode -eq 0) "An older managed repository should accept update preview. $($preview.Output)"
    $previewJson = $preview.Output | ConvertFrom-Json
    Assert-True ($previewJson.status -eq 'Available') 'An older managed repository should report an available update.'

    $apply = Invoke-Update $managed -Apply
    Assert-True ($apply.ExitCode -eq 0) "An unchanged managed repository should update successfully. $($apply.Output)"
    $applyJson = $apply.Output | ConvertFrom-Json
    Assert-True ($applyJson.status -eq 'Updated') 'Apply should report an updated repository.'
    Assert-True ($applyJson.changedPaths -contains '.repository-quality-gates.json') 'The update should refresh managed state.'
    $updatedState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-True ($updatedState.templateVersion -eq '1.1.0-dev.1') 'Managed state should record the new template version.'
    Commit-All $managed 'update quality gates'

    $current = Invoke-Update $managed
    Assert-True ($current.ExitCode -eq 0) 'A current repository should be handled without error.'
    Assert-True (($current.Output | ConvertFrom-Json).status -eq 'Current') 'A current repository should report Current.'

    $updatedState.templateVersion = '9.0.0'
    [IO.File]::WriteAllText($statePath, (($updatedState | ConvertTo-Json -Depth 8).Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    Commit-All $managed 'simulate newer template'
    $ahead = Invoke-Update $managed
    Assert-True ($ahead.ExitCode -eq 0) 'A repository on a newer version should not fail.'
    Assert-True (($ahead.Output | ConvertFrom-Json).status -eq 'Ahead') 'A newer repository should never be downgraded.'

    $aheadState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $aheadState.templateVersion = '1.0.1'
    [IO.File]::WriteAllText($statePath, (($aheadState | ConvertTo-Json -Depth 8).Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    Commit-All $managed 'restore previous stable template'
    $managedWorkflow = Join-Path $managed '.github\workflows\quality-documentation.yml'
    Add-Content -LiteralPath $managedWorkflow -Value '# repository-owned change'
    $conflict = Invoke-Update $managed -Apply
    Assert-True ($conflict.ExitCode -ne 0) 'A modified managed file should stop the automatic update.'
    Assert-True ((Get-Content -LiteralPath $managedWorkflow -Raw).Contains('# repository-owned change')) 'A failed automatic update must preserve the repository-owned change.'
    Assert-True ((Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).templateVersion -eq '1.0.1') 'A failed automatic update must not advance managed state.'

    $unmanaged = Join-Path $testRoot 'unmanaged'
    New-Item -ItemType Directory -Path $unmanaged | Out-Null
    & git -C $unmanaged init -q
    & git -C $unmanaged config user.name 'Fixture'
    & git -C $unmanaged config user.email 'fixture@example.invalid'
    'fixture' | Set-Content -LiteralPath (Join-Path $unmanaged 'README.md') -Encoding ascii
    Commit-All $unmanaged 'unmanaged fixture'
    $unmanagedResult = Invoke-Update $unmanaged
    Assert-True ($unmanagedResult.ExitCode -eq 0) 'An unmanaged repository should be skipped cleanly.'
    Assert-True (($unmanagedResult.Output | ConvertFrom-Json).status -eq 'Unmanaged') 'An unmanaged repository should report Unmanaged.'

    Write-Host "$passed assertions passed."
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
