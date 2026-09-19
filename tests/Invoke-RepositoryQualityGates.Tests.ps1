Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $projectRoot 'scripts\Invoke-RepositoryQualityGates.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('rqg-tests-' + [guid]::NewGuid().ToString('N'))
$passed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:passed++
}

function Invoke-Tool([string]$Repository, [string[]]$Arguments) {
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-RepositoryPath', $Repository) + $Arguments
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & powershell.exe @all 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join [Environment]::NewLine) }
    } finally { $ErrorActionPreference = $previousPreference }
}

function Invoke-DriftCheck([string]$Repository, [string[]]$Arguments = @()) {
    $driftScript = Join-Path $Repository 'scripts\Test-QualityGateModuleDrift.ps1'
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $driftScript, '-RepositoryPath', $Repository, '-OutputFormat', 'Json') + $Arguments
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & powershell.exe @all 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join [Environment]::NewLine) }
    } finally { $ErrorActionPreference = $previousPreference }
}

function Invoke-AutomaticReconciliation([string]$Repository) {
    $script = Join-Path $Repository 'scripts\Invoke-AutomaticQualityGateReconciliation.ps1'
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -RepositoryPath $Repository -OutputFormat Json 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join [Environment]::NewLine) }
    } finally { $ErrorActionPreference = $previousPreference }
}

function New-Fixture([string]$Name) {
    $path = Join-Path $testRoot $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    & git -C $path init --initial-branch=main | Out-Null
    & git -C $path config user.name 'Quality Gates Test' | Out-Null
    & git -C $path config user.email 'quality-gates@example.invalid' | Out-Null
    return $path
}

function Commit-Fixture([string]$Path, [string]$Message = 'fixture') {
    & git -C $Path add --all
    & git -C $Path commit -m $Message | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to commit a fixture.' }
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null

    $reparseTarget = Join-Path $testRoot 'outside-repository'
    New-Item -ItemType Directory -Path $reparseTarget | Out-Null
    $sentinelPath = Join-Path $reparseTarget 'sentinel.txt'
    'unchanged' | Set-Content -LiteralPath $sentinelPath -Encoding ascii
    $reparseFixture = New-Fixture 'reparse-point'
    '# Reparse-point fixture' | Set-Content -LiteralPath (Join-Path $reparseFixture 'README.md') -Encoding ascii
    Commit-Fixture $reparseFixture
    New-Item -ItemType Junction -Path (Join-Path $reparseFixture '.github') -Target $reparseTarget | Out-Null
    $reparsePreview = Invoke-Tool $reparseFixture @('-OutputFormat', 'Json')
    Assert-True ($reparsePreview.ExitCode -ne 0) 'A module path that traverses a junction should be rejected before deployment.'
    Assert-True ((Get-Content -LiteralPath $sentinelPath -Raw).Trim() -eq 'unchanged') 'Rejecting a reparse point must leave the external target unchanged.'

    $mixed = New-Fixture 'mixed'
    '{"name":"fixture","version":"1.0.0","scripts":{"test":"node -e \"process.exit(0)\""}}' | Set-Content -LiteralPath (Join-Path $mixed 'package.json') -Encoding utf8
    $utf8NoBomSource = 'param(); Write-Output "UTF-8 without BOM ' + [char]0x2014 + ' valid"'
    [IO.File]::WriteAllText((Join-Path $mixed 'tool.ps1'), $utf8NoBomSource, (New-Object Text.UTF8Encoding($false)))
    'print("fixture")' | Set-Content -LiteralPath (Join-Path $mixed 'tool.py') -Encoding ascii
    '<?php echo "fixture";' | Set-Content -LiteralPath (Join-Path $mixed 'tool.php') -Encoding ascii
    "#!/usr/bin/env bash`nprintf '%s\n' fixture" | Set-Content -LiteralPath (Join-Path $mixed 'tool.sh') -Encoding ascii
    [IO.File]::WriteAllText((Join-Path $mixed '.gitignore'), "existing-entry`n", (New-Object Text.UTF8Encoding($false)))
    Commit-Fixture $mixed
    New-Item -ItemType Directory -Path (Join-Path $mixed 'ignored-dependency') | Out-Null
    '<Project Sdk="Microsoft.NET.Sdk" />' | Set-Content -LiteralPath (Join-Path $mixed 'ignored-dependency\cache.csproj') -Encoding ascii
    Add-Content -LiteralPath (Join-Path $mixed '.git\info\exclude') -Value 'ignored-dependency/'
    & git -C $mixed check-ignore -q -- 'ignored-dependency/cache.csproj'
    Assert-True ($LASTEXITCODE -eq 0) 'The synthetic dependency project should be Git-ignored.'

    $preview = Invoke-Tool $mixed @('-OutputFormat', 'Json')
    Assert-True ($preview.ExitCode -eq 0) 'Preview should succeed.'
    $previewJson = $preview.Output | ConvertFrom-Json
    Assert-True ($previewJson.selectedModules -contains 'secret-scanning') 'Universal secret scanning should be selected.'
    Assert-True ($previewJson.selectedModules -contains 'node') 'Node should be detected.'
    Assert-True ($previewJson.selectedModules -contains 'powershell') 'PowerShell should be detected.'
    Assert-True ($previewJson.selectedModules -contains 'python') 'Script-only Python should be detected.'
    Assert-True ($previewJson.selectedModules -contains 'php') 'Script-only PHP should be detected.'
    Assert-True ($previewJson.selectedModules -contains 'shell') 'Shell scripts should be detected.'
    Assert-True (-not ($previewJson.selectedModules -contains 'dotnet')) '.NET should not be selected from an ignored dependency marker.'

    $apply = Invoke-Tool $mixed @('-Apply', '-OutputFormat', 'Json')
    Assert-True ($apply.ExitCode -eq 0) "Apply should succeed on a clean fixture. $($apply.Output)"
    Assert-True (Test-Path -LiteralPath (Join-Path $mixed '.repository-quality-gates.json')) 'Managed state should be created.'
    Assert-True (Test-Path -LiteralPath (Join-Path $mixed '.github\workflows\quality-node.yml')) 'The Node workflow should be deployed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $mixed '.github\workflows\quality-powershell.yml')) 'The PowerShell workflow should be deployed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $mixed '.github\workflows\quality-python.yml')) 'The Python workflow should be deployed.'
    $pythonWorkflow = [IO.File]::ReadAllText((Join-Path $mixed '.github\workflows\quality-python.yml'))
    Assert-True ($pythonWorkflow.Contains('requirements-dev.txt')) 'The Python workflow should install development requirements before running tests.'
    Assert-True (Test-Path -LiteralPath (Join-Path $mixed '.github\workflows\quality-php.yml')) 'The PHP workflow should be deployed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $mixed '.github\workflows\quality-shell.yml')) 'The shell workflow should be deployed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $mixed '.github\workflows\quality-module-drift.yml')) 'The automatic module-drift workflow should be deployed universally.'
    $moduleDriftWorkflow = [IO.File]::ReadAllText((Join-Path $mixed '.github\workflows\quality-module-drift.yml'))
    Assert-True ($moduleDriftWorkflow.Contains("if: github.ref_type == 'branch'")) 'Automatic reconciliation should be restricted to branch references and must not mutate tag checkouts.'
    Assert-True ($moduleDriftWorkflow.Contains("BaseName -ne 'quality-module-drift'")) 'Post-reconciliation validation must not redispatch the module-drift workflow into a redundant self-run.'
    Assert-True (Test-Path -LiteralPath (Join-Path $mixed 'scripts\Test-QualityGateModuleDrift.ps1')) 'The module-drift checker should be deployed universally.'
    Assert-True (Test-Path -LiteralPath (Join-Path $mixed 'scripts\RepositoryQualityGates.Detection.ps1')) 'The shared detection library should be deployed universally.'
    Assert-True (Test-Path -LiteralPath (Join-Path $mixed 'scripts\rqg-module-catalog.json')) 'The module catalog snapshot should be deployed universally.'
    Assert-True (Test-Path -LiteralPath (Join-Path $mixed 'scripts\Invoke-AutomaticQualityGateReconciliation.ps1')) 'The automatic reconciliation entry point should be deployed universally.'
    Assert-True (Test-Path -LiteralPath (Join-Path $mixed '.rqg\template\scripts\Invoke-RepositoryQualityGates.ps1')) 'A self-contained deployment engine should be embedded in every managed repository.'
    Assert-True (Test-Path -LiteralPath (Join-Path $mixed '.rqg\template\modules\catalog.json')) 'The embedded deployment engine should include its authoritative module catalog.'
    $initialDrift = Invoke-DriftCheck $mixed
    Assert-True ($initialDrift.ExitCode -eq 0) "A newly deployed mixed repository should have no module drift. $($initialDrift.Output)"
    $initialDriftJson = $initialDrift.Output | ConvertFrom-Json
    Assert-True ($initialDriftJson.status -eq 'Current') 'A newly deployed mixed repository should report current modules.'
    $updatedIgnore = [IO.File]::ReadAllText((Join-Path $mixed '.gitignore'))
    Assert-True (-not $updatedIgnore.Contains("`r")) 'Merging .gitignore entries should preserve existing LF line endings.'
    Assert-True ($updatedIgnore -eq "existing-entry`n`n/.tools/`n") 'The merged .gitignore entry should have one separating blank line and a final newline.'
    $stateBytes = [IO.File]::ReadAllBytes((Join-Path $mixed '.repository-quality-gates.json'))
    $stateText = [Text.Encoding]::UTF8.GetString($stateBytes)
    Assert-True (-not ($stateBytes.Length -ge 3 -and $stateBytes[0] -eq 0xEF -and $stateBytes[1] -eq 0xBB -and $stateBytes[2] -eq 0xBF)) 'Managed state should be UTF-8 without a BOM.'
    Assert-True (-not $stateText.Contains("`r")) 'Managed state should use LF line endings.'
    & git -C $mixed add --all
    $whitespaceOutput = & git -C $mixed diff --cached --check 2>&1
    Assert-True ($LASTEXITCODE -eq 0) "The deployed change set should pass git diff --cached --check. $($whitespaceOutput -join [Environment]::NewLine)"
    & git -C $mixed reset | Out-Null

    $secondPreview = Invoke-Tool $mixed @('-OutputFormat', 'Json')
    $secondJson = $secondPreview.Output | ConvertFrom-Json
    Assert-True (@($secondJson.plan | Where-Object action -eq 'Conflict').Count -eq 0) 'A repeated preview should not conflict.'
    Assert-True (@($secondJson.plan | Where-Object action -notin @('Unchanged')).Count -eq 0) 'A repeated preview should be idempotent.'

    Add-Content -LiteralPath (Join-Path $mixed '.github\workflows\quality-node.yml') -Value '# local change'
    $modified = Invoke-Tool $mixed @('-Apply', '-AllowDirtyWorkingTree', '-OutputFormat', 'Json')
    Assert-True ($modified.ExitCode -ne 0) 'A locally modified managed file should stop apply.'

    $replace = Invoke-Tool $mixed @('-Apply', '-AllowDirtyWorkingTree', '-ConflictAction', 'BackupAndReplace', '-OutputFormat', 'Json')
    Assert-True ($replace.ExitCode -eq 0) 'Reviewed backup-and-replace should succeed.'
    $replaceJson = $replace.Output | ConvertFrom-Json
    Assert-True ([bool]$replaceJson.backupPath) 'Replacement should report a recovery directory.'
    Assert-True (Test-Path -LiteralPath (Join-Path $replaceJson.backupPath '.github\workflows\quality-node.yml')) 'The local modification should be backed up.'

    $standaloneJavaScript = New-Fixture 'standalone-javascript'
    New-Item -ItemType Directory -Path (Join-Path $standaloneJavaScript 'tests') | Out-Null
    'module.exports = function () { return 42; };' | Set-Content -LiteralPath (Join-Path $standaloneJavaScript 'plugin.js') -Encoding ascii
    'if (require("../plugin")() !== 42) { process.exit(1); }' | Set-Content -LiteralPath (Join-Path $standaloneJavaScript 'tests\test.js') -Encoding ascii
    Commit-Fixture $standaloneJavaScript
    $standalonePreview = Invoke-Tool $standaloneJavaScript @('-OutputFormat', 'Json')
    Assert-True ($standalonePreview.ExitCode -eq 0) 'A dependency-free JavaScript preview should succeed.'
    $standaloneJson = $standalonePreview.Output | ConvertFrom-Json
    Assert-True ($standaloneJson.selectedModules -contains 'node') 'Tracked JavaScript should select the Node module without package.json.'
    $standaloneApply = Invoke-Tool $standaloneJavaScript @('-Apply', '-OutputFormat', 'Json')
    Assert-True ($standaloneApply.ExitCode -eq 0) 'A dependency-free JavaScript repository should accept deployment.'
    $standaloneWorkflowPath = Join-Path $standaloneJavaScript '.github\workflows\quality-node.yml'
    Assert-True (Test-Path -LiteralPath $standaloneWorkflowPath) 'The Node workflow should be deployed for dependency-free JavaScript.'
    $standaloneWorkflow = Get-Content -LiteralPath $standaloneWorkflowPath -Raw
    Assert-True ($standaloneWorkflow.Contains('node --check')) 'The Node workflow should check JavaScript syntax.'
    Assert-True ($standaloneWorkflow.Contains('node tests/test.js')) 'The Node workflow should run the conventional dependency-free test suite.'

    $goModule = New-Fixture 'go-module'
    "module example.invalid/fixture`n`ngo 1.24`n" | Set-Content -LiteralPath (Join-Path $goModule 'go.mod') -Encoding ascii
    "package fixture`n`nfunc Value() int { return 42 }`n" | Set-Content -LiteralPath (Join-Path $goModule 'fixture.go') -Encoding ascii
    Commit-Fixture $goModule
    $goPreview = Invoke-Tool $goModule @('-OutputFormat', 'Json')
    Assert-True ($goPreview.ExitCode -eq 0) 'A Go module preview should succeed.'
    $goJson = $goPreview.Output | ConvertFrom-Json
    Assert-True ($goJson.selectedModules -contains 'go') 'go.mod should select the Go module.'
    $goApply = Invoke-Tool $goModule @('-Apply', '-OutputFormat', 'Json')
    Assert-True ($goApply.ExitCode -eq 0) 'A Go module repository should accept deployment.'
    $goWorkflowPath = Join-Path $goModule '.github\workflows\quality-go.yml'
    Assert-True (Test-Path -LiteralPath $goWorkflowPath) 'The Go workflow should be deployed.'
    $goWorkflow = Get-Content -LiteralPath $goWorkflowPath -Raw
    Assert-True ($goWorkflow.Contains('gofmt')) 'The Go workflow should enforce formatting.'
    Assert-True ($goWorkflow.Contains('go vet ./...')) 'The Go workflow should run go vet.'
    Assert-True ($goWorkflow.Contains('go test ./...')) 'The Go workflow should run tests.'
    Assert-True ($goWorkflow.Contains('go build ./...')) 'The Go workflow should build packages.'

    $invalid = New-Fixture 'invalid-powershell'
    'param(; Write-Output "broken"' | Set-Content -LiteralPath (Join-Path $invalid 'broken.ps1') -Encoding ascii
    Commit-Fixture $invalid
    $invalidApply = Invoke-Tool $invalid @('-Apply', '-OutputFormat', 'Json')
    Assert-True ($invalidApply.ExitCode -ne 0) 'Invalid existing PowerShell should stop deployment.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $invalid '.repository-quality-gates.json'))) 'A failed preflight should not create managed state.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $invalid '.githooks'))) 'A failed preflight should not copy quality-gate files.'

    $conflict = New-Fixture 'unmanaged-conflict'
    New-Item -ItemType Directory -Path (Join-Path $conflict '.github\workflows') -Force | Out-Null
    'name: Existing Secret Scan' | Set-Content -LiteralPath (Join-Path $conflict '.github\workflows\secret-scanning.yml') -Encoding utf8
    Commit-Fixture $conflict
    $blocked = Invoke-Tool $conflict @('-Apply', '-OutputFormat', 'Json')
    Assert-True ($blocked.ExitCode -ne 0) 'An unmanaged target-path conflict should stop apply.'

    $preserved = New-Fixture 'preserved-module'
    New-Item -ItemType Directory -Path (Join-Path $preserved '.github\workflows') -Force | Out-Null
    "name: Existing Security`nsteps:`n  - run: gitleaks detect" | Set-Content -LiteralPath (Join-Path $preserved '.github\workflows\ci.yml') -Encoding utf8
    'title = "Existing Project Policy"' | Set-Content -LiteralPath (Join-Path $preserved '.gitleaks.toml') -Encoding utf8
    Commit-Fixture $preserved
    $preservePreview = Invoke-Tool $preserved @('-PreserveExistingModule', 'secret-scanning', '-OutputFormat', 'Json')
    Assert-True ($preservePreview.ExitCode -eq 0) 'Preview should accept an applicable preserved module.'
    $preserveJson = $preservePreview.Output | ConvertFrom-Json
    Assert-True ($preserveJson.selectedModules -contains 'secret-scanning') 'A preserved module should remain detected.'
    Assert-True ($preserveJson.managedModules -notcontains 'secret-scanning') 'A preserved module should not deploy template payload files.'
    Assert-True (@($preserveJson.preservationEvidence).Count -gt 0) 'A preserved module should report matching workflow evidence.'
    Assert-True (@($preserveJson.plan | Where-Object path -eq '.gitleaks.toml').Count -eq 0) 'A preserved module should not conflict with its existing project policy.'
    $preserveApply = Invoke-Tool $preserved @('-Apply', '-PreserveExistingModule', 'secret-scanning', '-OutputFormat', 'Json')
    Assert-True ($preserveApply.ExitCode -eq 0) 'Apply should retain a verified existing module without requiring overlap acknowledgement.'
    $preservedState = Get-Content -LiteralPath (Join-Path $preserved '.repository-quality-gates.json') -Raw | ConvertFrom-Json
    Assert-True ($preservedState.preservedModules -contains 'secret-scanning') 'Managed state should record preserved existing modules.'

    $unverified = New-Fixture 'unverified-preserved-module'
    'fixture' | Set-Content -LiteralPath (Join-Path $unverified 'README.md') -Encoding ascii
    Commit-Fixture $unverified
    $unverifiedApply = Invoke-Tool $unverified @('-Apply', '-PreserveExistingModule', 'secret-scanning', '-OutputFormat', 'Json')
    Assert-True ($unverifiedApply.ExitCode -ne 0) 'Apply should reject a preserved module without matching workflow evidence.'

    $ignoredManaged = New-Fixture 'ignored-managed-files'
    [IO.File]::WriteAllText((Join-Path $ignoredManaged '.gitignore'), "*secrets*`n", [Text.UTF8Encoding]::new($false))
    'fixture' | Set-Content -LiteralPath (Join-Path $ignoredManaged 'README.md') -Encoding ascii
    Commit-Fixture $ignoredManaged
    $ignoredPreview = Invoke-Tool $ignoredManaged @('-OutputFormat', 'Json')
    Assert-True ($ignoredPreview.ExitCode -eq 0) 'Preview should handle required managed files matched by an existing ignore rule.'
    $ignoredJson = $ignoredPreview.Output | ConvertFrom-Json
    Assert-True ($ignoredJson.managedUnignoreLines -contains '!/scripts/Configure-SecretScanning.ps1') 'Preview should report the exact Configure script exception.'
    Assert-True ($ignoredJson.managedUnignoreLines -contains '!/scripts/Test-Secrets.ps1') 'Preview should report the exact Test script exception.'
    $ignoredApply = Invoke-Tool $ignoredManaged @('-Apply', '-OutputFormat', 'Json')
    Assert-True ($ignoredApply.ExitCode -eq 0) 'Apply should add exact managed-file exceptions.'
    & git -C $ignoredManaged check-ignore --quiet --no-index -- scripts/Configure-SecretScanning.ps1
    Assert-True ($LASTEXITCODE -eq 1) 'The required Configure script should no longer be ignored.'
    & git -C $ignoredManaged check-ignore --quiet --no-index -- scripts/Test-Secrets.ps1
    Assert-True ($LASTEXITCODE -eq 1) 'The required Test script should no longer be ignored.'

    $docsOnly = New-Fixture 'docs-only'
    '# Documentation fixture' | Set-Content -LiteralPath (Join-Path $docsOnly 'README.md') -Encoding ascii
    Commit-Fixture $docsOnly
    $docsApply = Invoke-Tool $docsOnly @('-Apply', '-OutputFormat', 'Json')
    Assert-True ($docsApply.ExitCode -eq 0) 'A documentation-only repository should accept the initial deployment.'
    $docsSecondPreview = Invoke-Tool $docsOnly @('-OutputFormat', 'Json')
    Assert-True ($docsSecondPreview.ExitCode -eq 0) 'A repeated documentation-only preview should succeed.'
    $docsSecondJson = $docsSecondPreview.Output | ConvertFrom-Json
    Assert-True (-not ($docsSecondJson.selectedModules -contains 'powershell')) 'Managed secret-scanning helpers must not trigger the PowerShell module.'
    Assert-True (@($docsSecondJson.plan | Where-Object action -notin @('Unchanged')).Count -eq 0) 'A repeated documentation-only preview should remain idempotent.'

    $languageTransition = New-Fixture 'language-transition'
    'print("fixture")' | Set-Content -LiteralPath (Join-Path $languageTransition 'tool.py') -Encoding ascii
    '# Language transition fixture' | Set-Content -LiteralPath (Join-Path $languageTransition 'README.md') -Encoding ascii
    Commit-Fixture $languageTransition
    $transitionApply = Invoke-Tool $languageTransition @('-Apply', '-OutputFormat', 'Json')
    Assert-True ($transitionApply.ExitCode -eq 0) 'The initial Python repository should accept deployment.'
    $transitionCurrent = Invoke-DriftCheck $languageTransition
    Assert-True ($transitionCurrent.ExitCode -eq 0) 'The initial Python repository should have no module drift.'

    & git -C $languageTransition rm -- tool.py | Out-Null
    '<?php echo "fixture";' | Set-Content -LiteralPath (Join-Path $languageTransition 'tool.php') -Encoding ascii
    $transitionDrift = Invoke-DriftCheck $languageTransition
    Assert-True ($transitionDrift.ExitCode -eq 2) 'A Python-to-PHP conversion should fail until the PHP module is deployed.'
    $transitionDriftJson = $transitionDrift.Output | ConvertFrom-Json
    Assert-True ($transitionDriftJson.missingModules -contains 'php') 'A Python-to-PHP conversion should report the missing PHP module.'
    Assert-True ($transitionDriftJson.staleModules -contains 'python') 'A Python-to-PHP conversion should report the stale Python module.'

    $transitionReport = Invoke-DriftCheck $languageTransition @('-ReportOnly')
    Assert-True ($transitionReport.ExitCode -eq 0) 'Pull-request reporting should describe drift without failing.'
    $transitionReconcile = Invoke-AutomaticReconciliation $languageTransition
    Assert-True ($transitionReconcile.ExitCode -eq 0) "Automatic reconciliation should add PHP and prune Python. $($transitionReconcile.Output)"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $languageTransition '.github\workflows\quality-python.yml'))) 'Automatic reconciliation should remove the obsolete unchanged Python workflow.'
    Assert-True (Test-Path -LiteralPath (Join-Path $languageTransition '.github\workflows\quality-php.yml')) 'Automatic reconciliation should add the newly required PHP workflow.'
    $transitionFinal = Invoke-DriftCheck $languageTransition
    Assert-True ($transitionFinal.ExitCode -eq 0) 'The pruned PHP repository should pass module-drift validation.'
    $transitionFinalJson = $transitionFinal.Output | ConvertFrom-Json
    Assert-True ($transitionFinalJson.status -eq 'Current') 'The pruned PHP repository should report current modules.'

    $guard = Invoke-Tool $conflict @('-Push')
    Assert-True ($guard.ExitCode -ne 0) '-Push without -Apply and -Commit should be rejected.'

    $deployerText = Get-Content -LiteralPath $scriptPath -Raw
    Assert-True ($deployerText.Contains('Get-Command pwsh -ErrorAction SilentlyContinue')) 'The deployer should prefer the cross-platform PowerShell host.'
    Assert-True ($deployerText.Contains('Get-Command powershell.exe -ErrorAction Stop')) 'The deployer should retain a Windows PowerShell fallback.'
    $directHelperPattern = '& \(Join-Path \$script:RepositoryRoot ''scripts\\(?:Configure-SecretScanning|Install-Gitleaks|Test-Secrets)\.ps1''\)'
    Assert-True (-not ($deployerText -match $directHelperPattern)) 'Managed helper scripts should not be invoked directly from a network-backed checkout.'

    $versionOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Version 2>&1
    Assert-True ($LASTEXITCODE -eq 0) 'The version interface should succeed without a repository path.'
    Assert-True (($versionOutput -join "`n").Contains('Repository Quality Gates 1.0.1')) 'The version interface should report the canonical version.'

    Write-Host "$passed assertions passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
