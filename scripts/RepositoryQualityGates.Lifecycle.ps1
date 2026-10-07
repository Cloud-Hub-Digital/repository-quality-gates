# SPDX-License-Identifier: MIT
# Trusted controller library. Never load a destination repository's copy.
function Get-RqgManagedCheckNames([object[]]$Modules) {
    $names = @{
        documentation='Markdown Hygiene'; dotnet='.NET Build And Test'; go='Go Format, Vet, Test, And Build'
        licensing='Licence Decision'; 'module-drift'='Report Required Quality Gates'; node='JavaScript Syntax, Test, And Build'
        php='PHP Syntax And Project Test'; platformio='Firmware Build'; powershell='PowerShell And Regression Tests'
        python='Python Compile And Test'; 'secret-scanning'='Secret Scan'; shell='Shell Syntax'
    }
    return @($Modules | ForEach-Object { if ($names.ContainsKey([string]$_)) { [string]$names[[string]$_] } } | Sort-Object -Unique)
}

function Get-RqgLifecycleEnabled([object]$Rules) {
    if ($null -eq $Rules) { return $true }
    if ($Rules -isnot [pscustomobject] -or $Rules.schemaVersion -ne 1) { throw 'The repository lifecycle rules must use schemaVersion 1.' }
    if ($Rules.PSObject.Properties['automaticEnrollment']) { throw 'automaticEnrollment is unsupported; use rqgEnabled.' }
    if (-not $Rules.PSObject.Properties['rqgEnabled']) { return $true }
    if ($Rules.rqgEnabled -isnot [bool]) { throw 'rqgEnabled must be true or false.' }
    return [bool]$Rules.rqgEnabled
}

function Get-RqgLifecycleHash([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $bytes = [IO.File]::ReadAllBytes($Path)
    try { $bytes = [Text.UTF8Encoding]::new($false).GetBytes([Text.UTF8Encoding]::new($false, $true).GetString($bytes).Replace("`r`n", "`n").Replace("`r", "`n")) }
    catch [Text.DecoderFallbackException] { }
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Resolve-RqgLifecyclePath([string]$Root, [string]$Relative) {
    if (-not $Relative -or $Relative -match '(^[\\/]|:|\\|(^|/)\.\.?(/|$)|//)' -or $Relative -match '(?i)^\.git(?:/|$)' -or $Relative -in @('.repository-quality-gates.json','.repository-quality-gates.local.json','.gitignore')) { throw 'Unsafe lifecycle inventory path.' }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $target = [IO.Path]::GetFullPath((Join-Path $base $Relative))
    $comparison = if ([IO.Path]::DirectorySeparatorChar -eq '\') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $target.StartsWith($base + [IO.Path]::DirectorySeparatorChar, $comparison)) { throw 'Lifecycle path escapes its repository.' }
    $current = $base
    foreach ($part in $Relative.Split('/')) {
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Lifecycle paths cannot traverse filesystem links.' }
        }
    }
    return $target
}

function Invoke-RqgDeactivation([string]$RepositoryRoot, [string]$TemplateRoot, [switch]$Apply) {
    $statePath = Join-Path $RepositoryRoot '.repository-quality-gates.json'
    $rulesPath = Join-Path $RepositoryRoot '.repository-quality-gates.local.json'
    if (-not (Test-Path -LiteralPath $rulesPath -PathType Leaf) -or ((Get-Item -LiteralPath $rulesPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'A regular local rules file must explicitly disable RQG.' }
    $rules = [IO.File]::ReadAllText($rulesPath) | ConvertFrom-Json
    if (Get-RqgLifecycleEnabled $rules) { throw 'Deactivation requires rqgEnabled: false.' }
    $result = [ordered]@{ repository=$RepositoryRoot; status='Disabled'; selectedModules=@(); plan=@(); changedPaths=@() }
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return [pscustomobject]$result }
    if (((Get-Item -LiteralPath $statePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Managed state cannot be a filesystem link.' }
    $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    if ($state.schemaVersion -ne 1 -or -not $state.PSObject.Properties['files'] -or $state.files -isnot [array]) { throw 'Invalid deactivation inventory.' }
    # State alone is insufficient authority to delete product content. Each path
    # must also belong to the trusted catalogue's payload namespace and module.
    $catalog = Get-Content -LiteralPath (Join-Path $TemplateRoot 'modules/catalog.json') -Raw | ConvertFrom-Json
    $allowed = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $allowed['scripts/rqg-module-catalog.json'] = 'module-drift'
    $allowed['.rqg/template/scripts/Invoke-RepositoryQualityGates.ps1'] = 'module-drift'
    $allowed['.rqg/template/scripts/RepositoryQualityGates.Lifecycle.ps1'] = 'module-drift'
    $allowed['.rqg/template/modules/catalog.json'] = 'module-drift'
    foreach ($module in @($catalog.modules)) {
        $payloadRoot = Join-Path $TemplateRoot ([string]$module.source)
        foreach ($file in @(Get-ChildItem -LiteralPath $payloadRoot -File -Recurse -Force)) {
            $relative = [IO.Path]::GetRelativePath($payloadRoot, $file.FullName).Replace('\','/')
            if (-not ($module.PSObject.Properties['exclude'] -and $relative -in @($module.exclude))) { $allowed[$relative] = [string]$module.id }
            $allowed[('.rqg/template/' + [string]$module.source + '/' + $relative)] = 'module-drift'
        }
        if ($module.PSObject.Properties['gitignoreFragment']) { $allowed[('.rqg/template/' + [string]$module.gitignoreFragment)] = 'module-drift' }
    }
    $ownedPaths = if ($rules.PSObject.Properties['paths'] -and $rules.paths.PSObject.Properties['repositoryOwned']) { @($rules.paths.repositoryOwned) } else { @() }
    $ownedModules = if ($rules.PSObject.Properties['modules'] -and $rules.modules.PSObject.Properties['repositoryOwned']) { @($rules.modules.repositoryOwned) } else { @() }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $plan = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($state.files)) {
        $relative = [string]$entry.path
        $target = Resolve-RqgLifecyclePath $RepositoryRoot $relative
        if (-not $seen.Add($relative)) { throw 'Duplicate lifecycle inventory path.' }
        if ($relative -in $ownedPaths -or [string]$entry.module -in $ownedModules) { continue }
        if (-not $allowed.ContainsKey($relative) -or $allowed[$relative] -cne [string]$entry.module -or [string]$entry.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw "Unproven RQG ownership: $relative" }
        $hash = Get-RqgLifecycleHash $target
        if ($hash -and $hash -cne [string]$entry.sha256) { throw "Modified managed file prevents deactivation: $relative" }
        $plan.Add([pscustomobject]@{path=$relative;action=if ($hash) {'Remove'} else {'Absent'};existingHash=$hash})
    }
    $ignorePath = Join-Path $RepositoryRoot '.gitignore'
    $ignoreBytes = $null
    $newIgnore = $null
    $ownedIgnore = @(if ($state.PSObject.Properties['ownedGitIgnoreLines']) { $state.ownedGitIgnoreLines })
    if ($ownedIgnore.Count -and (Test-Path -LiteralPath $ignorePath -PathType Leaf)) {
        if (((Get-Item -LiteralPath $ignorePath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Git ignore configuration cannot be a filesystem link.' }
        $ignoreBytes = [IO.File]::ReadAllBytes($ignorePath)
        $text = [Text.UTF8Encoding]::new($false,$true).GetString($ignoreBytes)
        $newIgnore = $text
        foreach ($line in $ownedIgnore) {
            if ($line -isnot [string] -or -not $line -or $line -match '[\r\n]') { throw 'Invalid owned ignore fragment.' }
            $pattern = '(?m)^' + [regex]::Escape($line) + '(?:\r?\n|$)'
            if ([regex]::Matches($newIgnore,$pattern).Count -gt 1) { throw 'Ambiguous duplicated ignore fragment.' }
            $newIgnore = [regex]::Replace($newIgnore,$pattern,'')
        }
        if ($newIgnore -cne $text) { $plan.Add([pscustomobject]@{path='.gitignore';action='RemoveOwnedFragment';existingHash=Get-RqgLifecycleHash $ignorePath}) }
    }
    $result.status = 'DeactivationAvailable'; $result.plan = @($plan); $result.changedPaths = @($plan | Where-Object action -ne 'Absent' | ForEach-Object path) + '.repository-quality-gates.json'
    if (-not $Apply) { return [pscustomobject]$result }
    $dirty = @(& git -C $RepositoryRoot status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0 -or $dirty.Count) { throw 'Deactivation requires a clean, committed repository.' }
    $rulesHash = Get-RqgLifecycleHash $rulesPath
    $stateBytes = [IO.File]::ReadAllBytes($statePath)
    $stateHash = Get-RqgLifecycleHash $statePath
    $removed = [Collections.Generic.Dictionary[string,byte[]]]::new()
    try {
        foreach ($entry in $plan) {
            if ($entry.action -eq 'Absent') { continue }
            $path = if ($entry.path -eq '.gitignore') { $ignorePath } else { Resolve-RqgLifecyclePath $RepositoryRoot $entry.path }
            if ((Get-RqgLifecycleHash $path) -cne $entry.existingHash) { throw 'A deactivation path changed after preflight.' }
            $removed[$path] = [IO.File]::ReadAllBytes($path)
            if ($entry.action -eq 'RemoveOwnedFragment') { [IO.File]::WriteAllText($path,$newIgnore,[Text.UTF8Encoding]::new($false)) }
            else { Remove-Item -LiteralPath $path -Force }
        }
        if ((Get-RqgLifecycleHash $rulesPath) -cne $rulesHash -or (Get-RqgLifecycleHash $statePath) -cne $stateHash) { throw 'Lifecycle control files changed during deactivation.' }
        # State is the retry authority and is removed only after all owned content.
        Remove-Item -LiteralPath $statePath -Force
        $result.status='Deactivated'
    } catch {
        foreach ($path in $removed.Keys) { [IO.File]::WriteAllBytes($path,$removed[$path]) }
        if (-not (Test-Path -LiteralPath $statePath)) { [IO.File]::WriteAllBytes($statePath,$stateBytes) }
        throw
    }
    return [pscustomobject]$result
}
