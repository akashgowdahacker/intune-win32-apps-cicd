[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallerPath,
    [Parameter(Mandatory)][ValidateSet('msi','exe')][string]$InstallerType
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
    throw "Installer was not found: $InstallerPath"
}

if ($InstallerType -eq 'msi') {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.OpenDatabase((Resolve-Path -LiteralPath $InstallerPath).Path, 0)
    $query = "SELECT `Value` FROM Property WHERE `Property`='ProductCode'"
    $view = $database.OpenView($query)
    $view.Execute()
    $record = $view.Fetch()
    $productCode = if ($record) { $record.StringData(1) } else { $null }
    $view.Close()

    $query = "SELECT `Value` FROM Property WHERE `Property`='ProductVersion'"
    $view = $database.OpenView($query)
    $view.Execute()
    $record = $view.Fetch()
    $version = if ($record) { $record.StringData(1) } else { $null }
    $view.Close()
    [pscustomobject]@{
        version = $version
        productCode = $productCode
        installCommand = "msiexec /i $([IO.Path]::GetFileName($InstallerPath)) /qn /norestart"
        uninstallCommand = if ($productCode) { "msiexec /x $productCode /qn /norestart" } else { $null }
        detectionRule = [pscustomobject]@{ type = 'msi'; productCode = $productCode }
    }
    exit 0
}

$file = Get-Item -LiteralPath $InstallerPath
$version = $file.VersionInfo.ProductVersion
if ([string]::IsNullOrWhiteSpace($version)) {
    throw "The EXE has no ProductVersion resource. Add install/uninstall commands and an explicit detection rule to the catalog."
}
[pscustomobject]@{
    version = $version
    productCode = $null
    installCommand = $null
    uninstallCommand = $null
    detectionRule = [pscustomobject]@{ type = 'file'; path = $null; fileOrFolderName = $null; detectionMethod = 'exists' }
}

