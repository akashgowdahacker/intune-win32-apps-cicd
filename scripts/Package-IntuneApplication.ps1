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
$installer = Join-Path $source $Application.package.setupFile
Invoke-WebRequest -Uri $Application.package.downloadUrl -OutFile $installer

$metadataJson = & "$PSScriptRoot\Get-InstallerMetadata.ps1" -InstallerPath $installer -InstallerType $Application.installerType
if ([string]::IsNullOrWhiteSpace(($metadataJson -join ''))) {
    throw "Installer metadata extraction returned no output for '$installer'."
}
$metadata = ($metadataJson -join [Environment]::NewLine) | ConvertFrom-Json
if ($Application.installerType -eq 'msi') {
    $Application.package.installCommand = $metadata.installCommand
    $Application.package.uninstallCommand = $metadata.uninstallCommand
    $Application.package.detectionRule = $metadata.detectionRule
    if (-not $Application.package.upgradeBehavior) {
        $Application.package.upgradeBehavior = 'in-place'
    }
}
if (-not (Test-Path -LiteralPath $ToolPath)) {
    Invoke-WebRequest -Uri 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/raw/master/IntuneWinAppUtil.exe' -OutFile $ToolPath
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
