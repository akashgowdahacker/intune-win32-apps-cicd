[CmdletBinding()]
param(
    [Parameter(Mandatory)][pscustomobject]$Application,
    [Parameter(Mandatory)][string]$InstallerPath,
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
    throw "$($Application.id): installer not found at '$InstallerPath'."
}

function Test-ApplicationDetected {
    param([Parameter(Mandatory)][pscustomobject]$App)

    switch ($App.package.detectionRule.type) {
        'msi' {
            $productCode = $App.package.detectionRule.productCode
            if ([string]::IsNullOrWhiteSpace($productCode)) {
                throw "$($App.id): MSI detection rule has no productCode."
            }
            $windowsInstaller = New-Object -ComObject WindowsInstaller.Installer
            try {
                $productState = $windowsInstaller.ProductState($productCode)
                Write-Host "$($App.id): Windows Installer ProductState for $productCode is $productState."
                return $productState -eq 5
            }
            finally {
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($windowsInstaller)
            }
        }
        'file' {
            $directory = [Environment]::ExpandEnvironmentVariables($App.package.detectionRule.path)
            $fileOrFolder = $App.package.detectionRule.fileOrFolderName
            return Test-Path -LiteralPath (Join-Path $directory $fileOrFolder)
        }
        default {
            throw "$($App.id): unsupported detection rule '$($App.package.detectionRule.type)'."
        }
    }
}

function Invoke-CatalogCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    $expandedCommand = [Environment]::ExpandEnvironmentVariables($Command)
    $commandMatch = [regex]::Match(
        $expandedCommand,
        '^\s*(?:"(?<executable>[^"]+)"|(?<executable>\S+))\s*(?<arguments>.*)$'
    )
    if (-not $commandMatch.Success) {
        throw "$($Application.id): could not parse the $Description command."
    }

    $executable = $commandMatch.Groups['executable'].Value
    if (-not [IO.Path]::IsPathRooted($executable)) {
        $localExecutable = Join-Path $WorkingDirectory $executable
        if (Test-Path -LiteralPath $localExecutable -PathType Leaf) {
            $executable = $localExecutable
        }
        else {
            $resolvedCommand = Get-Command -Name $executable -CommandType Application -ErrorAction Stop |
                Select-Object -First 1
            $executable = $resolvedCommand.Source
        }
    }
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "$($Application.id): $Description executable was not found: '$executable'."
    }

    $process = Start-Process `
        -FilePath $executable `
        -ArgumentList $commandMatch.Groups['arguments'].Value `
        -WorkingDirectory $WorkingDirectory `
        -PassThru
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $process.Id -Force
        throw "$($Application.id): $Description exceeded the $TimeoutSeconds second timeout."
    }
    $process.Refresh()
    if ($process.ExitCode -notin @(0, 3010)) {
        throw "$($Application.id): $Description exited with code $($process.ExitCode)."
    }
    Write-Host "$($Application.id): $Description completed with exit code $($process.ExitCode)."
}

if ([string]::IsNullOrWhiteSpace($Application.package.installCommand) -or
    [string]::IsNullOrWhiteSpace($Application.package.uninstallCommand) -or
    -not $Application.package.detectionRule) {
    throw "$($Application.id): install, uninstall, and detection metadata are required for smoke testing."
}

$workingDirectory = Split-Path -Parent (Resolve-Path -LiteralPath $InstallerPath).Path
if (Test-ApplicationDetected -App $Application) {
    Write-Host "$($Application.id): removing the pre-existing copy from this disposable runner before testing."
    Invoke-CatalogCommand `
        -Command $Application.package.uninstallCommand `
        -Description 'pre-test uninstall' `
        -WorkingDirectory $workingDirectory
    if (Test-ApplicationDetected -App $Application) {
        throw "$($Application.id): pre-test uninstall completed but detection still reports the app installed."
    }
}

$installCommandCompleted = $false
try {
    Invoke-CatalogCommand `
        -Command $Application.package.installCommand `
        -Description 'install' `
        -WorkingDirectory $workingDirectory
    $installCommandCompleted = $true
    if (-not (Test-ApplicationDetected -App $Application)) {
        Invoke-CatalogCommand `
            -Command $Application.package.uninstallCommand `
            -Description 'cleanup after undetected install' `
            -WorkingDirectory $workingDirectory
        $installCommandCompleted = $false
        throw "$($Application.id): install completed but the catalog detection rule did not match."
    }
    Write-Host "$($Application.id): catalog detection confirmed the installation."

    Invoke-CatalogCommand `
        -Command $Application.package.uninstallCommand `
        -Description 'uninstall' `
        -WorkingDirectory $workingDirectory
    $installCommandCompleted = $false
    if (Test-ApplicationDetected -App $Application) {
        throw "$($Application.id): uninstall completed but the catalog detection rule still matches."
    }
    Write-Host "$($Application.id): catalog detection confirmed removal."
}
finally {
    if ($installCommandCompleted) {
        Invoke-CatalogCommand `
            -Command $Application.package.uninstallCommand `
            -Description 'cleanup uninstall' `
            -WorkingDirectory $workingDirectory
        $installCommandCompleted = $false
        if (Test-ApplicationDetected -App $Application) {
            throw "$($Application.id): cleanup uninstall completed but the app is still detected."
        }
    }
}
