$ErrorActionPreference = 'Stop'

$registryPath = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\MSIP'
New-Item -Path $registryPath -Force | Out-Null
New-ItemProperty `
    -Path $registryPath `
    -Name 'AllowMajorVersionUpgrade' `
    -PropertyType DWord `
    -Value 1 `
    -Force | Out-Null

$installerPath = Join-Path $PSScriptRoot 'PurviewInfoProtection.msi'
$logPath = Join-Path $env:TEMP "PurviewInfoProtection-$([guid]::NewGuid().ToString('N')).log"
$process = Start-Process `
    -FilePath "$env:SystemRoot\System32\msiexec.exe" `
    -ArgumentList "/i `"$installerPath`" /qn /norestart /l*v `"$logPath`"" `
    -Wait `
    -PassThru

if ($process.ExitCode -notin @(0, 3010)) {
    if (Test-Path -LiteralPath $logPath) {
        Get-Content -LiteralPath $logPath -Tail 40 | ForEach-Object { Write-Host $_ }
    }
    exit $process.ExitCode
}

if (Test-Path -LiteralPath $logPath) {
    Remove-Item -LiteralPath $logPath -Force
}
exit $process.ExitCode
