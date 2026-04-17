param([string]$Uri)

$ErrorActionPreference = "SilentlyContinue"
$logPath = Join-Path $env:USERPROFILE ".claude\hooks\click-handler.log"

function Log {
    param([string]$Msg)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    Add-Content -LiteralPath $logPath -Value "[$ts] $Msg"
}

Log "--- click received: uri=`"$Uri`" ---"

if (-not $Uri) { Log "no URI arg, exit"; exit 0 }

# Parse: clauderecall://<session_id> -> <session_id>
$trimmed = $Uri -replace '^clauderecall://', '' -replace '/$', ''
$sessionId = [System.Uri]::UnescapeDataString($trimmed)
if (-not $sessionId) { Log "could not extract session_id from URI"; exit 0 }
Log "session_id=$sessionId"

# Opportunistic stale cleanup: remove session files > 7 days old
$dir = Join-Path $env:USERPROFILE ".claude\session-windows"
if (Test-Path $dir) {
    Get-ChildItem -LiteralPath $dir -Filter "*.json" -ErrorAction SilentlyContinue | Where-Object {
        $_.LastWriteTime -lt (Get-Date).AddDays(-7)
    } | ForEach-Object {
        Log "cleanup: removing stale $($_.Name)"
        Remove-Item -LiteralPath $_.FullName -ErrorAction SilentlyContinue
    }
}

# Load session file
$file = Join-Path $dir "$sessionId.json"
if (-not (Test-Path $file)) { Log "session file missing: $file"; exit 0 }

$data = $null
try { $data = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json } catch { Log "session file parse failed"; exit 0 }
if (-not $data) { Log "session file empty"; exit 0 }

$hwndInt = [int64]$data.hwnd
$hwnd = [IntPtr]$hwndInt
$expectedPid = [int]$data.pid
Log ("loaded: hwnd=0x{0:X}, expected_pid={1}" -f $hwndInt, $expectedPid)

Add-Type -Namespace W -Name C -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool IsWindow(IntPtr hWnd);
[DllImport("user32.dll")]
public static extern void SwitchToThisWindow(IntPtr hWnd, bool fAltTab);
[DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
[DllImport("kernel32.dll")]
public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);
[DllImport("kernel32.dll")]
public static extern bool CloseHandle(IntPtr hObject);
[DllImport("kernel32.dll")]
public static extern bool QueryFullProcessImageName(IntPtr hProcess, uint dwFlags, System.Text.StringBuilder lpExeName, ref uint lpdwSize);
'@

# Check 1: HWND still valid
if (-not [W.C]::IsWindow($hwnd)) { Log "IsWindow=false, HWND is stale"; exit 0 }

# Check 2: HWND's owning PID matches
$actualPid = 0
[void][W.C]::GetWindowThreadProcessId($hwnd, [ref]$actualPid)
if ($actualPid -ne $expectedPid) { Log "PID mismatch: expected=$expectedPid actual=$actualPid (PID reuse)"; exit 0 }

# Check 3: Process name is mintty.exe
$h = [W.C]::OpenProcess(0x1000, $false, [uint32]$actualPid)
if ($h -eq [IntPtr]::Zero) { Log "OpenProcess failed for PID $actualPid"; exit 0 }
$sb = New-Object System.Text.StringBuilder 1024
$sz = [uint32]$sb.Capacity
$ok = [W.C]::QueryFullProcessImageName($h, 0, $sb, [ref]$sz)
[void][W.C]::CloseHandle($h)
if (-not $ok) { Log "QueryFullProcessImageName failed"; exit 0 }
$name = Split-Path -Leaf $sb.ToString()
if ($name -ne 'mintty.exe') { Log "process name mismatch: got '$name'"; exit 0 }

# All checks passed
Log ("switching to HWND 0x{0:X}" -f $hwndInt)
[W.C]::SwitchToThisWindow($hwnd, $true)
Log "switch completed"
