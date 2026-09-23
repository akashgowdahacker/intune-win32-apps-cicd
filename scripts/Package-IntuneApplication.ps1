[CmdletBinding()]
param(
    [Parameter(Mandatory)][pscustomobject]$Application,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$ToolPath = "$PSScriptRoot\..\IntuneWinAppUtil.exe"
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Application.package.downloadUrl)) {
    throw "$($Application.id): package.downloadUrl is missing. Run the catalog update first."
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$source = Join-Path $OutputDirectory 'source'
$package = Join-Path $OutputDirectory 'package'
New-Item -ItemType Directory -Path $source,$package -Force | Out-Null
$installer = Join-Path $source $Application.package.setupFile
Invoke-WebRequest -Uri $Application.package.downloadUrl -OutFile $installer

$metadata = & "$PSScriptRoot\Get-InstallerMetadata.ps1" -InstallerPath $installer -InstallerType $Application.installerType | ConvertFrom-Json
if ($Application.installerType -eq 'msi') {
    $Application.package.installCommand = $metadata.installCommand
    $Application.package.uninstallCommand = $metadata.uninstallCommand
    $Application.package.detectionRule = $metadata.detectionRule
}
if (-not (Test-Path -LiteralPath $ToolPath)) {
    Invoke-WebRequest -Uri 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/raw/master/IntuneWinAppUtil.exe' -OutFile $ToolPath
}
& $ToolPath -c $source -s $Application.package.setupFile -o $package -q
if ($LASTEXITCODE -ne 0) { throw "IntuneWinAppUtil failed with exit code $LASTEXITCODE." }
$result = Get-ChildItem -LiteralPath $package -Filter '*.intunewin' | Select-Object -First 1
if (-not $result) { throw "No .intunewin package was produced." }
[pscustomobject]@{ packagePath = $result.FullName; installerPath = $installer; metadata = $metadata }

