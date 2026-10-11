param([string]$Uri, [switch]$ResolveOnly)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'agent-sessions.ps1')
$logPath = Join-Path $PSScriptRoot 'click-handler.log'
function Write-ClickLog([string]$Message) { Add-Content -LiteralPath $logPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] $Message" }
try {
    Write-ClickLog "click received: $Uri"
    $target = ConvertFrom-AgentRecallUri -Uri $Uri
    if (-not $target) { throw 'This notification has an invalid session address.' }
    $sessions = @(Get-AgentSessions)
    $session = $sessions | Where-Object { $_.Provider -eq $target.Provider -and $_.SessionId -eq $target.SessionId } | Select-Object -First 1
    if (-not $session) { throw 'This session window has closed. Press Alt + backtick to see your current sessions.' }
    Write-ClickLog "resolved $($session.Provider) $($session.SessionId) hwnd=$($session.Hwnd) pid=$($session.Pid) name=$($session.Name)"
    if ($ResolveOnly) { $session; return }
    if (Test-AgentPopupService) {
        $ready=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'agent-monitor-ready.json') -Raw | ConvertFrom-Json
        $granted=[AgentWindows]::AllowSetForegroundWindow([uint32]$ready.Pid)
        Write-ClickLog "resident foreground permission=$granted pid=$($ready.Pid)"
        $preview='Click this card to switch to the session.'
        if($session.Provider -eq 'Codex' -and $session.TranscriptPath) {
            $preview=(Get-CodexFileState -Path $session.TranscriptPath).Snippet
        }
        Write-AgentPopupRequest -Provider $session.Provider -SessionId $session.SessionId -Name $session.Name -Snippet $preview -Silent -AutoFocus
        Write-ClickLog "saved notification reopened popup sid=$($session.SessionId)"
        return
    }
    $focused=[AgentWindows]::FocusFromNotification([int64]$session.Hwnd, [int]$session.Pid)
    Write-ClickLog "native focus trace: $([AgentWindows]::LastFocusTrace)"
    if (-not $focused) { throw 'Windows prevented switching to this window. Press Alt + backtick and select the session.' }
    Write-ClickLog "focus verified hwnd=$($session.Hwnd)"
    # A successful immediate API result may be undone when the notification
    # finishes dismissing. Observe without stealing focus back from the user.
    $elapsed = 0
    $retained = $true
    foreach ($delay in @(100,250,650,1000)) {
        Start-Sleep -Milliseconds $delay
        $elapsed += $delay
        $front = [AgentWindows]::GetForegroundWindow().ToInt64()
        if ($front -ne $session.Hwnd) { $retained = $false }
        $frontWindow = [AgentWindows]::List() | Where-Object { $_.Hwnd -eq $front } | Select-Object -First 1
        Write-ClickLog "focus observation elapsedMs=$elapsed target=$($session.Hwnd) foreground=$front pid=$($frontWindow.Pid) title=$($frontWindow.Title)"
    }
    if ($retained) { Write-ClickLog "focus retained hwnd=$($session.Hwnd) durationMs=$elapsed" }
    else { Write-ClickLog "focus changed after activation hwnd=$($session.Hwnd)" }
    if ($session.Provider -eq 'Claude') {
        $statusFile = Join-Path $env:USERPROFILE ".claude\session-windows\$($session.SessionId).status"
        if ((Test-Path -LiteralPath $statusFile) -and (Get-Content -LiteralPath $statusFile -Raw).Trim() -eq 'done') { Set-Content -LiteralPath $statusFile -Value 'idle' -Encoding ASCII }
    }
} catch {
    Write-ClickLog "failed: $($_.Exception.Message)"
    if ($ResolveOnly) { throw }
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Agent Sessions') | Out-Null
}
