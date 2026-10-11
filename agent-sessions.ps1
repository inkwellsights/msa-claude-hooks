# Shared discovery, sound settings, notification content and safe window activation.
$script:agentSettingsPath = Join-Path $env:USERPROFILE '.claude\hooks\agent-settings.json'
$script:agentMonitorReadyPath = Join-Path $env:USERPROFILE '.claude\hooks\agent-monitor-ready.json'
function Get-AgentSettings {
    param([string]$Path = $script:agentSettingsPath)
    try { $s = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json; if ($s.SoundEnabled -is [bool]) { return $s } } catch { }
    return [pscustomobject]@{ SoundEnabled = $true }
}
function Set-AgentSound {
    param([bool]$Enabled, [string]$Path = $script:agentSettingsPath)
    $tmp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        @{ SoundEnabled = $Enabled } | ConvertTo-Json | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp } }
}
function Resolve-CodexMetadata {
    param([string]$CommandLine, [datetime]$Started, [object[]]$Metadata)
    if ($CommandLine -match '(?i)\bresume\b.*?([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})') {
        $id = $matches[1]
        return $Metadata | Where-Object { $_.Id -eq $id } | Select-Object -First 1
    }
    $candidates = @($Metadata | Where-Object { $_.Source -eq 'cli' -and ($_.Started.ToUniversalTime() - $Started.ToUniversalTime()).TotalSeconds -ge -2 -and ($_.Started.ToUniversalTime() - $Started.ToUniversalTime()).TotalSeconds -le 30 })
    if ($candidates.Count -eq 1) { return $candidates[0] }
    return $null
}
function Resolve-ClaudeAgentForMapping {
    param($Mapping, [object[]]$Processes)
    $byPid=@{}; foreach ($p in $Processes) { $byPid[[int]$p.ProcessId]=$p }
    try { $captured = [datetime]$Mapping.captured_at } catch { return $null }
    if (-not $Mapping.captured_at) { return $null }
    foreach ($p in ($Processes | Sort-Object CreationDate -Descending)) {
        if ($p.Name -ne 'claude.exe' -and -not ($p.Name -eq 'node.exe' -and $p.CommandLine -match '(?i)(claude-code|[\\/]claude[\\/]|[\\/]claude(?:\.js)?(?:\s|$))')) { continue }
        if ($captured.ToUniversalTime() -lt $p.CreationDate.ToUniversalTime().AddSeconds(-2)) { continue }
        $cur=$p
        for ($i=0; $i -lt 25 -and $cur; $i++) {
            if ([int]$cur.ProcessId -eq [int]$Mapping.pid) { return $p }
            $cur=$byPid[[int]$cur.ParentProcessId]
        }
    }
    return $null
}
function ConvertFrom-AgentRecallUri {
    param([string]$Uri)
    $idPattern = '[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}'
    if ($Uri -match "(?i)^clauderecall://(codex|claude)/($idPattern)/?$") { return [pscustomobject]@{ Provider = (Get-Culture).TextInfo.ToTitleCase($matches[1].ToLower()); SessionId = $matches[2] } }
    if ($Uri -match "(?i)^clauderecall://($idPattern)/?$") { return [pscustomobject]@{ Provider = 'Claude'; SessionId = $matches[1] } }
    return $null
}
function Get-CodexHookTarget {
    param($Data, [object[]]$Sessions)
    $id = $Data.session_id
    if (-not $id) { $id = $Data.thread_id }
    if (-not $id) { $id = $Data.'thread-id' }
    if (-not $id) { return $null }
    return $Sessions | Where-Object { $_.Provider -eq 'Codex' -and $_.SessionId -eq $id } | Select-Object -First 1
}
function Test-AgentMonitorOwnsSession {
    param($Ready, [object[]]$Daemons, [string]$SessionId)
    if (-not $Ready -or -not $SessionId -or $SessionId -notin @($Ready.SessionIds)) { return $false }
    return @($Daemons | Where-Object { [int]$_.ProcessId -eq [int]$Ready.Pid }).Count -eq 1
}
function Get-CodexTurnState {
    param([string[]]$Lines)
    $status = 'idle'; $eventKey = ''; $snippet = ''; $hasLifecycle = $false
    foreach ($line in $Lines) {
        try {
            $e = $line | ConvertFrom-Json -ErrorAction Stop
            if ($e.type -ne 'event_msg') { continue }
            if ($e.payload.type -eq 'task_started') { $status = 'running'; $eventKey = ''; $hasLifecycle = $true }
            elseif ($e.payload.type -eq 'task_complete') { $status = 'done'; $eventKey = "$($e.timestamp)|$($e.payload.turn_id)"; $hasLifecycle = $true; if ($e.payload.last_agent_message) { $snippet=$e.payload.last_agent_message } }
            elseif ($e.payload.type -eq 'turn_aborted') { $status = 'idle'; $eventKey = ''; $hasLifecycle = $true }
            elseif ($e.payload.type -eq 'user_message') { $snippet = $e.payload.message }
        } catch { }
    }
    return [pscustomobject]@{ Status = $status; EventKey = $eventKey; Snippet = $snippet; HasLifecycle = $hasLifecycle }
}
function Get-CodexFileState {
    param([string]$Path)
    $length = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
    $bytes = 131072
    do {
        $state = Get-CodexTurnState -Lines (Read-AgentTail -Path $Path -Bytes $bytes)
        if ($state.HasLifecycle -or $bytes -ge $length) { return $state }
        $bytes = [int][Math]::Min([int]::MaxValue, $bytes * 2L)
    } while ($true)
}
function Read-AgentTail {
    param([string]$Path, [int]$Bytes = 131072)
    if (-not $Path) { return @() }
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $offset = [Math]::Max(0, $stream.Length - $Bytes)
        [void]$stream.Seek($offset, [IO.SeekOrigin]::Begin)
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd(); $reader.Dispose(); $stream = $null
        $lines = @($text -split '\r?\n')
        if ($offset -gt 0 -and $lines.Count -gt 1) { $lines = $lines[1..($lines.Count-1)] }
        return $lines
    } catch { return @() } finally { if ($stream) { $stream.Dispose() } }
}
function Initialize-AgentNative {
    if ('AgentWindows' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;
public class AgentWindow { public long Hwnd; public int Pid; public string Title; }
public static class AgentWindows {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", SetLastError=true)] public static extern bool AllowSetForegroundWindow(uint pid);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr h, int command);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern void SwitchToThisWindow(IntPtr h, bool altTab);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll", SetLastError=true)] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    public static AgentWindow[] List() {
        var result = new List<AgentWindow>();
        EnumWindows(delegate(IntPtr h, IntPtr p) {
            if (IsWindowVisible(h)) { uint pid; GetWindowThreadProcessId(h, out pid); var t = new StringBuilder(1024); GetWindowText(h,t,t.Capacity); result.Add(new AgentWindow { Hwnd=h.ToInt64(), Pid=(int)pid, Title=t.ToString() }); }
            return true;
        }, IntPtr.Zero);
        return result.ToArray();
    }
    public static bool Matches(long hwnd, int expectedPid) { uint pid; return IsWindow(new IntPtr(hwnd)) && GetWindowThreadProcessId(new IntPtr(hwnd),out pid)!=0 && pid==(uint)expectedPid; }
    public static string LastFocusTrace = "";
    public static bool FocusFromNotification(long hwnd, int expectedPid) {
        if (Focus(hwnd,expectedPid)) return true;
        if (!Matches(hwnd,expectedPid)) return false;
        // Notification Center's protected input queue rejects AttachThreadInput.
        // Use the Windows window-switch operation only for a validated user click.
        SwitchToThisWindow(new IntPtr(hwnd),false);
        System.Threading.Thread.Sleep(100);
        bool switched=GetForegroundWindow()==new IntPtr(hwnd);
        // Some Notification Center activations need the window-switch mode.
        if (!switched && Matches(hwnd,expectedPid)) {
            SwitchToThisWindow(new IntPtr(hwnd),true);
            System.Threading.Thread.Sleep(100);
            switched=GetForegroundWindow()==new IntPtr(hwnd);
            LastFocusTrace += " windowSwitchMode="+switched;
        }
        LastFocusTrace += " notificationSwitch="+switched+" foreground="+GetForegroundWindow().ToInt64();
        return switched;
    }
    public static bool Focus(long hwnd, int expectedPid) {
        LastFocusTrace = "before=" + GetForegroundWindow().ToInt64();
        if (!Matches(hwnd, expectedPid)) return false;
        var h = new IntPtr(hwnd);
        if (IsIconic(h)) ShowWindowAsync(h,9);
        bool initial=SetForegroundWindow(h);
        LastFocusTrace += " initial=" + initial;
        if (GetForegroundWindow()==h) return true;
        uint ignored; uint current=GetCurrentThreadId(); uint front=GetWindowThreadProcessId(GetForegroundWindow(),out ignored); uint target=GetWindowThreadProcessId(h,out ignored);
        bool a=false,b=false;
        try {
            if (front!=0 && front!=current) { a=AttachThreadInput(current,front,true); LastFocusTrace += " attachFront="+a+" error="+Marshal.GetLastWin32Error(); }
            if (target!=0 && target!=current && target!=front) { b=AttachThreadInput(current,target,true); LastFocusTrace += " attachTarget="+b+" error="+Marshal.GetLastWin32Error(); }
            BringWindowToTop(h); SetForegroundWindow(h);
        } finally { if (b) AttachThreadInput(current,target,false); if(a) AttachThreadInput(current,front,false); }
        LastFocusTrace += " currentThread="+current+" frontThread="+front+" targetThread="+target+" after="+GetForegroundWindow().ToInt64();
        return GetForegroundWindow()==h;
    }
}
'@
}
$script:agentMetaCache = @{}
function Get-CodexMetadata {
    $root = Join-Path $env:USERPROFILE '.codex\sessions'
    foreach ($file in (Get-ChildItem -LiteralPath $root -Filter '*.jsonl' -Recurse -ErrorAction SilentlyContinue)) {
        if (-not $script:agentMetaCache.ContainsKey($file.FullName)) {
            try {
                $m = (Get-Content -LiteralPath $file.FullName -TotalCount 1 -ErrorAction Stop | ConvertFrom-Json).payload
                if ($m.id) { $script:agentMetaCache[$file.FullName] = [pscustomobject]@{ Id=$m.id; Started=[datetime]$m.timestamp; Cwd=$m.cwd; Source=$m.source; Path=$file.FullName } }
            } catch { }
        }
    }
    return @($script:agentMetaCache.Values)
}
function Get-AgentSessions {
    Initialize-AgentNative
    $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    $byPid = @{}; foreach ($p in $processes) { $byPid[[int]$p.ProcessId] = $p }
    $windows = @([AgentWindows]::List()); $metadata = @(Get-CodexMetadata)
    $result = @()
    foreach ($p in $processes) {
        if ($p.Name -ne 'codex.exe' -or $p.CommandLine -match '\b(app-server|exec|mcp-server)\b') { continue }
        $cur = $p; $w = $null
        for ($i=0; $i -lt 25 -and $cur; $i++) {
            if ($cur.Name -like 'alacritty*' -or $cur.Name -eq 'mintty.exe') { $w = $windows | Where-Object { $_.Pid -eq $cur.ProcessId } | Select-Object -First 1; break }
            $cur = $byPid[[int]$cur.ParentProcessId]
        }
        if (-not $w) { continue }
        $m = Resolve-CodexMetadata -CommandLine $p.CommandLine -Started $p.CreationDate -Metadata $metadata
        $name = $w.Title -replace '^Administrator:\s*',''
        $sid = if ($m) { $m.Id } else { "window-$($p.ProcessId)" }
        $result += [pscustomobject]@{ Provider='Codex'; SessionId=$sid; Hwnd=$w.Hwnd; Pid=$w.Pid; AgentPid=[int]$p.ProcessId; AgentStarted=$p.CreationDate; TranscriptPath=$m.Path; Cwd=$m.Cwd; Name=$name; Secondary=''; Snippet=''; Status='idle'; Live=$true; File='' }
    }
    $dir = Join-Path $env:USERPROFILE '.claude\session-windows'
    foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter '*.json' -ErrorAction SilentlyContinue)) {
        try {
            $d = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            $w = $windows | Where-Object { $_.Hwnd -eq $d.hwnd -and $_.Pid -eq $d.pid } | Select-Object -First 1
            if (-not $w -or -not $byPid.ContainsKey([int]$d.pid)) { continue }
            $hostName = $byPid[[int]$d.pid].Name
            if ($hostName -notlike 'alacritty*' -and $hostName -ne 'mintty.exe') { continue }
            $agent = Resolve-ClaudeAgentForMapping -Mapping $d -Processes $processes
            if (-not $agent) { continue }
            $status='idle'; $sf=Join-Path $dir "$($d.session_id).status"
            if (Test-Path -LiteralPath $sf) { $status=(Get-Content -LiteralPath $sf -Raw).Trim() }
            $result += [pscustomobject]@{ Provider='Claude'; SessionId=$d.session_id; Hwnd=$w.Hwnd; Pid=$w.Pid; AgentPid=[int]$agent.ProcessId; AgentStarted=$agent.CreationDate; TranscriptPath=$d.transcript_path; Cwd=$d.cwd; Name=$w.Title; Secondary=''; Snippet=''; Status=$status; Live=$true; File=$file.FullName }
        } catch { }
    }
    return @($result | Sort-Object Provider,Name)
}
function New-AgentToastContent {
    param([string]$Provider, [string]$SessionId, [string]$Title, [string]$Body, [string]$ButtonText='Switch to session')
    Import-Module BurntToast -ErrorAction Stop
    $uri = "clauderecall://$($Provider.ToLower())/$SessionId"
    $t1 = New-BTText -Text $Title; $t2 = New-BTText -Text $Body
    $binding = New-BTBinding -Children $t1,$t2
    $visual = New-BTVisual -BindingGeneric $binding
    $button = New-BTButton -Content $ButtonText -Arguments $uri -ActivationType Protocol
    $actions = New-BTAction -Buttons $button
    New-BTContent -Visual $visual -Actions $actions -Audio (New-BTAudio -Silent) -Launch $uri -ActivationType Protocol
}
function Save-AgentNotificationHistory {
    param([string]$Provider,[string]$SessionId,[string]$Name,[string]$Snippet='')
    try {
        $view=Get-AgentPopupView ([pscustomobject]@{Provider=$Provider;Name=$Name;Snippet=$Snippet})
        if (Test-AgentNativeNotificationService) {
            Write-AgentNativeHistoryRequest -Provider $Provider -SessionId $SessionId -Name $view.Name -Snippet $view.Preview
            return
        }
        $content=New-AgentToastContent -Provider $Provider -SessionId $SessionId -Title $view.Title -Body "$($view.Name)`n$($view.Preview)" -ButtonText 'Open session popup'
        Submit-BTNotification -Content $content -UniqueIdentifier "$Provider-$SessionId" -SuppressPopup -ErrorAction Stop
    } catch { Add-Content -LiteralPath (Join-Path $PSScriptRoot 'notification-errors.log') -Value "$(Get-Date -Format o) History: $_" }
}
function Test-AgentNativeNotificationService {
    try {
        $ready=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'native-toast-ready.json') -Raw -ErrorAction Stop | ConvertFrom-Json
        $process=Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$ready.Pid)" -ErrorAction Stop
        return [bool]($process -and $process.ExecutablePath -eq (Join-Path $PSScriptRoot 'AgentNotifications.exe'))
    } catch {return $false}
}
function Write-AgentNativeSessionSnapshot {
    param($Sessions,[string]$Path=(Join-Path $PSScriptRoot 'native-session-targets.json'))
    $targets=@($Sessions | Select-Object Provider,SessionId,Hwnd,Pid,AgentPid,@{n='AgentStarted';e={$_.AgentStarted.ToUniversalTime().ToString('o')}})
    @{CreatedUtc=[datetime]::UtcNow.ToString('o');Sessions=$targets} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath ($Path+'.tmp') -Encoding UTF8
    Move-Item -LiteralPath ($Path+'.tmp') -Destination $Path -Force
}
function Write-AgentNativeHistoryRequest {
    param([string]$Provider,[string]$SessionId,[string]$Name,[string]$Snippet='',[string]$Directory=(Join-Path $PSScriptRoot 'native-toast-queue'))
    if(-not(ConvertFrom-AgentRecallUri "clauderecall://$Provider/$SessionId")){throw 'Invalid native session address'}
    if(-not(Test-Path -LiteralPath $Directory)){New-Item -ItemType Directory -Path $Directory -Force | Out-Null}
    $view=Get-AgentPopupView ([pscustomobject]@{Provider=$Provider;Name=$Name;Snippet=$Snippet})
    $path=Join-Path $Directory ([guid]::NewGuid().ToString('N')+'.json')
    try {
        @{Provider=$Provider;SessionId=$SessionId;Name=$view.Name;Snippet=$view.Preview;CreatedUtc=[datetime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath ($path+'.tmp') -Encoding UTF8
        Move-Item -LiteralPath ($path+'.tmp') -Destination $path
    } finally {if(Test-Path -LiteralPath ($path+'.tmp')){Remove-Item -LiteralPath ($path+'.tmp')}}
}
function Send-AgentNotification {
    param([string]$Provider, [string]$SessionId, [string]$Name, [string]$Snippet = '')
    if (Test-AgentPopupService) {
        Write-AgentPopupRequest -Provider $Provider -SessionId $SessionId -Name $Name -Snippet $Snippet
        Save-AgentNotificationHistory -Provider $Provider -SessionId $SessionId -Name $Name -Snippet $Snippet
        return
    }
    if ((Get-AgentSettings).SoundEnabled) { try { [Console]::Beep(800,200) } catch { } }
    $title = if ($Snippet) { ($Snippet -replace '\s+',' ').Trim() } else { "$Provider finished" }
    if ($title.Length -gt 100) { $title = $title.Substring(0,97) + '...' }
    try {
        $content = New-AgentToastContent -Provider $Provider -SessionId $SessionId -Title $title -Body "$Name - done"
        Submit-BTNotification -Content $content -UniqueIdentifier "$Provider-$SessionId" -ErrorAction Stop
    } catch { Add-Content -LiteralPath (Join-Path $PSScriptRoot 'notification-errors.log') -Value "$(Get-Date -Format o) $_" }
}
function Test-AgentPopupService {
    try {
        $ready=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'agent-monitor-ready.json') -Raw -ErrorAction Stop | ConvertFrom-Json
        if (-not $ready.PopupReady) { return $false }
        $process=Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$ready.Pid)" -ErrorAction Stop
        $daemon=Join-Path $PSScriptRoot 'session-picker-daemon.ps1'
        return [bool]($process -and $process.CommandLine -match ([regex]::Escape($daemon)))
    } catch { return $false }
}
. (Join-Path $PSScriptRoot 'completion-popups.ps1')
