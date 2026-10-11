$ErrorActionPreference = 'Stop'
. (Join-Path $env:USERPROFILE '.claude\hooks\agent-sessions.ps1')
$raw = [Console]::In.ReadToEnd()
try { $data = $raw | ConvertFrom-Json -ErrorAction Stop } catch { exit 0 }
# The live picker service owns CLI completion alerts. Avoid a second, unclickable
# toast and a second beep from this older Stop hook.
$daemon = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match '-File\s+"?[^\r\n"]*session-picker-daemon\.ps1"?(?:\s|$)' })
$id=$data.session_id
if (-not $id) { $id=$data.thread_id }
if (-not $id) { $id=$data.'thread-id' }
$ready=$null
try { $ready=Get-Content -LiteralPath (Join-Path $env:USERPROFILE '.claude\hooks\agent-monitor-ready.json') -Raw -ErrorAction Stop | ConvertFrom-Json } catch { }
if (Test-AgentMonitorOwnsSession -Ready $ready -Daemons $daemon -SessionId $id) { exit 0 }
try {
    $session = Get-CodexHookTarget -Data $data -Sessions @(Get-AgentSessions)
    if ($session) { Send-AgentNotification -Provider Codex -SessionId $session.SessionId -Name $session.Name }
} catch { }
