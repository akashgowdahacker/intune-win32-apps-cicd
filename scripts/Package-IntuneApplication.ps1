[CmdletBinding()]
param(
    [Parameter(Mandatory)][pscustomobject]$Application,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$ToolPath = "$PSScriptRoot\..\IntuneWinAppUtil.exe",
    [string]$CatalogPath
)

$ErrorActionPreference = 'Stop'
if ($Application.status -eq 'pending-validation') {
    throw "$($Application.id): application is pending vendor validation and cannot be packaged."
}
if ([string]::IsNullOrWhiteSpace($Application.package.downloadUrl)) {
    throw "$($Application.id): package.downloadUrl is missing. Run the catalog update first."
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$source = Join-Path $OutputDirectory 'source'
$package = Join-Path $OutputDirectory 'package'
New-Item -ItemType Directory -Path $source,$package -Force | Out-Null
if ($Application.package.installScript) {
    $installScriptName = [IO.Path]::GetFileName($Application.package.installScript)
    if ($installScriptName -ne $Application.package.installScript) {
        throw "$($Application.id): package.installScript must be a file name."
    }
    $installScriptPath = Join-Path $PSScriptRoot $installScriptName
    if (-not (Test-Path -LiteralPath $installScriptPath -PathType Leaf)) {
        throw "$($Application.id): install script was not found at '$installScriptPath'."
    }
    Copy-Item -LiteralPath $installScriptPath -Destination (Join-Path $source $installScriptName)
}
$installer = Join-Path $source $Application.package.setupFile
$downloadUrl = $Application.package.downloadUrl
if ($Application.source.type -eq 'winscp-download') {
    $downloadPage = Invoke-WebRequest -Uri $Application.source.downloadPageUrl -UseBasicParsing
    $fileNamePattern = [regex]::Escape($Application.package.setupFile)
    $downloadMatch = [regex]::Match(
        $downloadPage.Content,
        "href=[""'](?<url>https://cdn\.winscp\.net/files/$fileNamePattern\?secure=[^""']+)[""']"
    )
    if (-not $downloadMatch.Success) {
        throw "$($Application.id): vendor download page did not provide a signed CDN URL for '$($Application.package.setupFile)'."
    }
    $downloadUrl = [Net.WebUtility]::HtmlDecode($downloadMatch.Groups['url'].Value)
}
Invoke-WebRequest -Uri $downloadUrl -OutFile $installer -UseBasicParsing
if ($Application.source.sha256) {
    $actualHash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
    if ($actualHash -ine $Application.source.sha256) {
        throw "$($Application.id): installer SHA-256 '$actualHash' did not match the catalog value."
    }
}
if ($Application.source.signerSubject) {
    $signature = Get-AuthenticodeSignature -FilePath $installer
    if ($signature.Status -ne 'Valid' -or
        $signature.SignerCertificate.Subject -notlike "*$($Application.source.signerSubject)*") {
        throw "$($Application.id): installer signature is invalid or is not signed by '$($Application.source.signerSubject)'."
    }
}

$metadataJson = & "$PSScriptRoot\Get-InstallerMetadata.ps1" -InstallerPath $installer -InstallerType $Application.installerType
if ([string]::IsNullOrWhiteSpace(($metadataJson -join ''))) {
    throw "Installer metadata extraction returned no output for '$installer'."
}
$metadata = ($metadataJson -join [Environment]::NewLine) | ConvertFrom-Json
if ($Application.installerType -eq 'msi') {
    $Application.package.installCommand = if ($installScriptName) {
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScriptName"
    }
    else {
        $metadata.installCommand
    }
    $Application.package.uninstallCommand = $metadata.uninstallCommand
    $Application.package.detectionRule = $metadata.detectionRule
    if (-not $Application.package.upgradeBehavior) {
        $Application.package.upgradeBehavior = 'in-place'
    }
}
if (-not (Test-Path -LiteralPath $ToolPath)) {
    Invoke-WebRequest -Uri 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/raw/master/IntuneWinAppUtil.exe' -OutFile $ToolPath -UseBasicParsing
}
& $ToolPath -c $source -s $Application.package.setupFile -o $package -q
if ($LASTEXITCODE -ne 0) { throw "IntuneWinAppUtil failed with exit code $LASTEXITCODE." }
$result = Get-ChildItem -LiteralPath $package -Filter '*.intunewin' | Select-Object -First 1
if (-not $result) { throw "No .intunewin package was produced." }
if ($CatalogPath) {
    $catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
    $catalogApplication = $catalog.applications | Where-Object id -eq $Application.id | Select-Object -First 1
    if (-not $catalogApplication) {
        throw "Application '$($Application.id)' was not found in catalog '$CatalogPath'."
    }
    $catalogApplication.package.setupFile = $Application.package.setupFile
    $catalogApplication.package.downloadUrl = $Application.package.downloadUrl
    $catalogApplication.package.installCommand = $Application.package.installCommand
    $catalogApplication.package.uninstallCommand = $Application.package.uninstallCommand
    $catalogApplication.package.detectionRule = $Application.package.detectionRule
    $catalog | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $CatalogPath -Encoding utf8
    Write-Host "Persisted installer metadata for $($Application.id) to $CatalogPath"
}
[pscustomobject]@{ packagePath = $result.FullName; installerPath = $installer; metadata = $metadata }
