param([Parameter(Mandatory=$true)][string]$Uri)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Run this integration check with Windows PowerShell 5.1.' }
$hooks = Split-Path $PSScriptRoot -Parent
. (Join-Path $hooks 'agent-sessions.ps1')
$address = ConvertFrom-AgentRecallUri $Uri
if (-not $address) { throw 'Invalid session URI.' }
$session = Get-AgentSessions | Where-Object { $_.Provider -eq $address.Provider -and $_.SessionId -eq $address.SessionId } | Select-Object -First 1
if (-not $session) { throw 'The requested session is not live.' }
$log = Join-Path $hooks 'click-handler.log'
$offset = if (Test-Path $log) { (Get-Item $log).Length } else { 0 }
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.System.Launcher,Windows.System,ContentType=WindowsRuntime]
$operation = [Windows.System.Launcher]::LaunchUriAsync([uri]$Uri)
$method = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
} | Select-Object -First 1
$task = $method.MakeGenericMethod([bool]).Invoke($null,@($operation))
if (-not $task.Wait(10000) -or -not $task.Result) { throw 'Windows notification URI activation rejected the registered handler.' }
$deadline = [datetime]::UtcNow.AddSeconds(15)
do {
    Start-Sleep -Milliseconds 200
    $newLog = ''
    if (Test-Path $log) {
        $stream = [IO.File]::Open($log,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        try {
            $null = $stream.Seek($offset,[IO.SeekOrigin]::Begin)
            $reader = New-Object IO.StreamReader($stream)
            $newLog = $reader.ReadToEnd()
        } finally { $stream.Dispose() }
    }
    if ($newLog.Contains("focus retained hwnd=$($session.Hwnd)")) { break }
    if ($newLog.Contains('failed:')) { throw $newLog }
} while ([datetime]::UtcNow -lt $deadline)
if (-not $newLog.Contains("click received: $Uri") -or -not $newLog.Contains("focus retained hwnd=$($session.Hwnd)")) { throw 'Handler did not receive this session and retain focus for two seconds before the timeout.' }
Initialize-AgentNative
if ([AgentWindows]::GetForegroundWindow().ToInt64() -ne $session.Hwnd) { throw 'Target window did not retain focus.' }
Write-Output "PASS Windows URI activation, handler delivery, exact session resolution and foreground focus: $($session.SessionId)"
Write-Output 'Actual notification body and button clicks still require an interactive check.'
