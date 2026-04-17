$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $env:USERPROFILE ".claude\hooks\handle-click.ps1"
if (-not (Test-Path $scriptPath)) {
    Write-Error "Handler script not found: $scriptPath"
    exit 1
}
$fullScriptPath = (Resolve-Path $scriptPath).ProviderPath

$cmd = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$fullScriptPath`" `"%1`""

$basePath = "HKCU:\Software\Classes\clauderecall"

New-Item -Path $basePath -Force | Out-Null
Set-ItemProperty -Path $basePath -Name "(default)" -Value "URL:Claude Recall Protocol"
Set-ItemProperty -Path $basePath -Name "URL Protocol" -Value ""

New-Item -Path "$basePath\shell" -Force | Out-Null
New-Item -Path "$basePath\shell\open" -Force | Out-Null
New-Item -Path "$basePath\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path "$basePath\shell\open\command" -Name "(default)" -Value $cmd

Write-Host "Registered clauderecall:// protocol" -ForegroundColor Green
Write-Host "Handler command:"
Write-Host "  $cmd"
