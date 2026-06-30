$ErrorActionPreference = "SilentlyContinue"

# Read stdin for session metadata
$raw = [Console]::In.ReadToEnd()
$data = $null
try { $data = $raw | ConvertFrom-Json } catch { exit 1 }

$sessionId = $data.session_id
$cwd = $data.cwd
$transcriptPath = $data.transcript_path
if (-not $sessionId) { exit 1 }

Add-Type -Namespace W -Name N -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);
[DllImport("kernel32.dll")]
public static extern bool CloseHandle(IntPtr hObject);
[DllImport("kernel32.dll")]
public static extern bool QueryFullProcessImageName(IntPtr hProcess, uint dwFlags, System.Text.StringBuilder lpExeName, ref uint lpdwSize);
[DllImport("ntdll.dll")]
public static extern int NtQueryInformationProcess(IntPtr ProcessHandle, int ProcessInformationClass, ref PBI pbi, int pilen, out int rl);
[StructLayout(LayoutKind.Sequential)]
public struct PBI {
    public IntPtr ExitStatus;
    public IntPtr PebBaseAddress;
    public IntPtr AffinityMask;
    public IntPtr BasePriority;
    public IntPtr UniqueProcessId;
    public IntPtr InheritedFromUniqueProcessId;
}
[DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
[DllImport("user32.dll")]
public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
[DllImport("user32.dll")]
public static extern bool IsWindowVisible(IntPtr hWnd);
public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
'@

function Get-ProcName {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $null }
    $h = [W.N]::OpenProcess(0x1000, $false, [uint32]$ProcessId)
    if ($h -eq [IntPtr]::Zero) {
        try { return (Get-Process -Id $ProcessId -ErrorAction Stop).Name + ".exe" } catch { return $null }
    }
    $sb = New-Object System.Text.StringBuilder 1024
    $sz = [uint32]$sb.Capacity
    $ok = [W.N]::QueryFullProcessImageName($h, 0, $sb, [ref]$sz)
    [void][W.N]::CloseHandle($h)
    if (-not $ok) { return $null }
    return (Split-Path -Leaf $sb.ToString())
}

function Get-ParentPid {
    param([int]$ProcessId)
    $h = [W.N]::OpenProcess(0x1000, $false, [uint32]$ProcessId)
    if ($h -eq [IntPtr]::Zero) { return 0 }
    $pbi = New-Object W.N+PBI
    $rl = 0
    $size = [System.Runtime.InteropServices.Marshal]::SizeOf([type][W.N+PBI])
    $status = [W.N]::NtQueryInformationProcess($h, 0, [ref]$pbi, $size, [ref]$rl)
    [void][W.N]::CloseHandle($h)
    if ($status -ne 0) { return 0 }
    return [int]$pbi.InheritedFromUniqueProcessId
}

# Terminal hosts that present exactly ONE OS window per Claude session, so the
# picker can switch to a specific session. mintty.exe = Git Bash. Alacritty is
# matched by prefix because the portable build is named with its version baked in
# (e.g. "Alacritty-v0.17.0-portable.exe"), which changes on every update.
# To support another one-window-per-process terminal, add a pattern here AND in
# session-picker-daemon.ps1's Test-SessionLive.
$terminalHostPatterns = @('mintty.exe', 'alacritty*')
function Test-IsTerminalHost {
    param([string]$Name)
    if (-not $Name) { return $false }
    foreach ($p in $terminalHostPatterns) { if ($Name -like $p) { return $true } }
    return $false
}

# Walk ancestors to find the terminal host window process
$cur = [int]$PID
$hostPid = 0
for ($i = 0; $i -lt 20; $i++) {
    $name = Get-ProcName -ProcessId $cur
    if (Test-IsTerminalHost $name) { $hostPid = $cur; break }
    $cur = Get-ParentPid -ProcessId $cur
    if ($cur -le 0) { break }
}
if ($hostPid -eq 0) { exit 2 }

# Find visible top-level window for that PID
$script:targetPid = $hostPid
$script:found = [IntPtr]::Zero
$cb = [W.N+EnumWindowsProc] {
    param($hwnd, $lparam)
    if ($script:found -ne [IntPtr]::Zero) { return $true }
    $procId = 0
    [void][W.N]::GetWindowThreadProcessId($hwnd, [ref]$procId)
    if ($procId -eq $script:targetPid -and [W.N]::IsWindowVisible($hwnd)) {
        $script:found = $hwnd
    }
    return $true
}
[void][W.N]::EnumWindows($cb, [IntPtr]::Zero)
if ($script:found -eq [IntPtr]::Zero) { exit 3 }

# Write per-session mapping (one file per session = no lock contention)
$dir = Join-Path $env:USERPROFILE ".claude\session-windows"
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$file = Join-Path $dir "$sessionId.json"

$mapping = [ordered]@{
    session_id      = $sessionId
    hwnd            = [int64]$script:found
    pid             = $hostPid
    cwd             = $cwd
    transcript_path = $transcriptPath
    captured_at     = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffK')
}
$mapping | ConvertTo-Json | Set-Content -LiteralPath $file -Encoding UTF8

$statusFile = Join-Path $dir "$sessionId.status"
Set-Content -LiteralPath $statusFile -Value "idle" -Encoding ASCII -ErrorAction SilentlyContinue
