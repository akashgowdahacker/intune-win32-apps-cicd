[CmdletBinding()]
param(
    [string]$CatalogPath = "$PSScriptRoot\..\apps\applications.json",
    [string]$DownloadRoot = "$PSScriptRoot\..\downloads",
    [string]$ApplicationId,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
$applications = if ($ApplicationId) {
    @($catalog.applications | Where-Object id -eq $ApplicationId)
}
else {
    @($catalog.applications | Where-Object status -ne 'pending-validation')
}
if ($ApplicationId -and $applications.Count -eq 0) {
    throw "Application '$ApplicationId' was not found in '$CatalogPath'."
}
if ($ApplicationId -and $applications[0].status -eq 'pending-validation') {
    throw "Application '$ApplicationId' is pending vendor validation and cannot be updated."
}
if (-not $ApplicationId) {
    $pendingCount = @($catalog.applications | Where-Object status -eq 'pending-validation').Count
    if ($pendingCount -gt 0) {
        Write-Host "Skipping $pendingCount application(s) pending vendor validation."
    }
}
New-Item -ItemType Directory -Path $DownloadRoot -Force | Out-Null
$githubHeaders = @{ 'User-Agent' = 'intune-packaging'; 'Accept' = 'application/vnd.github+json' }
if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
    $githubHeaders.Authorization = "Bearer $($env:GITHUB_TOKEN)"
}

foreach ($app in $applications) {
    if ($app.source.type -eq 'github-release') {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$($app.source.repository)/releases/latest" -Headers $githubHeaders
        $asset = $release.assets | Where-Object { $_.name -match $app.source.assetRegex } | Select-Object -First 1
        if (-not $asset) { throw "$($app.id): no release asset matched $($app.source.assetRegex)" }
        $assetName = $asset.name
        $downloadUrl = $asset.browser_download_url
    }
    elseif ($app.source.type -eq 'direct-url') {
        $downloadUrl = $app.source.downloadUrl
        $assetName = if ($app.source.fileName) {
            $app.source.fileName
        }
        else {
            [IO.Path]::GetFileName(([Uri]$downloadUrl).AbsolutePath)
        }
        if ([string]::IsNullOrWhiteSpace($assetName) -or
            [IO.Path]::GetFileName($assetName) -ne $assetName) {
            throw "$($app.id): direct-url source needs a valid fileName when its URL has no installer filename."
        }
    }
    else {
        throw "$($app.id): unsupported source type '$($app.source.type)'. Use github-release or direct-url."
    }

    $versionPattern = if ($app.source.versionRegex) {
        $app.source.versionRegex
    }
    elseif ($app.source.assetRegex) {
        $app.source.assetRegex
    }
    elseif ($app.source.versionSource -eq 'installer') {
        $null
    }
    else {
        throw "$($app.id): source.versionRegex or source.assetRegex is required."
    }
    $match = if ($versionPattern) { [regex]::Match($assetName, $versionPattern) } else { $null }
    if ($app.source.versionSource -eq 'installer') {
        $probePath = Join-Path $DownloadRoot $assetName
        Invoke-WebRequest -Uri $downloadUrl -OutFile $probePath
        $metadataJson = & "$PSScriptRoot\Get-InstallerMetadata.ps1" -InstallerPath $probePath -InstallerType $app.installerType
        if ([string]::IsNullOrWhiteSpace(($metadataJson -join ''))) {
            throw "$($app.id): installer metadata returned no version."
        }
        $newVersion = (($metadataJson -join [Environment]::NewLine) | ConvertFrom-Json).version
    }
    elseif (
        -not $match.Success -or
        ($app.source.versionFormat -and
            (-not $match.Groups['major'].Success -or -not $match.Groups['minor'].Success)) -or
        (-not $app.source.versionFormat -and -not $match.Groups['version'].Success)
    ) {
        throw "$($app.id): version pattern did not produce the required version groups for '$assetName'."
    }
    else {
        if ($app.source.versionFormat) {
            $newVersion = $app.source.versionFormat -f $match.Groups['major'].Value, $match.Groups['minor'].Value
        }
        else {
            $newVersion = $match.Groups['version'].Value
        }
    }
    if (-not ($app.package.PSObject.Properties.Name -contains 'downloadUrl')) {
        $app.package | Add-Member -NotePropertyName 'downloadUrl' -NotePropertyValue $null
    }
    if (-not ($app.PSObject.Properties.Name -contains 'availableVersion')) {
        $app | Add-Member -NotePropertyName 'availableVersion' -NotePropertyValue $null
    }
    $app.package.setupFile = $assetName
    $app.package.downloadUrl = $downloadUrl
    $app.availableVersion = $newVersion
    Write-Host "$($app.id): deployed=$($app.currentVersion), available=$newVersion"

    if ($Apply -and ([version]$newVersion -gt [version]$app.currentVersion)) {
        $app.previousVersion = $app.currentVersion
        $app.currentVersion = $newVersion
        $app.availableVersion = $null
    }
}

$catalog | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $CatalogPath -Encoding utf8
