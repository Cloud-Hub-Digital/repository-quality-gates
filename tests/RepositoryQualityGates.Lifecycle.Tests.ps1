# SPDX-License-Identifier: MIT
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$template=Split-Path -Parent $PSScriptRoot
. (Join-Path $template 'scripts/RepositoryQualityGates.Lifecycle.ps1')
$passed=0
function Assert-Lifecycle([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message };$script:passed++ }
function Assert-Rejected([scriptblock]$Action,[string]$Pattern) { $failure=$null;try { &$Action | Out-Null } catch { $failure=$_ }; Assert-Lifecycle ($null -ne $failure -and $failure.Exception.Message -match $Pattern) "Expected rejection: $Pattern" }
$root=Join-Path ([IO.Path]::GetTempPath()) ('rqg-lifecycle-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
function Write-LifecycleFixture([string]$Relative,[string]$Text) { $path=Join-Path $root $Relative;New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null;[IO.File]::WriteAllText($path,$Text,[Text.UTF8Encoding]::new($false)) }
function Save-LifecycleFixture { & git -C $root add -A; if ($LASTEXITCODE) { throw 'Fixture staging failed.' }; & git -C $root -c user.name='Fixture Author' -c user.email='fixture@example.invalid' -c core.hooksPath='' commit -qm 'test fixture';if ($LASTEXITCODE) { throw 'Fixture commit failed.' } }
try {
    Assert-Lifecycle (Get-RqgLifecycleEnabled $null) 'Absence should enable RQG.'
    Assert-Lifecycle (Get-RqgLifecycleEnabled ([pscustomobject]@{schemaVersion=1})) 'A missing flag should enable RQG.'
    Assert-Lifecycle (Get-RqgLifecycleEnabled ([pscustomobject]@{schemaVersion=1;rqgEnabled=$true})) 'True should enable RQG.'
    Assert-Lifecycle (-not (Get-RqgLifecycleEnabled ([pscustomobject]@{schemaVersion=1;rqgEnabled=$false}))) 'False should disable RQG.'
    Assert-Rejected { Get-RqgLifecycleEnabled ([pscustomobject]@{schemaVersion=1;automaticEnrollment=$false}) } 'unsupported'
    Assert-Rejected { Get-RqgLifecycleEnabled ([pscustomobject]@{schemaVersion=1;rqgEnabled='false'}) } 'true or false'
    Assert-Rejected { Get-RqgLifecycleEnabled ([pscustomobject]@{schemaVersion=2;rqgEnabled=$false}) } 'schemaVersion'
    & git -C $root init -q
    if ($LASTEXITCODE) { throw 'Fixture initialization failed.' }
    Write-LifecycleFixture '.repository-quality-gates.local.json' '{"schemaVersion":1,"rqgEnabled":false,"paths":{"repositoryOwned":["scripts/Install-GitHooks.ps1"]}}'
    $disabled=Invoke-RqgDeactivation $root $template
    Assert-Lifecycle ($disabled.status -eq 'Disabled' -and $disabled.changedPaths.Count -eq 0) 'An initially disabled repository must remain unchanged.'
    Write-LifecycleFixture 'product.txt' "Independent product content`n"
    Write-LifecycleFixture 'scripts/Install-GitHooks.ps1' 'Repository-owned hook installation'
    Write-LifecycleFixture '.githooks/pre-commit' 'Managed fixture hook'
    Write-LifecycleFixture '.gitignore' "/product-cache/`n/.tools/`n"
    $state=[ordered]@{schemaVersion=1;templateVersion='3.1.4';modules=@('secret-scanning');files=@(@{path='.githooks/pre-commit';module='secret-scanning';sha256=Get-RqgLifecycleHash (Join-Path $root '.githooks/pre-commit')},@{path='scripts/Install-GitHooks.ps1';module='secret-scanning';sha256='0'*64});ownedGitIgnoreLines=@('/.tools/')}
    Write-LifecycleFixture '.repository-quality-gates.json' ($state | ConvertTo-Json -Depth 8)
    Save-LifecycleFixture
    $originalProduct=[IO.File]::ReadAllBytes((Join-Path $root 'product.txt'))
    $rulesHash=Get-RqgLifecycleHash (Join-Path $root '.repository-quality-gates.local.json')
    $preview=Invoke-RqgDeactivation $root $template
    Assert-Lifecycle ($preview.status -eq 'DeactivationAvailable') 'Managed removal must preview before mutation.'
    Assert-Lifecycle (Test-Path -LiteralPath (Join-Path $root '.githooks/pre-commit')) 'Preview must retain every file.'
    Assert-Lifecycle ($preview.changedPaths -notcontains 'product.txt' -and $preview.changedPaths -notcontains 'scripts/Install-GitHooks.ps1') 'Product and repository-owned paths must be preserved.'
    Write-LifecycleFixture '.githooks/pre-commit' 'Modified fixture hook'
    Assert-Rejected { Invoke-RqgDeactivation $root $template -Apply } 'Modified managed file'
    Assert-Lifecycle (Test-Path -LiteralPath (Join-Path $root '.repository-quality-gates.json')) 'Conflict must retain the retry state.'
    Write-LifecycleFixture '.githooks/pre-commit' 'Managed fixture hook'
    $forged=$state | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $forged.files += [pscustomobject]@{path='product.txt';module='secret-scanning';sha256=Get-RqgLifecycleHash (Join-Path $root 'product.txt')}
    Write-LifecycleFixture '.repository-quality-gates.json' ($forged | ConvertTo-Json -Depth 8)
    Assert-Rejected { Invoke-RqgDeactivation $root $template } 'Unproven RQG ownership'
    $forged.files[-1].path='../outside.txt'
    Write-LifecycleFixture '.repository-quality-gates.json' ($forged | ConvertTo-Json -Depth 8)
    Assert-Rejected { Invoke-RqgDeactivation $root $template } 'Unsafe lifecycle'
    Write-LifecycleFixture '.repository-quality-gates.json' ($state | ConvertTo-Json -Depth 8)
    Write-LifecycleFixture '.gitignore' "/product-cache/`n/.tools/`n/.tools/`n"
    Assert-Rejected { Invoke-RqgDeactivation $root $template } 'Ambiguous duplicated'
    Write-LifecycleFixture '.gitignore' "/product-cache/`n/.tools/`n"
    $removed=Invoke-RqgDeactivation $root $template -Apply
    Assert-Lifecycle ($removed.status -eq 'Deactivated') 'An unchanged owned installation should be removed.'
    Assert-Lifecycle (-not (Test-Path -LiteralPath (Join-Path $root '.repository-quality-gates.json'))) 'State must be removed after owned content.'
    Assert-Lifecycle (-not (Test-Path -LiteralPath (Join-Path $root '.githooks/pre-commit'))) 'The owned hook must be removed.'
    Assert-Lifecycle ((Get-RqgLifecycleHash (Join-Path $root '.repository-quality-gates.local.json')) -eq $rulesHash) 'The explicit disabled marker must remain unchanged.'
    Assert-Lifecycle ([IO.File]::ReadAllText((Join-Path $root '.gitignore')) -ceq "/product-cache/`n") 'Only the proven owned ignore fragment may be removed.'
    Assert-Lifecycle ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root 'product.txt'))) -ceq [Convert]::ToBase64String($originalProduct)) 'Product bytes must remain identical.'
    Assert-Lifecycle ([IO.File]::ReadAllText((Join-Path $root 'scripts/Install-GitHooks.ps1')) -ceq 'Repository-owned hook installation') 'Repository-owned controls must remain intact.'
    Assert-Lifecycle ((Invoke-RqgDeactivation $root $template -Apply).status -eq 'Disabled') 'A repeated removal must be idempotent.'
    Write-LifecycleFixture '.repository-quality-gates.local.json' '{"schemaVersion":1,"rqgEnabled":true,"paths":{"repositoryOwned":["scripts/Install-GitHooks.ps1"]}}'
    Assert-Rejected { Invoke-RqgDeactivation $root $template } 'requires rqgEnabled'
    Save-LifecycleFixture
    $reenable=& pwsh -NoProfile -File (Join-Path $template 'scripts/Invoke-RepositoryQualityGates.ps1') -RepositoryPath $root -Apply -OutputFormat Json 2>&1
    Assert-Lifecycle ($LASTEXITCODE -eq 0) "Re-enabling must restore the current baseline. $($reenable -join [Environment]::NewLine)"
    Assert-Lifecycle (Test-Path -LiteralPath (Join-Path $root '.repository-quality-gates.json')) 'Re-enabling should restore managed state.'
    Assert-Lifecycle ([IO.File]::ReadAllText((Join-Path $root 'scripts/Install-GitHooks.ps1')) -ceq 'Repository-owned hook installation') 'Re-enabling must still preserve repository-owned controls.'
    Write-Output "$passed lifecycle assertions passed."
} finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
