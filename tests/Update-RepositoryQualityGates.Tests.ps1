# SPDX-License-Identifier: MIT
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

function Invoke-Update([string]$RepositoryPath, [switch]$Enroll, [switch]$Apply) {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $updateTool, '-RepositoryPath', $RepositoryPath, '-TemplateRoot', $root, '-OutputFormat', 'Json')
    if ($Enroll) { $arguments += '-Enroll' }
    if ($Apply) { $arguments += '-Apply' }
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& pwsh @arguments 2>&1)
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

    $null = @(& pwsh -NoProfile -File $deploymentTool -RepositoryPath $managed -Apply -OutputFormat Json 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) 'The update fixture should accept its initial deployment.'
    Commit-All $managed 'install quality gates'

    $statePath = Join-Path $managed '.repository-quality-gates.json'
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $state.templateVersion = '1.1.0'
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
    Assert-True ($updatedState.templateVersion -eq '1.5.6') 'Managed state should record the new template version.'
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
    $aheadState.templateVersion = '1.1.0'
    [IO.File]::WriteAllText($statePath, (($aheadState | ConvertTo-Json -Depth 8).Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    Commit-All $managed 'restore previous stable template'
    $managedWorkflow = Join-Path $managed '.github\workflows\quality-documentation.yml'
    Add-Content -LiteralPath $managedWorkflow -Value '# repository-owned change'
    $conflict = Invoke-Update $managed -Apply
    Assert-True ($conflict.ExitCode -ne 0) 'A modified managed file should stop the automatic update.'
    Assert-True ((Get-Content -LiteralPath $managedWorkflow -Raw).Contains('# repository-owned change')) 'A failed automatic update must preserve the repository-owned change.'
    Assert-True ((Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).templateVersion -eq '1.1.0') 'A failed automatic update must not advance managed state.'

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

    $enrollmentPreview = Invoke-Update $unmanaged -Enroll
    Assert-True ($enrollmentPreview.ExitCode -eq 0) "An explicitly enrolled unmanaged repository should accept an enrolment preview. $($enrollmentPreview.Output)"
    $enrollmentPreviewJson = $enrollmentPreview.Output | ConvertFrom-Json
    Assert-True ($enrollmentPreviewJson.status -eq 'EnrollmentAvailable') 'An explicitly enrolled unmanaged repository should report an available enrolment.'
    Assert-True ($enrollmentPreviewJson.selectedModules -contains 'secret-scanning') 'Initial enrolment should include the universal secret-scanning module.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $unmanaged '.repository-quality-gates.json'))) 'An enrolment preview must not modify the repository.'

    $enrollmentApply = Invoke-Update $unmanaged -Enroll -Apply
    Assert-True ($enrollmentApply.ExitCode -eq 0) "An explicitly enrolled unmanaged repository should enrol successfully. $($enrollmentApply.Output)"
    $enrollmentApplyJson = $enrollmentApply.Output | ConvertFrom-Json
    Assert-True ($enrollmentApplyJson.status -eq 'Enrolled') 'Applied initial enrolment should report Enrolled.'
    $enrolledState = Get-Content -LiteralPath (Join-Path $unmanaged '.repository-quality-gates.json') -Raw | ConvertFrom-Json
    Assert-True ($enrolledState.templateVersion -eq '1.5.6') 'Initial enrolment should record the current template version.'
    Assert-True (Test-Path -LiteralPath (Join-Path $unmanaged '.github\workflows\secret-scanning.yml')) 'Initial enrolment should deploy the selected quality-gate workflows.'

    $overlap = Join-Path $testRoot 'overlap'
    New-Item -ItemType Directory -Path (Join-Path $overlap '.github\workflows') -Force | Out-Null
    & git -C $overlap init -q
    & git -C $overlap config user.name 'Fixture'
    & git -C $overlap config user.email 'fixture@example.invalid'
    "name: Existing Security`nsteps:`n  - run: gitleaks detect" | Set-Content -LiteralPath (Join-Path $overlap '.github\workflows\security.yml') -Encoding utf8
    Commit-All $overlap 'existing overlapping workflow'
    $overlapEnrollment = Invoke-Update $overlap -Enroll -Apply
    Assert-True ($overlapEnrollment.ExitCode -ne 0) 'Automatic enrolment should stop when an undeclared existing workflow overlaps a selected module.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $overlap '.repository-quality-gates.json'))) 'Failed automatic enrolment must not create managed state.'

    $legacyPreserved = Join-Path $testRoot 'legacy-preserved'
    New-Item -ItemType Directory -Path $legacyPreserved | Out-Null
    & git -C $legacyPreserved init -q
    & git -C $legacyPreserved config user.name 'Fixture'
    & git -C $legacyPreserved config user.email 'fixture@example.invalid'
    New-Item -ItemType Directory -Path (Join-Path $legacyPreserved '.github\workflows') -Force | Out-Null
    "name: Existing Documentation Check`nsteps:`n  - run: markdownlint README.md" | Set-Content -LiteralPath (Join-Path $legacyPreserved '.github\workflows\ci.yml') -Encoding utf8
    '# Legacy Preservation Fixture' | Set-Content -LiteralPath (Join-Path $legacyPreserved 'README.md') -Encoding utf8
    Commit-All $legacyPreserved 'initial legacy preservation fixture'
    $null = @(& pwsh -NoProfile -File $deploymentTool -RepositoryPath $legacyPreserved -Apply -PreserveExistingModule documentation -OutputFormat Json 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) 'The legacy preservation fixture should accept its initial deployment.'
    Commit-All $legacyPreserved 'install legacy preserved quality gates'
    $legacyStatePath = Join-Path $legacyPreserved '.repository-quality-gates.json'
    $legacyState = Get-Content -LiteralPath $legacyStatePath -Raw | ConvertFrom-Json
    $legacyState.templateVersion = '1.1.0'
    [IO.File]::WriteAllText($legacyStatePath, (($legacyState | ConvertTo-Json -Depth 8).Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    Commit-All $legacyPreserved 'simulate legacy stable template'
    $legacyUpdate = Invoke-Update $legacyPreserved -Apply
    Assert-True ($legacyUpdate.ExitCode -eq 0) "Legacy preserved modules should migrate successfully. $($legacyUpdate.Output)"
    $migratedRulesPath = Join-Path $legacyPreserved '.repository-quality-gates.local.json'
    Assert-True (Test-Path -LiteralPath $migratedRulesPath) 'The updater should create a downstream rules file for legacy preserved modules.'
    $migratedRules = Get-Content -LiteralPath $migratedRulesPath -Raw | ConvertFrom-Json
    Assert-True ($migratedRules.modules.repositoryOwned -contains 'documentation') 'The migrated rules file should retain the repository-owned module decision.'
    $migratedState = Get-Content -LiteralPath $legacyStatePath -Raw | ConvertFrom-Json
    Assert-True (@($migratedState.files | Where-Object path -eq '.repository-quality-gates.local.json').Count -eq 0) 'The migrated downstream rules file must remain outside managed state.'

    $legacySecret = Join-Path $testRoot 'legacy-secret-preservation'
    New-Item -ItemType Directory -Path $legacySecret | Out-Null
    & git -C $legacySecret init -q
    & git -C $legacySecret config user.name 'Fixture'
    & git -C $legacySecret config user.email 'fixture@example.invalid'
    '# Legacy Secret Fixture' | Set-Content -LiteralPath (Join-Path $legacySecret 'README.md') -Encoding utf8
    Commit-All $legacySecret 'initial legacy secret fixture'
    $null = @(& pwsh -NoProfile -File $deploymentTool -RepositoryPath $legacySecret -Apply -OutputFormat Json 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) 'The legacy secret fixture should accept its initial deployment.'
    $legacySecretStatePath = Join-Path $legacySecret '.repository-quality-gates.json'
    $legacySecretState = Get-Content -LiteralPath $legacySecretStatePath -Raw | ConvertFrom-Json
    $legacySecretState.templateVersion = '1.3.1'
    $legacySecretState.files = @($legacySecretState.files | Where-Object module -ne 'secret-scanning')
    $legacySecretState.preservedModules = @(@($legacySecretState.preservedModules) + 'secret-scanning' | Sort-Object -Unique)
    [IO.File]::WriteAllText($legacySecretStatePath, (($legacySecretState | ConvertTo-Json -Depth 8).Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    $legacyRootPolicy = Join-Path $legacySecret '.gitleaks.toml'
    Add-Content -LiteralPath $legacyRootPolicy -Value "`n# repository-owned exception" -Encoding utf8
    $legacyRootPolicyHash = (Get-FileHash -LiteralPath $legacyRootPolicy -Algorithm SHA256).Hash
    Commit-All $legacySecret 'simulate legacy preserved secret-scanning module'
    $legacySecretUpdate = Invoke-Update $legacySecret -Apply
    Assert-True ($legacySecretUpdate.ExitCode -eq 0) "A legacy preserved secret-scanning module should migrate safely. $($legacySecretUpdate.Output)"
    Assert-True ((Get-FileHash -LiteralPath $legacyRootPolicy -Algorithm SHA256).Hash -eq $legacyRootPolicyHash) 'The customized legacy root Gitleaks policy should remain byte for byte unchanged.'
    $legacySecretRules = Get-Content -LiteralPath (Join-Path $legacySecret '.repository-quality-gates.local.json') -Raw | ConvertFrom-Json
    Assert-True ($legacySecretRules.paths.repositoryOwned -contains '.gitleaks.toml') 'The migrated local rules should record the customized root Gitleaks policy as repository-owned.'
    $legacySecretUpdatedState = Get-Content -LiteralPath $legacySecretStatePath -Raw | ConvertFrom-Json
    Assert-True (@($legacySecretUpdatedState.files | Where-Object path -eq '.gitleaks.toml').Count -eq 0) 'The customized root Gitleaks policy must remain outside managed state after migration.'
    Assert-True ($legacySecretUpdatedState.modules -contains 'secret-scanning') 'The remaining secret-scanning payload should return to central management.'

    $deceptiveLegacySecret = Join-Path $testRoot 'deceptive-legacy-secret-preservation'
    & git clone -q $legacySecret $deceptiveLegacySecret
    & git -C $deceptiveLegacySecret config user.name 'Fixture'
    & git -C $deceptiveLegacySecret config user.email 'fixture@example.invalid'
    $deceptiveRulesPath = Join-Path $deceptiveLegacySecret '.repository-quality-gates.local.json'
    Remove-Item -LiteralPath $deceptiveRulesPath -Force -ErrorAction SilentlyContinue
    $deceptiveStatePath = Join-Path $deceptiveLegacySecret '.repository-quality-gates.json'
    $deceptiveState = Get-Content -LiteralPath $deceptiveStatePath -Raw | ConvertFrom-Json
    $deceptiveState.templateVersion = '1.3.1'
    $deceptiveState.files = @($deceptiveState.files | Where-Object module -ne 'secret-scanning')
    $deceptiveState.preservedModules = @(@($deceptiveState.preservedModules) + 'secret-scanning' | Sort-Object -Unique)
    [IO.File]::WriteAllText($deceptiveStatePath, (($deceptiveState | ConvertTo-Json -Depth 8).Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    @'
[extend]

[[rules]]
id = "synthetic-rule"
path = "security/gitleaks-portable.toml"
'@ | Set-Content -LiteralPath (Join-Path $deceptiveLegacySecret '.gitleaks.toml') -Encoding utf8
    Commit-All $deceptiveLegacySecret 'simulate deceptive legacy root policy'
    $deceptiveLegacyUpdate = Invoke-Update $deceptiveLegacySecret -Apply
    Assert-True ($deceptiveLegacyUpdate.ExitCode -ne 0) 'A path key outside the extend section must not satisfy legacy portable-policy inheritance.'
    $deceptiveNormalizedOutput = (($deceptiveLegacyUpdate.Output -replace '\x1B\[[0-?]*[ -/]*[@-~]', '') -replace '[\s|]+', ' ')
    Assert-True ($deceptiveNormalizedOutput -match 'does not extend security/gitleaks-portable\.toml') 'The deceptive legacy policy should fail with the inheritance error.'

    $localRules = Join-Path $testRoot 'local-rules'
    New-Item -ItemType Directory -Path $localRules | Out-Null
    & git -C $localRules init -q
    & git -C $localRules config user.name 'Fixture'
    & git -C $localRules config user.email 'fixture@example.invalid'
    '# Local rules fixture' | Set-Content -LiteralPath (Join-Path $localRules 'README.md') -Encoding ascii
    Commit-All $localRules 'initial local rules fixture'
    $null = @(& pwsh -NoProfile -File $deploymentTool -RepositoryPath $localRules -Apply -OutputFormat Json 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) 'The local-rules fixture should accept its initial deployment.'
    Commit-All $localRules 'install quality gates'
    $localStatePath = Join-Path $localRules '.repository-quality-gates.json'
    $localState = Get-Content -LiteralPath $localStatePath -Raw | ConvertFrom-Json
    $localState.templateVersion = '1.1.0'
    [IO.File]::WriteAllText($localStatePath, (($localState | ConvertTo-Json -Depth 8).Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    $localRulesPath = Join-Path $localRules '.repository-quality-gates.local.json'
    $repositoryPolicyPath = Join-Path $localRules 'security\gitleaks-repository.toml'
    New-Item -ItemType Directory -Path (Split-Path -Parent $repositoryPolicyPath) -Force | Out-Null
    $repositoryPolicyText = @'
title = "Repository Policy"

[[rules]]
id = "repository-synthetic-marker"
description = "Synthetic repository-only test marker"
regex = '''RQG_REPO_ONLY_[A-Z]{16}'''
keywords = ["RQG_REPO_ONLY_"]
'@
    [IO.File]::WriteAllText($repositoryPolicyPath, $repositoryPolicyText.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n", [Text.UTF8Encoding]::new($false))
    $rulesText = @'
{
  "schemaVersion": 1,
  "automaticEnrollment": false,
  "modules": {
    "include": ["php"],
    "repositoryOwned": []
  },
  "secretScanning": {
    "additionalConfigFiles": ["security/gitleaks-repository.toml"]
  }
}
'@
    [IO.File]::WriteAllText($localRulesPath, $rulesText.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n", [Text.UTF8Encoding]::new($false))
    $rulesHashBefore = (Get-FileHash -LiteralPath $localRulesPath -Algorithm SHA256).Hash
    Commit-All $localRules 'configure repository-owned quality rules'

    $localApply = Invoke-Update $localRules -Apply
    Assert-True ($localApply.ExitCode -eq 0) "A repository-owned include rule should apply successfully. $($localApply.Output)"
    Assert-True (Test-Path -LiteralPath (Join-Path $localRules '.github\workflows\quality-php.yml')) 'A repository-owned include rule should install the named module.'
    Assert-True ((Get-FileHash -LiteralPath $localRulesPath -Algorithm SHA256).Hash -eq $rulesHashBefore) 'RQG must not modify the downstream repository rules file.'
    $localUpdatedState = Get-Content -LiteralPath $localStatePath -Raw | ConvertFrom-Json
    Assert-True ($localUpdatedState.modules -contains 'php') 'Managed state should record a module selected by repository rules.'
    Assert-True (@($localUpdatedState.files | Where-Object path -eq '.repository-quality-gates.local.json').Count -eq 0) 'The downstream repository rules file must never become RQG-managed.'
    'RQG_REPO_ONLY_ABCDEFGHIJKLMNOP' | Set-Content -LiteralPath (Join-Path $localRules 'repository-policy-fixture.txt') -Encoding ascii
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = @(& pwsh -NoProfile -File (Join-Path $localRules 'scripts\Test-Secrets.ps1') -Mode WorkingTree -Repository $localRules 2>&1)
        $repositoryPolicyExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    Assert-True ($repositoryPolicyExit -ne 0) 'The repository-specific Gitleaks policy layer should detect its synthetic marker.'
    Remove-Item -LiteralPath (Join-Path $localRules 'repository-policy-fixture.txt') -Force

    Write-Host "$passed assertions passed."
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

exit 0
