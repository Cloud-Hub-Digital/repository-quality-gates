# SPDX-License-Identifier: MIT
# This library is used only by the trusted release controller.
function ConvertTo-RqgProtectionBody([object]$Detail) {
    return ([ordered]@{name=$Detail.name;target=$Detail.target;enforcement=$Detail.enforcement;bypass_actors=@($Detail.bypass_actors);conditions=$Detail.conditions;rules=@($Detail.rules)} | ConvertTo-Json -Depth 30) | ConvertFrom-Json
}

function Assert-RqgProtectionUnchanged([object]$Current,[object]$Expected) {
    $actual=ConvertTo-RqgProtectionBody $Current
    $wanted=ConvertTo-RqgProtectionBody $Expected
    if (($actual | ConvertTo-Json -Depth 30 -Compress) -cne ($wanted | ConvertTo-Json -Depth 30 -Compress)) { throw 'Protection configuration changed; a stale snapshot cannot be applied.' }
}

function Remove-RqgBoundRemovalRequirement([object]$Current,[long]$AppId) {
    $body=ConvertTo-RqgProtectionBody $Current
    $status=@($body.rules | Where-Object type -ceq 'required_status_checks')
    $binding=@($status | ForEach-Object { $_.parameters.required_status_checks } | Where-Object context -ceq 'RQG Deactivation')
    if ($status.Count -ne 1 -or $binding.Count -ne 1 -or [long]$binding[0].integration_id -ne $AppId) { throw 'The current removal requirement has ambiguous ownership.' }
    $status[0].parameters.required_status_checks=@($status[0].parameters.required_status_checks | Where-Object context -cne 'RQG Deactivation')
    if (-not $status[0].parameters.required_status_checks.Count) { $body.rules=@($body.rules | Where-Object type -cne 'required_status_checks') }
    return $body
}

function Assert-RqgRemovalDestination([object]$State,[string]$Head,[string]$Branch) {
    if ($State.headSha -cne $Head -or $State.baseRef -cne $Branch) { throw 'The removal head or destination changed before merge.' }
    if ($State.PSObject.Properties['state'] -and ($State.state -cne 'open' -or $State.merged)) { throw 'The removal pull request is no longer open.' }
}

function Invoke-RqgDeactivationApi([string[]]$Arguments) {
    $text = @(& gh api @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $code = if (($text -join "`n") -match 'HTTP (?<code>[0-9]{3})') { $Matches.code } else { 'unavailable' }
        $resource = if (($Arguments -join ' ') -match '/check-runs') { 'Checks' } elseif (($Arguments -join ' ') -match '/rulesets|/protection') { 'Administration' } elseif (($Arguments -join ' ') -match '/pulls') { 'Pull Requests' } else { 'Contents' }
        throw "The deactivation $resource operation failed (HTTP $code). Verify the installation permission for that resource and the applicable repository protection."
    }
    try { return ($text -join "`n") | ConvertFrom-Json }
    catch { throw 'Invalid GitHub deactivation response.' }
}

function Set-RqgDeactivationApi([string]$Method,[string]$Endpoint,[object]$Body) {
    $file = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($file,($Body | ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
        return Invoke-RqgDeactivationApi @('--method',$Method,$Endpoint,'--input',$file)
    } finally { Remove-Item -LiteralPath $file -Force }
}

function Repair-RqgDeactivationTransition([string]$RepositoryName,[string]$Branch,[long]$AppId) {
    $sets= @(Invoke-RqgDeactivationApi @("repos/$RepositoryName/rulesets?includes_parents=false&per_page=100"))
    if ($sets.Count -ge 100) { throw 'Incomplete ruleset inventory prevents recovery.' }
    foreach ($set in @($sets | Where-Object name -ceq 'Repository Standards - Default Branch')) {
        $detail=Invoke-RqgDeactivationApi @("repos/$RepositoryName/rulesets/$($set.id)")
        $status=@($detail.rules | Where-Object type -ceq 'required_status_checks')
        $binding=@($status | ForEach-Object { $_.parameters.required_status_checks } | Where-Object context -ceq 'RQG Deactivation')
        if (-not $binding.Count) { continue }
        if ($status.Count -ne 1 -or $binding.Count -ne 1 -or [long]$binding[0].integration_id -ne $AppId) { throw 'Ambiguous deactivation transition cannot be recovered.' }
        $state=Get-RemoteTextFile $RepositoryName $Branch '.repository-quality-gates.json'
        $body=[ordered]@{name=$detail.name;target=$detail.target;enforcement=$detail.enforcement;bypass_actors=@($detail.bypass_actors);conditions=$detail.conditions;rules=@($detail.rules)}
        if ($state.exists) {
            $pulls=@(Get-OpenPullRequests $RepositoryName | Where-Object { $_.headRefName -match '^rqg/update-v' -and $_.baseRefName -ceq $Branch -and $_.body -match '<!-- repository-quality-gates-deactivation -->' })
            if ($pulls.Count -ne 1) { throw 'The interrupted removal PR is unavailable; no protection was changed.' }
            $pr=Invoke-RqgDeactivationApi @("repos/$RepositoryName/pulls/$($pulls[0].number)")
            if ([DateTimeOffset]::Parse([string]$pr.created_at) -gt [DateTimeOffset]::UtcNow.AddHours(-2)) { throw 'A removal transaction may still be active; recovery is deferred for two hours.' }
            $checks=@(Invoke-RqgDeactivationApi @('--paginate','--slurp',"repos/$RepositoryName/commits/$($pr.head.sha)/check-runs?filter=latest&per_page=100",'--jq','[.[] | .check_runs[]]'))
            $receiptCheck=@($checks | Where-Object { $_.name -ceq 'RQG Deactivation' -and [long]$_.app.id -eq $AppId -and $_.conclusion -ceq 'success' })
            if ($receiptCheck.Count -ne 1 -or $receiptCheck[0].output.summary -notmatch 'RQG-Deactivation-Receipt: (?<json>\{[^\r\n]+\})') { throw 'Authoritative deactivation recovery receipt is missing.' }
            $receipt=$Matches.json | ConvertFrom-Json
            if ($receipt.schemaVersion -ne 1 -or [long]$receipt.ruleset -ne [long]$set.id -or [long]$receipt.appId -ne $AppId -or $pr.user.login -cne ($receiptCheck[0].app.slug + '[bot]')) { throw 'Deactivation recovery receipt identity mismatch.' }
            $stateData=$state.content | ConvertFrom-Json
            $expected=@(Get-RqgExpectedModuleChecks $stateData.modules)
            if (@($receipt.removedChecks).Count -ne $expected.Count -or @($receipt.removedChecks | Where-Object { $_.context -cnotin $expected }).Count) { throw 'Recovery receipt does not match the deployed module inventory.' }
            $status[0].parameters.required_status_checks=@($status[0].parameters.required_status_checks | Where-Object context -cne 'RQG Deactivation') + @($receipt.removedChecks)
            $null=Set-RqgDeactivationApi PUT "repos/$RepositoryName/rulesets/$($set.id)" $body
            $null=Set-RqgDeactivationApi PATCH "repos/$RepositoryName/pulls/$($pr.number)" @{state='closed'}
            Remove-RqgMergedBranch $RepositoryName ([string]$pr.head.ref)
        } else {
            if (Test-RqgEnabled $RepositoryName $Branch) { throw 'Missing state without an explicit disabled decision prevents transition cleanup.' }
            $status[0].parameters.required_status_checks=@($status[0].parameters.required_status_checks | Where-Object context -cne 'RQG Deactivation')
            if (-not $status[0].parameters.required_status_checks.Count) { $body.rules=@($body.rules | Where-Object type -cne 'required_status_checks') }
            $null=Set-RqgDeactivationApi PUT "repos/$RepositoryName/rulesets/$($set.id)" $body
        }
        $readback=Invoke-RqgDeactivationApi @("repos/$RepositoryName/rulesets/$($set.id)")
        if (($readback.rules | ConvertTo-Json -Depth 30 -Compress) -cne ($body.rules | ConvertTo-Json -Depth 30 -Compress)) { throw 'Deactivation recovery readback failed.' }
    }
}

function Clear-RqgAbandonedRemovalPr([string]$RepositoryName,[string]$Branch,[long]$AppId) {
    foreach ($candidate in @(Get-OpenPullRequests $RepositoryName | Where-Object { -not $_.isCrossRepository -and $_.baseRefName -ceq $Branch -and $_.headRefName -match '^rqg/update-v' -and $_.body -match '<!-- repository-quality-gates-deactivation -->' })) {
        if ([DateTimeOffset]::Parse([string]$candidate.createdAt) -gt [DateTimeOffset]::UtcNow.AddHours(-2)) { continue }
        $pr=Invoke-RqgDeactivationApi @("repos/$RepositoryName/pulls/$($candidate.number)")
        $checks=@(Invoke-RqgDeactivationApi @('--paginate','--slurp',"repos/$RepositoryName/commits/$($pr.head.sha)/check-runs?filter=latest&per_page=100",'--jq','[.[] | .check_runs[]]'))
        $proof=@($checks | Where-Object { $_.name -ceq 'RQG Deactivation' -and [long]$_.app.id -eq $AppId -and $_.conclusion -ceq 'success' })
        if ($proof.Count -ne 1 -or $pr.user.login -cne ($proof[0].app.slug + '[bot]')) { throw 'An abandoned removal PR lacks authoritative provenance; it was preserved.' }
        $null=Set-RqgDeactivationApi PATCH "repos/$RepositoryName/pulls/$($pr.number)" @{state='closed'}
        Remove-RqgMergedBranch $RepositoryName ([string]$pr.head.ref)
    }
}

function Assert-RqgDeactivationBaseline([string]$RepositoryName,[string]$Commit,[string[]]$ExpectedChecks) {
    $checks = @(Invoke-RqgDeactivationApi @('--paginate','--slurp',"repos/$RepositoryName/commits/$Commit/check-runs?filter=latest&per_page=100",'--jq','[.[] | .check_runs[]]'))
    if (-not $checks.Count) { throw 'The deactivation baseline has no verified check evidence.' }
    $providers=@{}
    foreach ($name in $ExpectedChecks) {
        $matches = @($checks | Where-Object name -ceq $name)
        if (-not $matches.Count -or @($matches | Where-Object { $_.status -cne 'completed' -or $_.conclusion -cne 'success' }).Count) { throw "The baseline check has not passed: $name" }
        if (@($matches | Where-Object { -not $_.PSObject.Properties['app'] -or $_.app.slug -cne 'github-actions' -or [long]$_.app.id -lt 1 }).Count -or @($matches | ForEach-Object { [long]$_.app.id } | Sort-Object -Unique).Count -ne 1) { throw "The managed baseline check provider is ambiguous: $name" }
        $providers[$name]=[long]$matches[0].app.id
    }
    if (@($checks | Where-Object { $_.status -cne 'completed' -or $_.conclusion -notin @('success','neutral','skipped') }).Count) { throw 'A baseline check is failed or incomplete; deactivation cannot bypass it.' }
    $statuses = @(Invoke-RqgDeactivationApi @('--paginate','--slurp',"repos/$RepositoryName/commits/$Commit/statuses?per_page=100",'--jq','[.[][]]'))
    foreach ($group in @($statuses | Group-Object context)) {
        $latest = @($group.Group | Sort-Object created_at -Descending)[0]
        if ($latest.state -cne 'success') { throw 'A baseline commit status is failed or incomplete.' }
    }
    return [pscustomobject]@{providers=$providers}
}

function Get-RqgDeactivationRules([string]$RepositoryName,[string]$Branch,[string[]]$RemovedChecks,[long]$AppId,[string]$Visibility,[object]$Policy,[hashtable]$CheckProviders) {
    $encoded = [Uri]::EscapeDataString($Branch)
    # Preserve the same narrowly approved private-plan exception as updates.
    $enforcement = Assert-RequiredQualityChecksEnforced $RepositoryName $Branch $RemovedChecks $Visibility $Policy
    if ($enforcement.platformLimitationVerified) {
        return [pscustomobject]@{mode=$enforcement.mode;exceptionId=$enforcement.exceptionId;expectedChecks=@('RQG Deactivation');ruleset=$null;original=$null;transition=$null}
    }
    $sets = @(Invoke-RqgDeactivationApi @("repos/$RepositoryName/rulesets?includes_parents=false&per_page=100"))
    if ($sets.Count -ge 100) { throw 'Incomplete ruleset inventory prevents deactivation.' }
    $owned = @($sets | Where-Object name -ceq 'Repository Standards - Default Branch')
    if ($owned.Count -ne 1) { throw 'A unique managed ruleset is required for checked deactivation.' }
    $detail = Invoke-RqgDeactivationApi @("repos/$RepositoryName/rulesets/$($owned[0].id)")
    if ($detail.enforcement -cne 'active' -or @($detail.bypass_actors).Count -or @($detail.conditions.ref_name.include).Count -ne 1 -or $detail.conditions.ref_name.include[0] -cne '~DEFAULT_BRANCH' -or @($detail.conditions.ref_name.exclude).Count) { throw 'The managed ruleset ownership boundary is unresolved.' }
    $statusRules = @($detail.rules | Where-Object type -ceq 'required_status_checks')
    if ($statusRules.Count -ne 1) { throw 'Ambiguous managed required-check rules.' }
    $oldChecks = @($statusRules[0].parameters.required_status_checks)
    if (@($oldChecks | Where-Object context -ceq 'RQG Deactivation').Count) { throw 'An interrupted deactivation transition requires verified recovery before another attempt.' }
    $removed = @($oldChecks | Where-Object context -cin $RemovedChecks)
    if ($removed.Count -ne $RemovedChecks.Count) { throw 'Required-check ownership is not exact.' }
    foreach ($check in $removed) {
        if (-not $CheckProviders -or -not $CheckProviders.ContainsKey([string]$check.context)) { throw 'Required-check provider ownership is unresolved.' }
        if ($check.PSObject.Properties['integration_id'] -and $null -ne $check.integration_id -and [long]$check.integration_id -gt 0 -and [long]$check.integration_id -ne [long]$CheckProviders[[string]$check.context]) { throw 'An independent provider owns a same-named requirement; it cannot be removed.' }
    }
    # Other rulesets and classic protection may not be weakened. If they also
    # require a removed workflow, the owner must resolve that independent rule.
    foreach ($other in @($sets | Where-Object id -ne $owned[0].id)) {
        $otherDetail = Invoke-RqgDeactivationApi @("repos/$RepositoryName/rulesets/$($other.id)")
        if ($otherDetail.enforcement -eq 'active' -and @($otherDetail.rules | Where-Object type -eq 'required_status_checks' | ForEach-Object { $_.parameters.required_status_checks } | Where-Object context -cin $RemovedChecks).Count) { throw 'An independent ruleset requires removed RQG checks; deactivation is blocked.' }
    }
    $classic = @(& gh api "repos/$RepositoryName/branches/$encoded/protection/required_status_checks" 2>&1)
    if ($LASTEXITCODE -eq 0) {
        $classicRules = ($classic -join "`n") | ConvertFrom-Json
        if (@($classicRules.contexts | Where-Object { $_ -cin $RemovedChecks }).Count) { throw 'Classic branch protection independently requires removed RQG checks.' }
    } elseif (($classic -join "`n") -notmatch '(?i)HTTP 404') { throw 'Unable to verify independent classic protections.' }
    $original = [ordered]@{name=$detail.name;target=$detail.target;enforcement=$detail.enforcement;bypass_actors=@($detail.bypass_actors);conditions=$detail.conditions;rules=@($detail.rules)}
    $transition = ($original | ConvertTo-Json -Depth 30) | ConvertFrom-Json
    $rule = @($transition.rules | Where-Object type -ceq 'required_status_checks')[0]
    $retained = @($oldChecks | Where-Object context -cnotin $RemovedChecks)
    $rule.parameters.required_status_checks = @($retained) + @([pscustomobject]@{context='RQG Deactivation';integration_id=$AppId})
    $expected = @(@($enforcement.requiredChecks | Where-Object { $_ -cnotin $RemovedChecks }) + 'RQG Deactivation' | Sort-Object -Unique)
    return [pscustomobject]@{mode=$enforcement.mode;exceptionId=$enforcement.exceptionId;expectedChecks=$expected;ruleset=[long]$owned[0].id;original=$original;transition=$transition;removedChecks=@($removed)}
}

function Invoke-RqgCheckedDeactivation([object]$Entry,[string]$TemplateRoot,[string]$TargetVersion,[object]$RequiredCheckPolicy,[switch]$Apply,[switch]$AutoMerge) {
    $repository = [string]$Entry.repository
    $metadata = Invoke-RqgDeactivationApi @("repos/$repository")
    $branch = [string]$metadata.default_branch
    $base = Invoke-RqgDeactivationApi @("repos/$repository/git/ref/heads/$([Uri]::EscapeDataString($branch))")
    $baseSha = [string]$base.object.sha
    if ($baseSha -cnotmatch '^[0-9a-f]{40}$') { throw 'Invalid deactivation base commit.' }
    $appId=0
    if ($Apply -and $AutoMerge) {
        $installation=Invoke-RqgDeactivationApi @('/installation')
        $appId=[long]$installation.app_id
        if ($appId -lt 1) { throw 'The authenticated GitHub App identity cannot be verified.' }
        # Recovery changes only the bound temporary removal requirement. An
        # unsupported private plan has no native transition to recover.
        $rulesProbe=@(& gh api "repos/$repository/rules/branches/$([Uri]::EscapeDataString($branch))?per_page=100" 2>&1)
        if ($LASTEXITCODE -eq 0) { Repair-RqgDeactivationTransition $repository $branch $appId }
        elseif (-not ([string]$Entry.visibility -eq 'Private' -and (Test-RqgPrivatePlanLimitation ($rulesProbe -join "`n")))) { throw 'Unable to inspect protections before deactivation recovery.' }
        Clear-RqgAbandonedRemovalPr $repository $branch $appId
    }
    if (@(Get-OpenPullRequests $repository).Count) { $Entry.status='DeferredOpenPullRequests';$Entry.detail='Open pull requests prevent checked deactivation.';return $Entry }
    $root = Join-Path ([IO.Path]::GetTempPath()) ('rqg-deactivate-' + [Guid]::NewGuid().ToString('N'))
    $transitioned=$false; $merged=$false; $rules=$null; $pr=$null; $pushed=$false; $pending=$false
    $updateBranch="rqg/update-v$TargetVersion"
    try {
        & git clone --quiet --single-branch --branch $branch "https://github.com/$repository.git" $root
        if ($LASTEXITCODE -ne 0) { throw 'Unable to clone the deactivation baseline.' }
        $cloneHead=(& git -C $root rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0 -or $cloneHead -cne $baseSha) { throw 'The deactivation base changed during clone.' }
        $removedChecks = @(Get-ExpectedQualityCheckNames $root)
        $plan=Invoke-RqgDeactivation $root $TemplateRoot
        $stateData=Get-Content -LiteralPath (Join-Path $root '.repository-quality-gates.json') -Raw | ConvertFrom-Json
        foreach ($module in @($stateData.modules)) {
            if (-not @(Get-RqgExpectedModuleChecks @($module) -AllowEmpty).Count) { continue }
            $workflows=@($stateData.files | Where-Object { $_.module -ceq $module -and $_.path -like '.github/workflows/*' })
            if (-not $workflows.Count -or @($workflows | Where-Object { $_.path -cnotin @($plan.plan | Where-Object action -eq 'Remove' | ForEach-Object path) }).Count) { throw 'Required-check ownership is ambiguous because its workflow is retained or absent.' }
        }
        $Entry.status=$plan.status; $Entry.detail="$($plan.changedPaths.Count) owned paths would be removed; product and repository-owned content are preserved."
        if (-not $Apply) { return $Entry }
        if (-not $AutoMerge) { $Entry.detail += ' Guarded removal requires Apply and AutoMerge together; no branch, check or protection was changed.'; return $Entry }
        $baseline=Assert-RqgDeactivationBaseline $repository $baseSha $removedChecks
        $rules=Get-RqgDeactivationRules $repository $branch $removedChecks $appId ([string]$Entry.visibility) $RequiredCheckPolicy $baseline.providers
        & git -C $root checkout -b $updateBranch
        if ($LASTEXITCODE -ne 0) { throw 'Unable to create the removal branch.' }
        $null=Invoke-RqgDeactivation $root $TemplateRoot -Apply
        & git -C $root add -A
        if ($LASTEXITCODE -ne 0) { throw 'Unable to stage removal.' }
        $changed=@(& git -C $root diff --cached --name-only)
        if ($LASTEXITCODE -ne 0 -or @($changed | Where-Object { $_ -cnotin @($plan.changedPaths) }).Count) { throw 'Removal changes include an unapproved path.' }
        $nonDeletes=@(& git -C $root diff --cached --name-only --diff-filter=ACMRTUXB)
        if ($LASTEXITCODE -ne 0 -or @($nonDeletes | Where-Object { $_ -cne '.gitignore' }).Count) { throw 'The checked removal contains a replacement or addition rather than owned deletion.' }
        & git -C $root diff --quiet --exit-code
        if ($LASTEXITCODE -ne 0) { throw 'The removal working tree changed after staging.' }
        $scanner=Join-Path $TemplateRoot 'scripts/Test-Secrets.ps1'
        & pwsh -NoProfile -File $scanner -Mode Staged -Repository $root
        if ($LASTEXITCODE -ne 0) { throw 'The exact removal failed the trusted publication scan.' }
        $noHooks=Join-Path $root '.git/rqg-no-hooks'
        New-Item -ItemType Directory -Path $noHooks | Out-Null
        & git -C $root -c "core.hooksPath=$noHooks" -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' commit -m 'chore: deactivate managed repository quality gates'
        if ($LASTEXITCODE -ne 0) { throw 'Unable to commit checked removal.' }
        $head=(& git -C $root rev-parse HEAD).Trim()
        $fresh=Invoke-RqgDeactivationApi @("repos/$repository/git/ref/heads/$([Uri]::EscapeDataString($branch))")
        if ($fresh.object.sha -cne $baseSha) { throw 'The destination changed before removal publication.' }
        & git -C $root push origin "HEAD:refs/heads/$updateBranch"
        if ($LASTEXITCODE -ne 0) { throw 'Unable to publish the exact removal branch.' }
        $pushed=$true
        $pr=Set-RqgDeactivationApi POST "repos/$repository/pulls" @{title='chore: deactivate managed repository quality gates';head=$updateBranch;base=$branch;body="<!-- repository-quality-gates-fleet-update -->`n<!-- repository-quality-gates-deactivation -->`nRemoves unchanged RQG-owned content following an explicit committed rqgEnabled: false decision. Product content and independent protections are preserved. The trusted removal check and all independent checks must pass before merge."}
        $Entry.pullRequest=[string]$pr.html_url
        $receipt=[ordered]@{schemaVersion=1;appId=$appId;ruleset=$rules.ruleset;baseSha=$baseSha;removedChecks=if ($rules.PSObject.Properties['removedChecks']) {@($rules.removedChecks)} else {@()}}
        $summary='Baseline checks passed. Only proven RQG-owned content was removed. Product content is unchanged; publication scanning passed.' + "`nRQG-Deactivation-Receipt: " + ($receipt | ConvertTo-Json -Depth 8 -Compress)
        $check=Set-RqgDeactivationApi POST "repos/$repository/check-runs" @{name='RQG Deactivation';head_sha=$head;status='completed';conclusion='success';output=@{title='Exact Managed Removal Validated';summary=$summary}}
        if ($check.head_sha -cne $head -or [long]$check.app.id -ne $appId -or $check.conclusion -cne 'success') { throw 'The authoritative removal check could not be verified.' }
        $checks=Wait-PullRequestQualityChecks $repository $Entry.pullRequest @($rules.expectedChecks) 30
        $Entry.runners=@($checks.runnerNames)
        if ($checks.headSha -cne $head -or $checks.baseRef -cne $branch) { throw 'The checked removal PR changed.' }
        if (-not $AutoMerge) { $pending=$true;$Entry.status='DeactivationPullRequest';$Entry.detail='Removal validated; checked PR awaits controlled merge.';return $Entry }
        $fresh=Invoke-RqgDeactivationApi @("repos/$repository/git/ref/heads/$([Uri]::EscapeDataString($branch))")
        if ($fresh.object.sha -cne $baseSha) { throw 'The destination changed after removal validation.' }
        if ($rules.ruleset) {
            $before=Invoke-RqgDeactivationApi @("repos/$repository/rulesets/$($rules.ruleset)")
            Assert-RqgProtectionUnchanged $before $rules.original
            $null=Set-RqgDeactivationApi PUT "repos/$repository/rulesets/$($rules.ruleset)" $rules.transition
            $transitioned=$true
        }
        $null=Assert-RequiredQualityChecksEnforced $repository $branch @($rules.expectedChecks) ([string]$Entry.visibility) $RequiredCheckPolicy
        if ($rules.ruleset) {
            $binding=Invoke-RqgDeactivationApi @("repos/$repository/rulesets/$($rules.ruleset)")
            $bound=@($binding.rules | Where-Object type -ceq 'required_status_checks' | ForEach-Object { $_.parameters.required_status_checks } | Where-Object context -ceq 'RQG Deactivation')
            if ($bound.Count -ne 1 -or [long]$bound[0].integration_id -ne $appId) { throw 'Removal validation is not bound to the authoritative App.' }
        }
        $freshChecks=Wait-PullRequestQualityChecks $repository $Entry.pullRequest @($rules.expectedChecks) 30
        Assert-RqgRemovalDestination $freshChecks $head $branch
        $fresh=Invoke-RqgDeactivationApi @("repos/$repository/git/ref/heads/$([Uri]::EscapeDataString($branch))")
        if ($fresh.object.sha -cne $baseSha) { throw 'The base changed before checked removal merge.' }
        $checkReadback=Invoke-RqgDeactivationApi @("repos/$repository/check-runs/$($check.id)")
        if ($checkReadback.head_sha -cne $head -or $checkReadback.conclusion -cne 'success' -or [long]$checkReadback.app.id -ne $appId) { throw 'The authoritative removal check changed before merge.' }
        $mergePr=Get-PullRequestState $repository ([int]$pr.number)
        Assert-RqgRemovalDestination $mergePr $head $branch
        $response=Set-RqgDeactivationApi PUT "repos/$repository/pulls/$($pr.number)/merge" @{merge_method='squash';sha=$head}
        if ($response.merged -ne $true) { throw 'The checked removal was not merged.' }
        $merged=$true
        $mergeCommit=Invoke-RqgDeactivationApi @("repos/$repository/git/commits/$($response.sha)")
        $expectedTree=(& git -C $root rev-parse 'HEAD^{tree}').Trim()
        if ($LASTEXITCODE -ne 0 -or $mergeCommit.tree.sha -cne $expectedTree) { throw 'The merged tree does not match the checked removal.' }
        $remote=Get-RemoteTextFile $repository $branch '.repository-quality-gates.json'
        if ($remote.exists -or (Test-RqgEnabled $repository $branch)) { throw 'Remote deactivation state could not be verified after merge.' }
        if ($rules.ruleset) {
            $current=Invoke-RqgDeactivationApi @("repos/$repository/rulesets/$($rules.ruleset)")
            $final=Remove-RqgBoundRemovalRequirement $current $appId
            $null=Set-RqgDeactivationApi PUT "repos/$repository/rulesets/$($rules.ruleset)" $final
            $verified=Invoke-RqgDeactivationApi @("repos/$repository/rulesets/$($rules.ruleset)")
            Assert-RqgProtectionUnchanged $verified $final
        }
        Remove-RqgMergedBranch $repository $updateBranch
        $Entry.status='DeactivatedSuccessfully';$Entry.autoMerge=$true;$Entry.detail='Owned RQG content removed after validated checks; independent protections retained and remote disabled state verified.'
        return $Entry
    } finally {
        if ($transitioned -and -not $merged) {
            $current=Invoke-RqgDeactivationApi @("repos/$repository/rulesets/$($rules.ruleset)")
            Assert-RqgProtectionUnchanged $current $rules.transition
            $null=Set-RqgDeactivationApi PUT "repos/$repository/rulesets/$($rules.ruleset)" $rules.original
            $restored=Invoke-RqgDeactivationApi @("repos/$repository/rulesets/$($rules.ruleset)")
            Assert-RqgProtectionUnchanged $restored $rules.original
        }
        if ($pushed -and -not $merged -and -not $pending) {
            if ($pr) { $null=Set-RqgDeactivationApi PATCH "repos/$repository/pulls/$($pr.number)" @{state='closed'} }
            Remove-RqgMergedBranch $repository $updateBranch
        }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}
