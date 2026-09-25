# SPDX-License-Identifier: MIT
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
        $output = & pwsh @all 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join [Environment]::NewLine) }
    } finally { $ErrorActionPreference = $previousPreference }
}

function Invoke-DriftCheck([string]$Repository, [string[]]$Arguments = @()) {
    $driftScript = Join-Path $Repository 'scripts\Test-QualityGateModuleDrift.ps1'
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $driftScript, '-RepositoryPath', $Repository, '-OutputFormat', 'Json') + $Arguments
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & pwsh @all 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join [Environment]::NewLine) }
    } finally { $ErrorActionPreference = $previousPreference }
}

function Invoke-AutomaticReconciliation([string]$Repository) {
    $script = Join-Path $Repository 'scripts\Invoke-AutomaticQualityGateReconciliation.ps1'
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & pwsh -NoProfile -File $script -RepositoryPath $Repository -OutputFormat Json 2>&1
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
    Assert-True ($previewJson.selectedModules -contains 'licensing') 'Universal RQG licensing attribution should be selected.'
    Assert-True ($previewJson.selectedModules -contains 'node') 'Node should be detected.'
    Assert-True ($previewJson.selectedModules -contains 'powershell') 'PowerShell should be detected.'
    Assert-True ($previewJson.selectedModules -contains 'python') 'Script-only Python should be detected.'
    Assert-True ($previewJson.selectedModules -contains 'php') 'Script-only PHP should be detected.'
    Assert-True ($previewJson.selectedModules -contains 'shell') 'Shell scripts should be detected.'
    Assert-True (-not ($previewJson.selectedModules -contains 'dotnet')) '.NET should not be selected from an ignored dependency marker.'

    $apply = Invoke-Tool $mixed @('-Apply', '-OutputFormat', 'Json')
    Assert-True ($apply.ExitCode -eq 0) "Apply should succeed on a clean fixture. $($apply.Output)"
    Assert-True (Test-Path -LiteralPath (Join-Path $mixed '.repository-quality-gates.json')) 'Managed state should be created.'
    Assert-True (Test-Path -LiteralPath (Join-Path $mixed 'LICENSES\Repository-Quality-Gates-MIT.txt')) 'The RQG MIT attribution file should be deployed universally.'
    $deployedLicence = Get-Content -LiteralPath (Join-Path $mixed 'LICENSES\Repository-Quality-Gates-MIT.txt') -Raw
    Assert-True ($deployedLicence.Contains('MIT License')) 'The deployed RQG attribution file should contain the MIT license.'
    Assert-True ($deployedLicence.Contains('applies only to `.repository-quality-gates.json`')) 'The deployed RQG attribution file should scope the MIT license to the managed-state file.'
    Assert-True ($deployedLicence.Contains("files identified as Repository Quality Gates-managed files in its ``files``")) 'The deployed RQG attribution file should scope the MIT license to files recorded as RQG-managed.'
    Assert-True ($deployedLicence.Contains("remain subject to the downstream project's own licensing")) 'The deployed RQG attribution file should preserve the downstream project licence boundary.'
    Assert-True (Test-Path -LiteralPath (Join-Path $mixed '.github\workflows\quality-node.yml')) 'The Node workflow should be deployed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $mixed '.github\workflows\quality-powershell.yml')) 'The PowerShell workflow should be deployed.'
    $powerShellWorkflow = [IO.File]::ReadAllText((Join-Path $mixed '.github\workflows\quality-powershell.yml'))
    Assert-True ($powerShellWorkflow.Contains('shell: pwsh')) 'The PowerShell workflow should run its script steps with PowerShell 7.'
    Assert-True (-not $powerShellWorkflow.Contains('shell: powershell')) 'The PowerShell workflow should not invoke Windows PowerShell 5.1.'
    Assert-True ($powerShellWorkflow.Contains('vars.RQG_WINDOWS_RUNS_ON')) 'The PowerShell workflow should support configured self-hosted Windows runners.'
    Assert-True ($powerShellWorkflow.Contains("github.event.pull_request.head.repo.full_name != github.repository")) 'The PowerShell workflow should keep fork pull requests off self-hosted runners.'
    Assert-True ($powerShellWorkflow.Contains('!github.event.repository.private')) 'The PowerShell workflow should keep public repositories off self-hosted runners.'
    $secretWorkflow = [IO.File]::ReadAllText((Join-Path $mixed '.github\workflows\secret-scanning.yml'))
    Assert-True ($secretWorkflow.Contains('shell: pwsh')) 'The secret-scanning workflow should run its script steps with PowerShell 7.'
    Assert-True (-not $secretWorkflow.Contains('shell: powershell')) 'The secret-scanning workflow should not invoke Windows PowerShell 5.1.'
    Assert-True ($secretWorkflow.Contains('vars.RQG_WINDOWS_RUNS_ON')) 'The secret-scanning workflow should support configured self-hosted Windows runners.'
    $documentationWorkflow = [IO.File]::ReadAllText((Join-Path $projectRoot 'modules\documentation\payload\.github\workflows\quality-documentation.yml'))
    Assert-True ($documentationWorkflow.Contains('vars.RQG_LINUX_RUNS_ON')) 'The documentation workflow should support configured self-hosted Linux runners.'
    Assert-True ($documentationWorkflow.Contains("github.event.pull_request.head.repo.full_name != github.repository")) 'The documentation workflow should keep fork pull requests off self-hosted runners.'
    Assert-True ($documentationWorkflow.Contains('!github.event.repository.private')) 'The documentation workflow should keep public repositories off self-hosted runners.'
    foreach ($hookName in @('pre-commit', 'pre-push')) {
        $hookText = [IO.File]::ReadAllText((Join-Path $mixed ".githooks\$hookName"))
        Assert-True ($hookText.Contains('exec pwsh ')) "The $hookName hook should invoke PowerShell 7."
        Assert-True ($hookText.Contains('-ExecutionPolicy Bypass')) "The $hookName hook should support repositories reached through a trusted network mapping."
        Assert-True (-not $hookText.Contains('powershell.exe')) "The $hookName hook should not invoke Windows PowerShell 5.1."
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $mixed '.github\workflows\quality-python.yml')) 'The Python workflow should be deployed.'
    $pythonWorkflow = [IO.File]::ReadAllText((Join-Path $mixed '.github\workflows\quality-python.yml'))
    Assert-True ($pythonWorkflow.Contains('requirements-dev.txt')) 'The Python workflow should install development requirements before running tests.'
    Assert-True (Test-Path -LiteralPath (Join-Path $mixed '.github\workflows\quality-php.yml')) 'The PHP workflow should be deployed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $mixed '.github\workflows\quality-shell.yml')) 'The shell workflow should be deployed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $mixed '.github\workflows\quality-module-drift.yml')) 'The automatic module-drift workflow should be deployed universally.'
    $moduleDriftWorkflow = [IO.File]::ReadAllText((Join-Path $mixed '.github\workflows\quality-module-drift.yml'))
    Assert-True ($moduleDriftWorkflow.Contains("if: github.ref_type == 'branch'")) 'Automatic reconciliation should be restricted to branch references and must not mutate tag checkouts.'
    Assert-True ($moduleDriftWorkflow.Contains("'quality-module-drift', 'update-managed-repositories'")) 'Post-reconciliation validation must not redispatch the module-drift or central fleet-update workflows.'
    Assert-True ($moduleDriftWorkflow.Contains("steps.commit_reconciliation.outputs.reconciled == 'true'")) 'Validation dispatch must require an explicit successful reconciliation output.'
    Assert-True ($moduleDriftWorkflow.Contains('git diff --cached --name-only')) 'The reconciliation decision must use the staged Git index instead of runner-specific status output.'
    Assert-True (Test-Path -LiteralPath (Join-Path $projectRoot '.github\workflows\update-managed-repositories.yml')) 'The central template should provide a fleet-update workflow.'
    Assert-True (Test-Path -LiteralPath (Join-Path $projectRoot 'scripts\Invoke-RepositoryQualityGateFleetUpdate.ps1')) 'The central template should provide the fleet updater.'
    Assert-True (Test-Path -LiteralPath (Join-Path $projectRoot 'scripts\Update-RepositoryQualityGates.ps1')) 'The central template should provide the single-repository updater.'
    $fleetWorkflow = [IO.File]::ReadAllText((Join-Path $projectRoot '.github\workflows\update-managed-repositories.yml'))
    Assert-True ($fleetWorkflow.Contains('Invoke-RepositoryQualityGateAppFleetUpdate.ps1 -AutoEnroll -Apply -AutoMerge')) 'The fleet workflow should update every GitHub App installation through the cross-owner wrapper.'
    Assert-True (-not $fleetWorkflow.Contains('github.repository_owner')) 'The fleet workflow should not limit discovery to the central repository owner.'
    Assert-True ($fleetWorkflow.Contains('-Apply -AutoMerge')) 'The fleet workflow should request automatic downstream completion.'
    Assert-True ($fleetWorkflow.Contains("cron: '23 4 * * *'")) 'The fleet workflow should retry deferred repositories every day.'
    Assert-True ($fleetWorkflow.Contains('release_tag:')) 'The fleet workflow should accept an exact release tag from the automatic release workflow.'
    Assert-True ($fleetWorkflow.Contains('PUBLISHED_RELEASE_TAG: ${{ github.event.release.tag_name }}')) 'Release-event fleet runs should use the exact published release tag.'
    Assert-True ($fleetWorkflow.Contains('gh release view $tag --repo $env:GITHUB_REPOSITORY --json tagName,isDraft,isPrerelease')) 'The fleet workflow should verify its selected tag against the explicit central repository before checkout.'
    $fleetScript = [IO.File]::ReadAllText((Join-Path $projectRoot 'scripts\Invoke-RepositoryQualityGateFleetUpdate.ps1'))
    $appFleetScript = [IO.File]::ReadAllText((Join-Path $projectRoot 'scripts\Invoke-RepositoryQualityGateAppFleetUpdate.ps1'))
    Assert-True ($appFleetScript.Contains("OutputFormat = 'Json'")) 'Cross-owner fleet runs should retain complete structured per-repository diagnostics.'
    Assert-True ($fleetScript.Contains('gh pr list --repo $RepositoryName --state open --limit 1000')) 'The fleet updater should inspect all open pull requests before changing a downstream repository.'
    Assert-True ($fleetScript.Contains("status = 'DeferredOpenPullRequests'")) 'A repository with an open pull request should be explicitly deferred.'
    Assert-True ($fleetScript.Contains('No RQG branch was pushed.')) 'The fleet updater should check again immediately before publishing its temporary branch.'
    Assert-True ($fleetScript.Contains('gh pr close')) 'Expired or failed RQG pull requests should be closed automatically.'
    Assert-True ($fleetScript.Contains('--delete-branch')) 'Temporary RQG branches should be removed after merge, expiry, or failed setup.'
    Assert-True ($fleetScript.Contains('TemporaryBranchLifetimeHours = 24')) 'The default temporary branch inspection window should be limited to 24 hours.'
    Assert-True ($fleetScript.IndexOf('$openPullRequests = @(Get-OpenPullRequests $fullName)') -lt $fleetScript.IndexOf('gh repo clone')) 'The initial open-pull-request gate must run before cloning or preparing an update.'
    Assert-True ($fleetScript.IndexOf('$lateOpenPullRequests = @(Get-OpenPullRequests $fullName)') -lt $fleetScript.IndexOf('& git -C $clonePath fetch origin')) 'The second open-pull-request gate must run before publishing the temporary branch.'
    Assert-True ($fleetScript.Contains('gh api --method PUT "repos/$repositoryName/pulls/$pullRequestNumber/merge"')) 'The fleet updater should merge verified pull requests through the GitHub REST API.'
    Assert-True (-not $fleetScript.Contains('gh pr merge')) 'The fleet updater should not depend on the GitHub CLI GraphQL merge path.'
    Assert-True ($fleetScript.Contains('Wait-PullRequestQualityChecks')) 'Downstream updates should explicitly wait for reported quality checks.'
    Assert-True ($fleetScript.Contains('-f merge_method=squash')) 'Verified downstream updates should use squash merging.'
    Assert-True ($fleetScript.Contains('gh api --method DELETE "repos/$repositoryName/git/refs/heads/$branchName"')) 'Verified downstream updates should remove their temporary version branch.'
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

    $statePath = Join-Path $mixed '.repository-quality-gates.json'
    $originalStateAttributes = [IO.File]::GetAttributes($statePath)
    [IO.File]::SetAttributes($statePath, ($originalStateAttributes -bor [IO.FileAttributes]::Hidden))
    $hiddenStateApply = Invoke-Tool $mixed @('-Apply', '-AllowDirtyWorkingTree', '-OutputFormat', 'Json')
    Assert-True ($hiddenStateApply.ExitCode -eq 0) "Apply should refresh a hidden managed-state file. $($hiddenStateApply.Output)"
    Assert-True (([IO.File]::GetAttributes($statePath) -band [IO.FileAttributes]::Hidden) -ne 0) 'Apply should restore the hidden attribute after refreshing managed state.'
    [IO.File]::SetAttributes($statePath, $originalStateAttributes)

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
    "name: Existing Documentation Check`nsteps:`n  - run: markdownlint README.md" | Set-Content -LiteralPath (Join-Path $preserved '.github\workflows\ci.yml') -Encoding utf8
    '# Fixture' | Set-Content -LiteralPath (Join-Path $preserved 'README.md') -Encoding utf8
    $preservedRulesText = @'
{
  "schemaVersion": 1,
  "modules": {
    "include": [],
    "repositoryOwned": ["documentation"]
  },
  "secretScanning": {
    "additionalConfigFiles": []
  }
}
'@
    [IO.File]::WriteAllText((Join-Path $preserved '.repository-quality-gates.local.json'), $preservedRulesText.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n", [Text.UTF8Encoding]::new($false))
    Commit-Fixture $preserved
    $preservePreview = Invoke-Tool $preserved @('-OutputFormat', 'Json')
    Assert-True ($preservePreview.ExitCode -eq 0) 'Preview should accept an applicable preserved module.'
    $preserveJson = $preservePreview.Output | ConvertFrom-Json
    Assert-True ($preserveJson.selectedModules -contains 'documentation') 'A preserved module should remain detected.'
    Assert-True ($preserveJson.managedModules -notcontains 'documentation') 'A preserved module should not deploy template payload files.'
    Assert-True (@($preserveJson.preservationEvidence).Count -gt 0) 'A preserved module should report matching workflow evidence.'
    Assert-True (@($preserveJson.plan | Where-Object path -eq '.github/workflows/quality-documentation.yml').Count -eq 0) 'A preserved module should not deploy the central workflow over its existing implementation.'
    Assert-True ($preserveJson.repositoryRulesFile -eq '.repository-quality-gates.local.json') 'Preview should report the downstream repository rules file.'
    $preserveApply = Invoke-Tool $preserved @('-Apply', '-OutputFormat', 'Json')
    Assert-True ($preserveApply.ExitCode -eq 0) 'Apply should retain a verified existing module without requiring overlap acknowledgement.'
    $preservedState = Get-Content -LiteralPath (Join-Path $preserved '.repository-quality-gates.json') -Raw | ConvertFrom-Json
    Assert-True ($preservedState.preservedModules -contains 'documentation') 'Managed state should record preserved existing modules.'
    Assert-True (@($preservedState.files | Where-Object path -eq '.repository-quality-gates.local.json').Count -eq 0) 'The downstream repository rules file must never become managed state.'

    $ownedPath = New-Fixture 'repository-owned-path'
    $ownedPolicyPath = Join-Path $ownedPath '.gitleaks.toml'
    $ownedPolicy = "title = `"Repository Policy`"`n`n[extend]`npath = `"security/gitleaks-portable.toml`"`n`n# repository-owned exception`n"
    [IO.File]::WriteAllText($ownedPolicyPath, $ownedPolicy, [Text.UTF8Encoding]::new($false))
    $ownedPathRules = '{"schemaVersion":1,"paths":{"repositoryOwned":[".gitleaks.toml"]}}'
    [IO.File]::WriteAllText((Join-Path $ownedPath '.repository-quality-gates.local.json'), $ownedPathRules + "`n", [Text.UTF8Encoding]::new($false))
    Commit-Fixture $ownedPath
    $ownedHashBefore = (Get-FileHash -LiteralPath $ownedPolicyPath -Algorithm SHA256).Hash
    $ownedApply = Invoke-Tool $ownedPath @('-Apply', '-OutputFormat', 'Json')
    Assert-True ($ownedApply.ExitCode -eq 0) "A declared repository-owned path should not block universal module deployment. $($ownedApply.Output)"
    Assert-True ((Get-FileHash -LiteralPath $ownedPolicyPath -Algorithm SHA256).Hash -eq $ownedHashBefore) 'RQG must preserve a declared repository-owned path byte for byte.'
    $ownedState = Get-Content -LiteralPath (Join-Path $ownedPath '.repository-quality-gates.json') -Raw | ConvertFrom-Json
    Assert-True (@($ownedState.files | Where-Object path -eq '.gitleaks.toml').Count -eq 0) 'A repository-owned path must remain outside managed state.'

    $adopted = New-Fixture 'adopted-historical-file'
    New-Item -ItemType Directory -Path (Join-Path $adopted '.github\workflows') -Force | Out-Null
    $adoptedPath = Join-Path $adopted '.github\workflows\secret-scanning.yml'
    [IO.File]::WriteAllText($adoptedPath, "name: Historical RQG Secret Scan`n", [Text.UTF8Encoding]::new($false))
    Commit-Fixture $adopted
    $adoptedHash = (Get-FileHash -LiteralPath $adoptedPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $adoptPreview = Invoke-Tool $adopted @('-AdoptExistingManagedFile', ".github/workflows/secret-scanning.yml=$adoptedHash", '-OutputFormat', 'Json')
    Assert-True ($adoptPreview.ExitCode -eq 0) "A file with an explicitly verified historical hash should be adoptable. $($adoptPreview.Output)"
    $adoptJson = $adoptPreview.Output | ConvertFrom-Json
    Assert-True ((@($adoptJson.plan | Where-Object path -eq '.github/workflows/secret-scanning.yml')[0]).action -eq 'Update') 'A verified historical file should become a managed update.'
    $adoptMismatch = Invoke-Tool $adopted @('-AdoptExistingManagedFile', '.github/workflows/secret-scanning.yml=0000000000000000000000000000000000000000000000000000000000000000', '-Apply', '-OutputFormat', 'Json')
    Assert-True ($adoptMismatch.ExitCode -ne 0) 'A historical-file adoption with the wrong hash must remain blocked.'

    $universalOwned = New-Fixture 'universal-repository-owned'
    New-Item -ItemType Directory -Path (Join-Path $universalOwned '.github\workflows') -Force | Out-Null
    "name: Existing Security`nsteps:`n  - run: gitleaks detect" | Set-Content -LiteralPath (Join-Path $universalOwned '.github\workflows\ci.yml') -Encoding utf8
    $universalOwnedRulesText = @'
{
  "schemaVersion": 1,
  "modules": {
    "include": [],
    "repositoryOwned": ["secret-scanning"]
  },
  "secretScanning": {
    "additionalConfigFiles": []
  }
}
'@
    [IO.File]::WriteAllText((Join-Path $universalOwned '.repository-quality-gates.local.json'), $universalOwnedRulesText.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n", [Text.UTF8Encoding]::new($false))
    Commit-Fixture $universalOwned
    $universalOwnedPreview = Invoke-Tool $universalOwned @('-OutputFormat', 'Json')
    Assert-True ($universalOwnedPreview.ExitCode -ne 0) 'Repository rules must not replace a universal quality-gate module.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $universalOwned '.repository-quality-gates.json'))) 'Rejected universal-module ownership must not create managed state.'

    $licensingOwned = New-Fixture 'licensing-repository-owned'
    $licensingOwnedRulesText = '{"schemaVersion":1,"modules":{"repositoryOwned":["licensing"]}}'
    [IO.File]::WriteAllText((Join-Path $licensingOwned '.repository-quality-gates.local.json'), $licensingOwnedRulesText + "`n", [Text.UTF8Encoding]::new($false))
    Commit-Fixture $licensingOwned
    $licensingOwnedPreview = Invoke-Tool $licensingOwned @('-OutputFormat', 'Json')
    Assert-True ($licensingOwnedPreview.ExitCode -ne 0) 'Repository rules must not suppress universal RQG licensing attribution.'

    $invalidEnrollmentRule = New-Fixture 'invalid-enrollment-rule'
    $invalidEnrollmentRulesText = @'
{
  "schemaVersion": 1,
  "automaticEnrollment": "false"
}
'@
    [IO.File]::WriteAllText((Join-Path $invalidEnrollmentRule '.repository-quality-gates.local.json'), $invalidEnrollmentRulesText.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n", [Text.UTF8Encoding]::new($false))
    Commit-Fixture $invalidEnrollmentRule
    $invalidEnrollmentPreview = Invoke-Tool $invalidEnrollmentRule @('-OutputFormat', 'Json')
    Assert-True ($invalidEnrollmentPreview.ExitCode -ne 0) 'The automaticEnrollment repository rule must be a Boolean.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $invalidEnrollmentRule '.repository-quality-gates.json'))) 'An invalid automatic-enrolment rule must not create managed state.'

    $validPullRequestRule = New-Fixture 'valid-pull-request-rule'
    $validPullRequestRulesText = '{"schemaVersion":1,"pullRequest":{"references":["OP#PROJECT-123","OP#PROJECT-456"]}}'
    [IO.File]::WriteAllText((Join-Path $validPullRequestRule '.repository-quality-gates.local.json'), $validPullRequestRulesText + "`n", [Text.UTF8Encoding]::new($false))
    Commit-Fixture $validPullRequestRule
    $validPullRequestPreview = Invoke-Tool $validPullRequestRule @('-OutputFormat', 'Json')
    Assert-True ($validPullRequestPreview.ExitCode -eq 0) "Valid OpenProject pull-request references should be accepted. $($validPullRequestPreview.Output)"

    $invalidPullRequestRule = New-Fixture 'invalid-pull-request-rule'
    $invalidPullRequestRulesText = '{"schemaVersion":1,"pullRequest":{"references":["PROJECT-123"]}}'
    [IO.File]::WriteAllText((Join-Path $invalidPullRequestRule '.repository-quality-gates.local.json'), $invalidPullRequestRulesText + "`n", [Text.UTF8Encoding]::new($false))
    Commit-Fixture $invalidPullRequestRule
    $invalidPullRequestPreview = Invoke-Tool $invalidPullRequestRule @('-OutputFormat', 'Json')
    Assert-True ($invalidPullRequestPreview.ExitCode -ne 0) 'A pull-request reference without the OP# prefix must be rejected.'

    $mixedPullRequestRule = New-Fixture 'mixed-pull-request-rule'
    $mixedPullRequestRulesText = '{"schemaVersion":1,"pullRequest":{"references":["OP#PROJECT-123","OP#OTHER-456"]}}'
    [IO.File]::WriteAllText((Join-Path $mixedPullRequestRule '.repository-quality-gates.local.json'), $mixedPullRequestRulesText + "`n", [Text.UTF8Encoding]::new($false))
    Commit-Fixture $mixedPullRequestRule
    $mixedPullRequestPreview = Invoke-Tool $mixedPullRequestRule @('-OutputFormat', 'Json')
    Assert-True ($mixedPullRequestPreview.ExitCode -ne 0) 'Pull-request references from different OpenProject projects must be rejected.'

    $unverified = New-Fixture 'unverified-preserved-module'
    'fixture' | Set-Content -LiteralPath (Join-Path $unverified 'README.md') -Encoding ascii
    Commit-Fixture $unverified
    $unverifiedApply = Invoke-Tool $unverified @('-Apply', '-PreserveExistingModule', 'secret-scanning', '-OutputFormat', 'Json')
    Assert-True ($unverifiedApply.ExitCode -ne 0) 'Apply should reject preserving a universal module outside RQG management.'

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
    $managedDocumentationPath = Join-Path $docsOnly '.github\workflows\quality-documentation.yml'
    $managedDocumentationText = [IO.File]::ReadAllText($managedDocumentationPath).Replace("`r`n", "`n").Replace("`n", "`r`n")
    [IO.File]::WriteAllText($managedDocumentationPath, $managedDocumentationText, [Text.UTF8Encoding]::new($false))
    $docsCrlfPreview = Invoke-Tool $docsOnly @('-OutputFormat', 'Json')
    Assert-True ($docsCrlfPreview.ExitCode -eq 0) 'A managed text file checked out with CRLF line endings should remain valid.'
    $docsCrlfJson = $docsCrlfPreview.Output | ConvertFrom-Json
    Assert-True (@($docsCrlfJson.plan | Where-Object action -notin @('Unchanged')).Count -eq 0) 'Line-ending conversion alone must not create managed-file drift.'

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
    Assert-True ($deployerText.Contains('PowerShell 7 (pwsh) is required')) 'The deployer should report its PowerShell 7 requirement clearly.'
    Assert-True (-not $deployerText.Contains('powershell.exe')) 'The deployer should not fall back to Windows PowerShell 5.1.'
    $directHelperPattern = '& \(Join-Path \$script:RepositoryRoot ''scripts\\(?:Configure-SecretScanning|Install-Gitleaks|Test-Secrets)\.ps1''\)'
    Assert-True (-not ($deployerText -match $directHelperPattern)) 'Managed helper scripts should not be invoked directly from a network-backed checkout.'

    $versionOutput = & pwsh -NoProfile -File $scriptPath -Version 2>&1
    Assert-True ($LASTEXITCODE -eq 0) 'The version interface should succeed without a repository path.'
    Assert-True (($versionOutput -join "`n").Contains('Repository Quality Gates 1.5.5')) 'The version interface should report the canonical version.'
    Assert-True (($versionOutput -join "`n").Contains('https://github.com/Cloud-Hub-Digital/repository-quality-gates')) 'The version interface should report the authoritative organization-owned repository.'

    Write-Host "$passed assertions passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
