[CmdletBinding()]
param(
    [string]$CatalogPath = "$PSScriptRoot\..\apps\applications.json",
    [string]$DownloadRoot = "$PSScriptRoot\..\downloads",
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Path $DownloadRoot -Force | Out-Null

foreach ($app in $catalog.applications) {
    if ($app.source.type -eq 'github-release') {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$($app.source.repository)/releases/latest" -Headers @{ 'User-Agent' = 'intune-packaging' }
        $asset = $release.assets | Where-Object { $_.name -match $app.source.assetRegex } | Select-Object -First 1
        if (-not $asset) { throw "$($app.id): no release asset matched $($app.source.assetRegex)" }
        $assetName = $asset.name
        $downloadUrl = $asset.browser_download_url
    }
    elseif ($app.source.type -eq 'direct-url') {
        $downloadUrl = $app.source.downloadUrl
        $assetName = [IO.Path]::GetFileName(([Uri]$downloadUrl).AbsolutePath)
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
    else {
        throw "$($app.id): source.versionRegex or source.assetRegex is required."
    }
    $match = [regex]::Match($assetName, $versionPattern)
    if (-not $match.Success -or -not $match.Groups['version'].Success) {
        throw "$($app.id): version pattern did not produce a named 'version' group for '$assetName'."
    }
    $newVersion = $match.Groups['version'].Value
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
