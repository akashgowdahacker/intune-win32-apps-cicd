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
$installedModule = Get-Module -ListAvailable -Name IntuneWin32App |
    Where-Object Version -eq ([version]$moduleVersion) |
    Select-Object -First 1
if (-not $installedModule) {
    Install-Module -Name IntuneWin32App -RequiredVersion $moduleVersion -Repository PSGallery -Scope CurrentUser -Force -AllowClobber
}
Import-Module -Name IntuneWin32App -RequiredVersion $moduleVersion -Force
$authenticationHeader = Connect-MSIntuneGraph `
    -TenantID $env:INTUNE_TENANT_ID `
    -ClientID $env:INTUNE_CLIENT_ID `
    -ClientSecret $env:INTUNE_CLIENT_SECRET `
    -Scopes @('DeviceManagementApps.ReadWrite.All')
if (-not $authenticationHeader) {
    throw 'Microsoft Graph authentication did not return an authorization header.'
}

$matchingApps = @(Get-IntuneWin32App -DisplayName $app.displayName |
    Where-Object { $_.displayName -ceq $app.displayName })
if ($matchingApps.Count -gt 1) {
    throw "Found multiple Intune Win32 apps named '$($app.displayName)'; refusing to choose one."
}

$intuneApp = $null
if ($matchingApps.Count -eq 1) {
    $intuneApp = $matchingApps[0]
    if ($intuneApp.publisher -cne $app.publisher) {
        throw "The existing '$($app.displayName)' app has publisher '$($intuneApp.publisher)', not '$($app.publisher)'; refusing to assign a potentially unrelated app."
    }
    Write-Host "Reusing existing Intune Win32 app '$($app.displayName)' (ID: $($intuneApp.id)); package content will not be changed."
}
else {
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

    $intuneApp = Add-IntuneWin32App `
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

    if (-not $intuneApp -or [string]::IsNullOrWhiteSpace($intuneApp.id)) {
        throw "Intune did not return a created app ID for '$($app.displayName)'."
    }
    Write-Host "Created Intune Win32 app '$($app.displayName)' (ID: $($intuneApp.id))."
}

foreach ($assignment in $app.assignments) {
    if ($assignment.intent -notin @('available', 'required', 'uninstall')) {
        throw "Unsupported assignment intent '$($assignment.intent)' for '$ApplicationId'."
    }
    if ($assignment.groupId -notmatch '^[0-9a-fA-F-]{36}$') {
        throw "Invalid Entra group object ID '$($assignment.groupId)' for '$ApplicationId'."
    }

    $assignmentsUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($intuneApp.id)/assignments"
    $existingAssignments = Invoke-RestMethod -Method Get -Uri $assignmentsUri -Headers $authenticationHeader
    $targetAssignments = @($existingAssignments.value | Where-Object {
        $_.target.'@odata.type' -like '*groupAssignmentTarget' -and
        $_.target.groupId -eq $assignment.groupId
    })
    if ($targetAssignments.Count -gt 1) {
        throw "The group '$($assignment.groupId)' already has multiple include assignments on '$($app.displayName)'; refusing to modify them."
    }
    if ($targetAssignments.Count -eq 1) {
        if ($targetAssignments[0].target.'@odata.type' -ne '#microsoft.graph.groupAssignmentTarget') {
            throw "The group '$($assignment.groupId)' is already excluded from '$($app.displayName)'; refusing to add an include assignment."
        }
        if ($targetAssignments[0].intent -ne $assignment.intent) {
            throw "The group '$($assignment.groupId)' already has intent '$($targetAssignments[0].intent)' on '$($app.displayName)', not '$($assignment.intent)'; refusing to alter an existing assignment."
        }
        if ($targetAssignments[0].target.deviceAndAppManagementAssignmentFilterId) {
            throw "The existing assignment for group '$($assignment.groupId)' has a filter; refusing to treat it as the unfiltered catalog assignment."
        }
        Write-Host "Assignment already exists: group $($assignment.groupId), intent $($assignment.intent); no change needed."
        continue
    }

    $assignmentBody = @{
        '@odata.type' = '#microsoft.graph.mobileAppAssignment'
        intent = $assignment.intent
        source = 'direct'
        target = @{
            '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
            groupId = $assignment.groupId
            deviceAndAppManagementAssignmentFilterId = $null
            deviceAndAppManagementAssignmentFilterType = 'none'
        }
        settings = @{
            '@odata.type' = '#microsoft.graph.win32LobAppAssignmentSettings'
            notifications = 'showAll'
            restartSettings = $null
            deliveryOptimizationPriority = 'notConfigured'
            installTimeSettings = $null
        }
    }
    $createdAssignment = Invoke-RestMethod `
        -Method Post `
        -Uri $assignmentsUri `
        -Headers $authenticationHeader `
        -ContentType 'application/json' `
        -Body ($assignmentBody | ConvertTo-Json -Depth 10)
    if (-not $createdAssignment -or -not $createdAssignment.id) {
        throw "Graph did not confirm creation of the '$($assignment.intent)' assignment for group '$($assignment.groupId)'."
    }
    Write-Host "Created '$($assignment.intent)' assignment for group $($assignment.groupId) on '$($app.displayName)' (assignment ID: $($createdAssignment.id))."
}
