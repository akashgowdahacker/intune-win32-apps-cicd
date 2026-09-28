[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ApplicationId,
    [string]$CatalogPath = "$PSScriptRoot\..\apps\applications.json",
    [string]$PackageRoot = "$PSScriptRoot\..\artifacts"
)

$ErrorActionPreference = 'Stop'
$catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
$app = $catalog.applications | Where-Object id -eq $ApplicationId | Select-Object -First 1
if (-not $app) { throw "Application '$ApplicationId' was not found in '$CatalogPath'." }
if ($app.status -eq 'pending-validation') {
    throw "$ApplicationId is pending vendor validation and cannot be deployed."
}
if ([string]::IsNullOrWhiteSpace($app.package.installCommand) -or
    [string]::IsNullOrWhiteSpace($app.package.uninstallCommand)) {
    throw "$ApplicationId is missing installCommand or uninstallCommand."
}
foreach ($name in 'INTUNE_TENANT_ID', 'INTUNE_CLIENT_ID', 'INTUNE_CLIENT_SECRET') {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "Required GitHub Actions secret is not configured: $name"
    }
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

function Get-ComparableVersion {
    param([AllowNull()][string]$Version)
    if ([string]::IsNullOrWhiteSpace($Version)) { return [version]'0.0.0' }
    try {
        return [version]$Version.Trim()
    }
    catch {
        return [version]'0.0.0'
    }
}

$matchingApps = @(Get-IntuneWin32App -DisplayName $app.displayName |
    Where-Object {
        $_.publisher -ceq $app.publisher -and
        ($_.displayName -ceq $app.displayName -or $_.displayName -like "$($app.displayName)*")
    })

$catalogVersion = Get-ComparableVersion $app.currentVersion
$productionApp = $null
$productionVersion = [version]'0.0.0'
foreach ($candidate in $matchingApps) {
    $candidateVersion = if ($candidate.appVersion) { $candidate.appVersion } else { $candidate.displayName -replace '^.*\((?<version>.*)\)$', '$1' }
    $candidateComparable = Get-ComparableVersion $candidateVersion
    if (-not $productionApp -or $candidateComparable -gt $productionVersion) {
        $productionApp = $candidate
        $productionVersion = $candidateComparable
    }
}

$lowerVersionApps = @($matchingApps | Where-Object {
    $candidateVersion = if ($_.appVersion) { $_.appVersion } else { $_.displayName -replace '^.*\((?<version>.*)\)$', '$1' }
    (Get-ComparableVersion $candidateVersion) -lt $productionVersion
})
if ($lowerVersionApps.Count -gt 0) {
    Write-Host "Ignoring $($lowerVersionApps.Count) stale lower-version Intune app(s) for '$($app.displayName)' while keeping the latest production version as the active app."
}

$versionedName = "$($app.displayName) ($($app.currentVersion))"
$versionedApp = @($matchingApps | Where-Object { $_.displayName -ceq $versionedName } | Select-Object -First 1)
$stagedNewVersion = $false

$intuneApp = $null
if ($matchingApps.Count -gt 0 -and $productionApp -and $catalogVersion -le $productionVersion) {
    $intuneApp = $productionApp
    if ($intuneApp.publisher -cne $app.publisher) {
        throw "The existing '$($app.displayName)' app has publisher '$($intuneApp.publisher)', not '$($app.publisher)'; refusing to assign a potentially unrelated app."
    }
    if ($catalogVersion -eq $productionVersion) {
        Write-Host "No staged upgrade created for '$($app.displayName)' because the catalog version ($catalogVersion) matches the newest Intune production version ($productionVersion); ignoring lower-version duplicates."
    }
    else {
        Write-Host "No staged upgrade created for '$($app.displayName)' because the catalog version ($catalogVersion) is lower than the newest Intune production version ($productionVersion); ignoring stale lower-version app(s)."
    }
}
elseif ($matchingApps.Count -gt 0 -and $productionApp -and $catalogVersion -gt $productionVersion) {
    if (-not $versionedApp) {
        $detectionRule = switch ($app.package.detectionRule.type) {
            'file' {
                New-IntuneWin32AppDetectionRuleFile `
                    -Existence `
                    -Path $app.package.detectionRule.path `
                    -FileOrFolder $app.package.detectionRule.fileOrFolderName `
                    -DetectionType $app.package.detectionRule.detectionMethod
            }
            'msi' {
                if ([string]::IsNullOrWhiteSpace($app.package.detectionRule.productCode)) {
                    throw "$ApplicationId has an MSI detection rule without a product code."
                }
                New-IntuneWin32AppDetectionRuleMSI `
                    -ProductCode $app.package.detectionRule.productCode
            }
            default {
                throw "Detection rule type '$($app.package.detectionRule.type)' is not supported by the deployment adapter."
            }
        }

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
            -DisplayName $versionedName `
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
            throw "Intune did not return a created app ID for '$versionedName'."
        }
        Write-Host "Created staged Intune Win32 app '$versionedName' (ID: $($intuneApp.id)) without assignments so the current production app remains active while the new version is tested."
        $stagedNewVersion = $true
    }
    else {
        $intuneApp = $versionedApp
        Write-Host "Reusing staged Intune Win32 app '$($intuneApp.displayName)' (ID: $($intuneApp.id)); package content will not be changed."
    }
}
else {
    $detectionRule = switch ($app.package.detectionRule.type) {
        'file' {
            New-IntuneWin32AppDetectionRuleFile `
                -Existence `
                -Path $app.package.detectionRule.path `
                -FileOrFolder $app.package.detectionRule.fileOrFolderName `
                -DetectionType $app.package.detectionRule.detectionMethod
        }
        'msi' {
            if ([string]::IsNullOrWhiteSpace($app.package.detectionRule.productCode)) {
                throw "$ApplicationId has an MSI detection rule without a product code."
            }
            New-IntuneWin32AppDetectionRuleMSI `
                -ProductCode $app.package.detectionRule.productCode
        }
        default {
            throw "Detection rule type '$($app.package.detectionRule.type)' is not supported by the deployment adapter."
        }
    }

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

if ($stagedNewVersion) {
    Write-Host "Skipping assignments for the staged version '$versionedName' to keep the current production app active while the newer build is validated."
}
else {
    foreach ($assignment in $app.assignments) {
        if ($assignment.intent -notin @('available', 'required', 'uninstall')) {
            throw "Unsupported assignment intent '$($assignment.intent)' for '$ApplicationId'."
        }
        if (-not $assignment.notifications) {
            $assignment.notifications = 'hideAll'
        }
        if ($assignment.notifications -notin @('showAll', 'showReboot', 'hideAll')) {
            throw "Unsupported assignment notification setting '$($assignment.notifications)' for '$ApplicationId'."
        }
        if ($assignment.groupId -notmatch '^[0-9a-fA-F-]{36}$') {
            throw "Invalid Entra group object ID '$($assignment.groupId)' for '$ApplicationId'."
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
                notifications = $assignment.notifications
                restartSettings = $null
                deliveryOptimizationPriority = 'notConfigured'
                installTimeSettings = $null
            }
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
            if ($targetAssignments[0].source -eq 'policySets') {
                throw "The existing assignment for group '$($assignment.groupId)' is managed by a policy set and cannot be updated directly."
            }
            if ($targetAssignments[0].settings.notifications -ne $assignment.notifications) {
                $replacementSettings = $targetAssignments[0].settings |
                    ConvertTo-Json -Depth 20 |
                    ConvertFrom-Json -AsHashtable
                $replacementSettings.notifications = $assignment.notifications
                $replacementBody = @{
                    '@odata.type' = '#microsoft.graph.mobileAppAssignment'
                    intent = $targetAssignments[0].intent
                    source = 'direct'
                    target = $targetAssignments[0].target
                    settings = $replacementSettings
                }
                $restoreBody = @{
                    '@odata.type' = '#microsoft.graph.mobileAppAssignment'
                    intent = $targetAssignments[0].intent
                    target = $targetAssignments[0].target
                    settings = $targetAssignments[0].settings
                }
                Invoke-RestMethod `
                    -Method Delete `
                    -Uri "$assignmentsUri/$($targetAssignments[0].id)" `
                    -Headers $authenticationHeader | Out-Null
                try {
                    $replacementAssignment = Invoke-RestMethod `
                        -Method Post `
                        -Uri $assignmentsUri `
                        -Headers $authenticationHeader `
                        -ContentType 'application/json' `
                        -Body ($replacementBody | ConvertTo-Json -Depth 20)
                    if (-not $replacementAssignment -or
                        -not $replacementAssignment.id -or
                        $replacementAssignment.settings.notifications -ne $assignment.notifications) {
                        throw "Graph did not confirm the replacement assignment with notifications '$($assignment.notifications)'."
                    }
                }
                catch {
                    $replacementError = $_
                    try {
                        $restoredAssignment = Invoke-RestMethod `
                            -Method Post `
                            -Uri $assignmentsUri `
                            -Headers $authenticationHeader `
                            -ContentType 'application/json' `
                            -Body ($restoreBody | ConvertTo-Json -Depth 20)
                        if (-not $restoredAssignment -or -not $restoredAssignment.id) {
                            throw 'Graph did not confirm restoration of the previous assignment.'
                        }
                    }
                    catch {
                        throw "Could not apply notification setting '$($assignment.notifications)' and could not restore the previous assignment. Update error: $($replacementError.Exception.Message). Restore error: $($_.Exception.Message)"
                    }
                    throw "Could not apply notification setting '$($assignment.notifications)'; restored the previous assignment. Update error: $($replacementError.Exception.Message)"
                }
                Write-Host "Replaced group $($assignment.groupId) assignment with notifications '$($assignment.notifications)' (assignment ID: $($replacementAssignment.id))."
            }
            else {
                Write-Host "Assignment already matches catalog: group $($assignment.groupId), intent $($assignment.intent), notifications $($assignment.notifications)."
            }
            continue
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
        if ($createdAssignment.settings.notifications -ne $assignment.notifications) {
            throw "Assignment was created but Graph returned notification setting '$($createdAssignment.settings.notifications)' instead of '$($assignment.notifications)'."
        }
        Write-Host "Created '$($assignment.intent)' assignment for group $($assignment.groupId) on '$($app.displayName)' with notifications '$($assignment.notifications)' (assignment ID: $($createdAssignment.id))."
    }
}
