$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $env:USERPROFILE ".claude\hooks\handle-click.ps1"
if (-not (Test-Path $scriptPath)) {
    Write-Error "Handler script not found: $scriptPath"
    exit 1
}
$fullScriptPath = (Resolve-Path $scriptPath).ProviderPath

$sourcePath = Join-Path $PSScriptRoot 'AgentRecall.cs'
$launcherPath = Join-Path $PSScriptRoot 'AgentRecall.exe'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The Windows .NET Framework compiler is unavailable.' }
$temporaryExe = Join-Path $PSScriptRoot ('AgentRecall-' + [guid]::NewGuid().ToString('N') + '.exe')
try {
    & $compiler /nologo /target:winexe /optimize+ "/out:$temporaryExe" $sourcePath
    if ($LASTEXITCODE -ne 0) { throw 'Session protocol launcher did not compile.' }
    Move-Item -LiteralPath $temporaryExe -Destination $launcherPath -Force
} finally { if (Test-Path -LiteralPath $temporaryExe) { Remove-Item -LiteralPath $temporaryExe } }
$cmd = "`"$launcherPath`" `"%1`""

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
