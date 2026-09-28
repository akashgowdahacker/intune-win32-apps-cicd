[CmdletBinding()]
param(
    [string]$CatalogPath = "$PSScriptRoot\..\apps\applications.json",
    [string]$WorkflowPath = "$PSScriptRoot\..\.github\workflows\intune-apps.yml"
)

$ErrorActionPreference = 'Stop'
$catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
if ($catalog.schemaVersion -ne 1) {
    throw "Unsupported catalog schema version '$($catalog.schemaVersion)'."
}
if (-not $catalog.applications -or $catalog.applications.Count -eq 0) {
    throw 'The catalog must contain at least one application.'
}

$duplicateIds = @($catalog.applications | Group-Object -Property id | Where-Object Count -gt 1)
if ($duplicateIds.Count -gt 0) {
    throw "Duplicate application IDs: $(($duplicateIds.Name) -join ', ')."
}

$supportedSourceTypes = @('github-release', 'direct-url', 'winscp-download')
foreach ($app in $catalog.applications) {
    if ([string]::IsNullOrWhiteSpace($app.id) -or
        [string]::IsNullOrWhiteSpace($app.displayName) -or
        [string]::IsNullOrWhiteSpace($app.publisher)) {
        throw 'Every application needs an id, displayName, and publisher.'
    }

    if ($app.status -eq 'pending-validation') {
        if ([string]::IsNullOrWhiteSpace($app.pendingReason)) {
            throw "$($app.id): pending-validation entries need a pendingReason."
        }
        if ($app.source.referenceUrl -and $app.source.referenceUrl -notmatch '^https?://') {
            throw "$($app.id): source.referenceUrl must be an HTTP or HTTPS URL."
        }
        continue
    }

    if ($app.status -and $app.status -ne 'active') {
        throw "$($app.id): unsupported status '$($app.status)'."
    }
    if ($app.source.type -notin $supportedSourceTypes) {
        throw "$($app.id): unsupported package source '$($app.source.type)'."
    }
    if ($app.source.sha256 -and $app.source.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "$($app.id): source.sha256 must contain exactly 64 hexadecimal characters."
    }
    if ($app.source.type -eq 'winscp-download' -and
        ([string]::IsNullOrWhiteSpace($app.source.downloadPageUrl) -or
            [string]::IsNullOrWhiteSpace($app.source.fileName) -or
            [string]::IsNullOrWhiteSpace($app.source.signerSubject) -or
            [string]::IsNullOrWhiteSpace($app.source.sha256))) {
        throw "$($app.id): winscp-download requires downloadPageUrl, fileName, signerSubject, and sha256."
    }
    foreach ($property in 'installerType', 'architecture', 'currentVersion') {
        if ([string]::IsNullOrWhiteSpace([string]$app.$property)) {
            throw "$($app.id): active application is missing '$property'."
        }
    }
    foreach ($property in 'setupFile', 'downloadUrl', 'installCommand', 'uninstallCommand') {
        if ([string]::IsNullOrWhiteSpace($app.package.$property)) {
            throw "$($app.id): active application is missing package.$property."
        }
    }
    if ($app.package.installScript) {
        $installScriptName = [IO.Path]::GetFileName($app.package.installScript)
        if ($installScriptName -ne $app.package.installScript -or
            -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $installScriptName) -PathType Leaf) -or
            $app.package.installCommand -notlike "*-File $installScriptName") {
            throw "$($app.id): package.installScript must name an existing script used by package.installCommand."
        }
    }
    if (-not $app.package.detectionRule) {
        throw "$($app.id): active application is missing package.detectionRule."
    }
    if ($app.package.detectionRule.type -eq 'msi' -and
        [string]::IsNullOrWhiteSpace($app.package.detectionRule.productCode)) {
        throw "$($app.id): MSI detection requires a productCode."
    }
    if ($app.package.detectionRule.type -notin @('file', 'msi')) {
        throw "$($app.id): unsupported detection rule type '$($app.package.detectionRule.type)'."
    }
}

$workflow = Get-Content -LiteralPath $WorkflowPath -Raw
$optionsMatch = [regex]::Match($workflow, '(?m)^\s+options:\s*\r?\n(?<options>(?:\s+-\s+[^\r\n]+\r?\n)+)')
if (-not $optionsMatch.Success) {
    throw 'The Intune workflow application selector was not found.'
}
$workflowIds = @($optionsMatch.Groups['options'].Value -split '\r?\n' |
    ForEach-Object { $_ -replace '^\s+-\s+', '' } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Sort-Object -Unique)
$bulkOption = @($workflowIds | Where-Object { $_ -eq 'all-validated' })
$workflowIds = @($workflowIds | Where-Object { $_ -ne 'all-validated' })
$activeIds = @($catalog.applications |
    Where-Object status -ne 'pending-validation' |
    ForEach-Object id |
    Sort-Object -Unique)
if (Compare-Object -ReferenceObject $activeIds -DifferenceObject $workflowIds) {
    throw "Workflow selector IDs do not match packageable catalog IDs. Catalog=[$($activeIds -join ', ')], workflow=[$($workflowIds -join ', ')]."
}
if ($bulkOption.Count -ne 1) {
    throw "Workflow selector must include exactly one 'all-validated' option."
}
if ($workflow -notmatch '(?m)^\s+ref:\s+\$\{\{\s*github\.ref\s*\}\}\s*$') {
    throw 'Package and deployment jobs must check out the workflow ref instead of hardcoding main.'
}

foreach ($scriptPath in Get-ChildItem -LiteralPath "$PSScriptRoot" -Filter '*.ps1' -File) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null
    if ($parseErrors.Count -gt 0) {
        throw "$($scriptPath.Name): $($parseErrors[0].Message)"
    }
}
if ($workflow -notmatch '(?m)^\s+\.\s*\\scripts\\Test-IntuneInstaller\.ps1\s+-Application\s+\$app') {
    throw 'The Intune packaging job must smoke-test each installer before deployment.'
}

$pendingApp = $catalog.applications |
    Where-Object status -eq 'pending-validation' |
    Select-Object -First 1
if ($pendingApp) {
    $guardRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
    $updateRejected = $false
    try {
        & "$PSScriptRoot\Update-ApplicationCatalog.ps1" `
            -ApplicationId $pendingApp.id `
            -DownloadRoot (Join-Path $guardRoot 'update')
    }
    catch {
        $updateRejected = $_.Exception.Message -like '*pending vendor validation*'
    }
    if (-not $updateRejected) {
        throw 'Catalog updater did not reject a pending application.'
    }

    $packageRejected = $false
    try {
        & "$PSScriptRoot\Package-IntuneApplication.ps1" `
            -Application $pendingApp `
            -OutputDirectory (Join-Path $guardRoot 'package')
    }
    catch {
        $packageRejected = $_.Exception.Message -like '*pending vendor validation*'
    }
    if (-not $packageRejected) {
        throw 'Packager did not reject a pending application.'
    }

    $deployRejected = $false
    try {
        & "$PSScriptRoot\Deploy-IntuneApplication.ps1" `
            -ApplicationId $pendingApp.id `
            -CatalogPath $CatalogPath `
            -PackageRoot (Join-Path $guardRoot 'deploy')
    }
    catch {
        $deployRejected = $_.Exception.Message -like '*pending vendor validation*'
    }
    if (-not $deployRejected) {
        throw 'Deployment script did not reject a pending application.'
    }
    if (Test-Path -LiteralPath $guardRoot) {
        throw 'A pending-application guard created files before rejecting the request.'
    }
}

Write-Host "Catalog validation passed: $($catalog.applications.Count) applications, $($activeIds.Count) packageable, $(@($catalog.applications | Where-Object status -eq 'pending-validation').Count) pending validation."
