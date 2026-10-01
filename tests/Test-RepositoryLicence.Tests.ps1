# SPDX-License-Identifier: MIT
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$validator = Join-Path $projectRoot 'scripts/Test-RepositoryLicence.ps1'
$spdxPolicy = Join-Path $projectRoot '.rqg/licensing/spdx-license-identifiers.json'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('rqg-licence-tests-' + [guid]::NewGuid().ToString('N'))
$passed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:passed++
}

function New-Fixture([string]$Name, [hashtable]$Licence, [string]$LicenceText) {
    $path = Join-Path $testRoot $Name
    New-Item -ItemType Directory -Path (Join-Path $path '.rqg/licensing') -Force | Out-Null
    & git -C $path init --initial-branch=main | Out-Null
    Copy-Item -LiteralPath $spdxPolicy -Destination (Join-Path $path '.rqg/licensing/spdx-license-identifiers.json')
    $config = [ordered]@{
        schemaVersion = 2
        profile = 'downstream'
        account = 'example-owner'
        centralRepository = 'https://github.com/example-owner/.github'
        licence = $Licence
        supportRoute = 'github-discussions'
        conductRoute = 'confidential-email'
    }
    [IO.File]::WriteAllText((Join-Path $path '.repository-standards.json'), ($config | ConvertTo-Json -Depth 5) + "`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $path 'LICENSE'), $LicenceText.Replace("`r`n", "`n").TrimEnd() + "`n", [Text.UTF8Encoding]::new($false))
    return $path
}

function Invoke-Validation([string]$Path, [AllowEmptyString()][string]$GitHubSpdxId, [AllowEmptyString()][string]$Visibility) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & pwsh -NoProfile -ExecutionPolicy Bypass -File $validator -Repository $Path -GitHubSpdxId $GitHubSpdxId -RepositoryVisibility $Visibility -OutputFormat Json 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join [Environment]::NewLine) }
    } finally { $ErrorActionPreference = $previousPreference }
}

$openSourceDecision = [ordered]@{ class = 'open-source'; identifier = 'MIT'; rightsHolder = 'Example Owner'; decisionStatus = 'approved'; templateVersion = $null; overrideReason = $null }
$mitText = @'
MIT License

Copyright (c) 2026 Example Owner

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files, to deal in the Software without restriction.
'@
$proprietaryDecision = [ordered]@{ class = 'proprietary'; identifier = 'LicenseRef-TR-Proprietary-1.0'; rightsHolder = 'Terry Rogers'; decisionStatus = 'approved'; templateVersion = '1.0'; overrideReason = $null }
$proprietaryText = @'
PROPRIETARY LICENSE

Copyright © 2026 Terry Rogers. All rights reserved.

This software and its associated source code, documentation, assets, and other original repository contents are proprietary.

Access to this repository or its contents does not grant permission to use, copy, modify, merge, publish, distribute, sublicense, sell, create derivative works from, or otherwise exploit the original repository contents.

Any permitted use requires prior written authorization from the copyright holder and is limited to the purpose, scope, recipients, and duration stated in that authorization.

Third-party software, dependencies, libraries, assets, and other materials remain subject to their respective licences. Nothing in this licence limits rights independently granted under those third-party licences or rights that cannot lawfully be excluded.

THE ORIGINAL REPOSITORY CONTENTS ARE PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, AND NON-INFRINGEMENT. TO THE MAXIMUM EXTENT PERMITTED BY LAW, THE COPYRIGHT HOLDER SHALL NOT BE LIABLE FOR ANY CLAIM, DAMAGES, OR OTHER LIABILITY ARISING FROM THE CONTENTS OR THEIR USE.

SPDX-License-Identifier: LicenseRef-TR-Proprietary-1.0
'@

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null

    $open = New-Fixture 'open-source-valid' $openSourceDecision $mitText
    $result = Invoke-Validation $open 'MIT' 'Public'
    Assert-True ($result.ExitCode -eq 0) "A recognized SPDX decision with matching GitHub detection should pass. $($result.Output)"
    Assert-True ((Invoke-Validation $open 'MIT' 'Private').ExitCode -ne 0) 'A private repository must reject MIT without an approved local override.'
    Assert-True ((Invoke-Validation $open 'MIT' '').ExitCode -ne 0) 'Missing repository visibility must fail closed.'

    $unknownDecision = $openSourceDecision | ConvertTo-Json | ConvertFrom-Json -AsHashtable; $unknownDecision.identifier = 'Not-A-Real-SPDX-ID'
    $unknown = New-Fixture 'open-source-unknown' $unknownDecision $mitText
    Assert-True ((Invoke-Validation $unknown 'Not-A-Real-SPDX-ID' 'Public').ExitCode -ne 0) 'An unrecognized SPDX identifier must fail.'
    Assert-True ((Invoke-Validation $open 'Apache-2.0' 'Public').ExitCode -ne 0) 'A GitHub SPDX mismatch must fail.'
    Assert-True ((Invoke-Validation $open '' 'Public').ExitCode -ne 0) 'A missing GitHub licence presentation must fail closed.'

    $apacheDecision = $openSourceDecision | ConvertTo-Json | ConvertFrom-Json -AsHashtable; $apacheDecision.identifier = 'Apache-2.0'; $apacheDecision.overrideReason = 'Approved repository-specific open-source licence.'
    $apache = New-Fixture 'public-apache' $apacheDecision ($mitText -replace 'MIT License', 'Apache License 2.0')
    Assert-True ((Invoke-Validation $apache 'Apache-2.0' 'Public').ExitCode -eq 0) 'A public repository may use a different approved SPDX licence through a documented local override.'
    $apacheDecisionWithoutOverride = $apacheDecision | ConvertTo-Json | ConvertFrom-Json -AsHashtable; $apacheDecisionWithoutOverride.overrideReason = $null
    $apacheWithoutOverride = New-Fixture 'public-apache-without-override' $apacheDecisionWithoutOverride ($mitText -replace 'MIT License', 'Apache License 2.0')
    Assert-True ((Invoke-Validation $apacheWithoutOverride 'Apache-2.0' 'Public').ExitCode -ne 0) 'A public non-MIT decision without an approved local override reason must fail.'

    $wrongHolderDecision = $openSourceDecision | ConvertTo-Json | ConvertFrom-Json -AsHashtable; $wrongHolderDecision.rightsHolder = 'Different Holder'
    $wrongHolder = New-Fixture 'wrong-rights-holder' $wrongHolderDecision $mitText
    Assert-True ((Invoke-Validation $wrongHolder 'MIT' 'Public').ExitCode -ne 0) 'A rights-holder mismatch must fail.'

    $contradictory = New-Fixture 'contradictory-marker' $openSourceDecision ($mitText + "`nSPDX-License-Identifier: Apache-2.0")
    Assert-True ((Invoke-Validation $contradictory 'MIT' 'Public').ExitCode -ne 0) 'A contradictory licence marker must fail.'

    $proprietary = New-Fixture 'proprietary-valid' $proprietaryDecision $proprietaryText
    Assert-True ((Invoke-Validation $proprietary 'NOASSERTION' 'Private').ExitCode -eq 0) 'The exact private proprietary template with GitHub NOASSERTION should pass.'
    Assert-True ((Invoke-Validation $proprietary 'Other' 'Private').ExitCode -eq 0) 'The exact private proprietary template with GitHub Other should pass.'
    Assert-True ((Invoke-Validation $proprietary 'MIT' 'Private').ExitCode -ne 0) 'A proprietary decision detected as an open-source licence must fail.'
    Assert-True ((Invoke-Validation $proprietary 'NOASSERTION' 'Public').ExitCode -ne 0) 'A public repository must reject a proprietary decision without an approved local override.'

    $altered = New-Fixture 'proprietary-altered' $proprietaryDecision ($proprietaryText -replace 'prior written authorization', 'authorization')
    Assert-True ((Invoke-Validation $altered 'NOASSERTION' 'Private').ExitCode -ne 0) 'An altered standard proprietary template must fail.'

    $overrideDecision = [ordered]@{ class = 'proprietary'; identifier = 'LicenseRef-Example-Proprietary-2.0'; rightsHolder = 'Example Owner'; decisionStatus = 'approved'; templateVersion = '2.0'; overrideReason = 'Approved project-specific terms.' }
    $overrideText = "PROPRIETARY LICENSE`n`nCopyright (c) 2026 Example Owner. All rights reserved.`n`nApproved project-specific terms. Third-party materials remain subject to their respective licences.`n`nSPDX-License-Identifier: LicenseRef-Example-Proprietary-2.0"
    $override = New-Fixture 'proprietary-override' $overrideDecision $overrideText
    Assert-True ((Invoke-Validation $override 'NOASSERTION' 'Private').ExitCode -eq 0) 'A private repository may use an approved proprietary local override.'
    Assert-True ((Invoke-Validation $override 'NOASSERTION' 'Public').ExitCode -eq 0) 'A public repository may use an approved proprietary local override.'

    $privateMitDecision = $openSourceDecision | ConvertTo-Json | ConvertFrom-Json -AsHashtable; $privateMitDecision.overrideReason = 'Approved repository-specific open-source licence.'
    $privateMit = New-Fixture 'private-mit-override' $privateMitDecision $mitText
    Assert-True ((Invoke-Validation $privateMit 'MIT' 'Private').ExitCode -eq 0) 'A private repository may use an approved MIT local override.'

    $gplDecision = [ordered]@{ class = 'open-source'; identifier = 'GPL-3.0-only'; rightsHolder = 'Terry Rogers'; decisionStatus = 'approved'; templateVersion = $null; overrideReason = 'Approved repository-specific GPL-3.0-only terms preserve existing copyleft and third-party obligations.' }
    $gplText = "Copyright (c) 2026 Terry Rogers`n`nSPDX-License-Identifier: GPL-3.0-only`n`nGNU GENERAL PUBLIC LICENSE`nVersion 3, 29 June 2007"
    $gpl = New-Fixture 'public-gpl-override' $gplDecision $gplText
    Assert-True ((Invoke-Validation $gpl 'GPL-3.0' 'Public').ExitCode -eq 0) 'The approved GPL-3.0-only override should accept GitHub legacy detector identifier GPL-3.0.'
    Assert-True ((Invoke-Validation $gpl 'GPL-3.0-or-later' 'Public').ExitCode -ne 0) 'An unapproved GPL detector variant must fail.'

    $unapprovedOverrideDecision = $overrideDecision | ConvertTo-Json | ConvertFrom-Json -AsHashtable; $unapprovedOverrideDecision.overrideReason = $null
    $unapprovedOverride = New-Fixture 'proprietary-unapproved-override' $unapprovedOverrideDecision $overrideText
    Assert-True ((Invoke-Validation $unapprovedOverride 'NOASSERTION' 'Private').ExitCode -ne 0) 'A proprietary deviation without an approved override reason must fail.'

    $missingBoundary = New-Fixture 'proprietary-missing-boundary' $overrideDecision ($overrideText -replace ' Third-party materials remain subject to their respective licences\.', '')
    Assert-True ((Invoke-Validation $missingBoundary 'NOASSERTION' 'Private').ExitCode -ne 0) 'A proprietary override without a third-party-material boundary must fail.'

    Copy-Item -LiteralPath (Join-Path $open 'LICENSE') -Destination (Join-Path $open 'LICENCE')
    Assert-True ((Invoke-Validation $open 'MIT' 'Public').ExitCode -ne 0) 'Multiple root licence files must fail as unresolved.'

    Write-Host "$passed assertions passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

exit 0
