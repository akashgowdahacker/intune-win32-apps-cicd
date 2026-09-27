[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ApplicationId,
    [string]$CatalogPath = "$PSScriptRoot\..\apps\applications.json",
    [string]$PackageRoot = "$PSScriptRoot\..\artifacts"
)

$ErrorActionPreference = 'Stop'
foreach ($name in 'INTUNE_TENANT_ID', 'INTUNE_CLIENT_ID', 'INTUNE_CLIENT_SECRET') {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "Required GitHub Actions secret is not configured: $name"
    }
}

$catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
$app = $catalog.applications | Where-Object id -eq $ApplicationId | Select-Object -First 1
if (-not $app) { throw "Application '$ApplicationId' was not found in '$CatalogPath'." }
if ([string]::IsNullOrWhiteSpace($app.package.installCommand) -or
    [string]::IsNullOrWhiteSpace($app.package.uninstallCommand)) {
    throw "$ApplicationId is missing installCommand or uninstallCommand."
}

$package = Get-ChildItem -LiteralPath (Join-Path $PackageRoot $ApplicationId) -Filter '*.intunewin' -File -Recurse |
    Select-Object -First 1
if (-not $package) { throw "No .intunewin package found for '$ApplicationId' under '$PackageRoot'." }

$moduleVersion = '1.5.0'
if (-not (Get-Module -ListAvailable -Name IntuneWin32App -RequiredVersion $moduleVersion)) {
    Install-Module -Name IntuneWin32App -RequiredVersion $moduleVersion -Repository PSGallery -Scope CurrentUser -Force -AllowClobber
}
Import-Module -Name IntuneWin32App -RequiredVersion $moduleVersion -Force
Connect-MSIntuneGraph `
    -TenantID $env:INTUNE_TENANT_ID `
    -ClientID $env:INTUNE_CLIENT_ID `
    -ClientSecret $env:INTUNE_CLIENT_SECRET `
    -Scopes @('DeviceManagementApps.ReadWrite.All') | Out-Null

$matchingApps = @(Get-IntuneWin32App -DisplayName $app.displayName |
    Where-Object { $_.displayName -ceq $app.displayName })
if ($matchingApps.Count -gt 0) {
    throw "A Win32 app named '$($app.displayName)' already exists in Intune. Refusing to overwrite or change any existing app or assignments during this first upload-only test."
}

if ($app.package.detectionRule.type -ne 'file') {
    throw "Detection rule type '$($app.package.detectionRule.type)' is not yet supported by the deployment adapter."
}
$detectionRule = New-IntuneWin32AppDetectionRuleFile `
    -Existence `
    -Path $app.package.detectionRule.path `
    -FileOrFolder $app.package.detectionRule.fileOrFolderName `
    -DetectionType $app.package.detectionRule.detectionMethod

$osRelease = switch ($app.package.requirements.minimumOS) {
    'W10-21H2' { 'W10_21H2' }
    default { throw "Unsupported minimumOS value '$($app.package.requirements.minimumOS)'." }
}
$requirementRule = New-IntuneWin32AppRequirementRule `
    -Architecture $app.package.requirements.architecture `
    -MinimumSupportedWindowsRelease $osRelease `
    -MinimumFreeDiskSpaceInMB $app.package.requirements.minimumDiskSpaceInMB

$createdApp = Add-IntuneWin32App `
    -FilePath $package.FullName `
    -DisplayName $app.displayName `
    -Description $app.description `
    -Publisher $app.publisher `
    -AppVersion $app.currentVersion `
    -InstallCommandLine $app.package.installCommand `
    -UninstallCommandLine $app.package.uninstallCommand `
    -InstallExperience $app.package.installExperience `
    -RestartBehavior $app.package.restartBehavior `
    -DetectionRule $detectionRule `
    -RequirementRule $requirementRule `
    -ErrorAction Stop

if (-not $createdApp -or [string]::IsNullOrWhiteSpace($createdApp.id)) {
    throw "Intune did not return a created app ID for '$($app.displayName)'."
}
Write-Host "Created Intune Win32 app '$($app.displayName)' (ID: $($createdApp.id)); no assignments were created."
