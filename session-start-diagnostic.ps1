param(
    [int]$BashPid = -1,
    [int]$BashPpid = -1,
    [int]$BashWinPid = -1,
    [string]$BashPpidWinpid = "NONE"
)

$ErrorActionPreference = "Continue"

$logPath = Join-Path $env:USERPROFILE ".claude\hooks\session-start-diagnostic.log"

function Log-Line {
    param([string]$Line)
    $ts = Get-Date -Format "HH:mm:ss.fff"
    Add-Content -LiteralPath $logPath -Value "[$ts] $Line"
}

function Log-Raw {
    param([string]$Text)
    Add-Content -LiteralPath $logPath -Value $Text
}

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
public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
[DllImport("user32.dll", CharSet=CharSet.Auto)]
public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
[DllImport("user32.dll")]
public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
[DllImport("user32.dll")]
public static extern bool IsWindowVisible(IntPtr hWnd);
public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
'@

function Get-ProcName {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return "(PID $ProcessId)" }
    $h = [W.N]::OpenProcess(0x1000, $false, [uint32]$ProcessId)
    if ($h -eq [IntPtr]::Zero) {
        try {
            return ((Get-Process -Id $ProcessId -ErrorAction Stop).Name + ".exe [via Get-Process]")
        } catch {
            return "(OpenProcess+GetProcess both failed)"
        }
    }
    $sb = New-Object System.Text.StringBuilder 1024
    $sz = [uint32]$sb.Capacity
    $ok = [W.N]::QueryFullProcessImageName($h, 0, $sb, [ref]$sz)
    [void][W.N]::CloseHandle($h)
    if (-not $ok) { return "(QueryFullProcessImageName failed)" }
    return (Split-Path -Leaf $sb.ToString())
}

function Walk-Parents {
    param([int]$StartPid)
    $out = @()
    $cur = $StartPid
    $steps = 0
    while ($cur -gt 0 -and $steps -lt 20) {
        $name = Get-ProcName -ProcessId $cur
        $h = [W.N]::OpenProcess(0x1000, $false, [uint32]$cur)
        if ($h -eq [IntPtr]::Zero) {
            $out += "  [$steps] PID $cur - $name - (OpenProcess failed, cannot get parent)"
            break
        }
        $pbi = New-Object W.N+PBI
        $rl = 0
        $size = [System.Runtime.InteropServices.Marshal]::SizeOf([type][W.N+PBI])
        $status = [W.N]::NtQueryInformationProcess($h, 0, [ref]$pbi, $size, [ref]$rl)
        [void][W.N]::CloseHandle($h)
        if ($status -ne 0) {
            $out += "  [$steps] PID $cur - $name - (NtQIP failed, status=0x{0:X})" -f $status
            break
        }
        $parent = [int]$pbi.InheritedFromUniqueProcessId
        $out += "  [$steps] PID $cur - $name - parent=$parent"
        if ($parent -eq $cur -or $parent -le 0) { break }
        $cur = $parent
        $steps++
    }
    return $out
}

function Get-AllMintty {
    $script:hwnds = @()
    $cb = [W.N+EnumWindowsProc] {
        param($hwnd, $lparam)
        $procId = 0
        [void][W.N]::GetWindowThreadProcessId($hwnd, [ref]$procId)
        $name = Get-ProcName -ProcessId $procId
        if ($name -match "^mintty") {
            $sb = New-Object System.Text.StringBuilder 256
            [void][W.N]::GetWindowText($hwnd, $sb, 256)
            $vis = [W.N]::IsWindowVisible($hwnd)
            $script:hwnds += [PSCustomObject]@{
                HWND = $hwnd; PID = $procId; Name = $name; Title = $sb.ToString(); Visible = $vis
            }
        }
        return $true
    }
    [void][W.N]::EnumWindows($cb, [IntPtr]::Zero)
    return $script:hwnds
}

# ============================================================
Log-Raw ""
Log-Raw "================================================================"
Log-Line "=== SessionStart diagnostic: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') ==="
Log-Raw "================================================================"

# --- stdin JSON ---
Log-Line "--- stdin JSON ---"
$raw = [Console]::In.ReadToEnd()
Log-Raw $raw

# --- /proc info passed from bash ---
Log-Line "--- /proc info (from bash wrapper) ---"
Log-Raw "  bash msys PID (`$`$):         $BashPid"
Log-Raw "  bash msys PPID (/proc/`$`$/ppid): $BashPpid"
Log-Raw "  bash winpid (/proc/`$`$/winpid): $BashWinPid"
Log-Raw "  bash PPID winpid (/proc/ppid/winpid): $BashPpidWinpid"

# --- CLAUDE_* env vars ---
Log-Line "--- CLAUDE_* env vars ---"
$claudeEnv = Get-ChildItem Env: | Where-Object { $_.Name -like "CLAUDE_*" }
if ($claudeEnv.Count -eq 0) {
    Log-Raw "  (none)"
} else {
    $claudeEnv | ForEach-Object { Log-Raw ("  {0} = {1}" -f $_.Name, $_.Value) }
}

# --- PS identity ---
Log-Line "--- PS identity ---"
$psPid = [int]$PID
Log-Raw ("  PS PID: {0} ({1})" -f $psPid, (Get-ProcName -ProcessId $psPid))

# --- Strategy 2: NtQIP ancestor chain from PS ---
Log-Line "--- Strategy 2: NtQueryInformationProcess ancestor chain (from PS PID) ---"
Walk-Parents -StartPid $psPid | ForEach-Object { Log-Raw $_ }

# --- Also walk from bash winpid if we have it ---
if ($BashWinPid -gt 0) {
    Log-Line "--- Strategy 2b: NtQIP ancestor chain (from bash winpid $BashWinPid) ---"
    Walk-Parents -StartPid $BashWinPid | ForEach-Object { Log-Raw $_ }
}

# --- Strategy 3: GetForegroundWindow ---
Log-Line "--- Strategy 3: GetForegroundWindow ---"
$fgHwnd = [W.N]::GetForegroundWindow()
Log-Raw ("  HWND: 0x{0:X}" -f $fgHwnd.ToInt64())
if ($fgHwnd -ne [IntPtr]::Zero) {
    $fgPid = 0
    [void][W.N]::GetWindowThreadProcessId($fgHwnd, [ref]$fgPid)
    $fgName = Get-ProcName -ProcessId $fgPid
    $sb = New-Object System.Text.StringBuilder 256
    [void][W.N]::GetWindowText($fgHwnd, $sb, 256)
    Log-Raw "  owner PID: $fgPid"
    Log-Raw "  owner proc: $fgName"
    Log-Raw ("  title: `"{0}`"" -f $sb.ToString())
}

# --- All mintty top-level windows ---
Log-Line "--- All mintty.exe top-level windows on system ---"
$mintties = Get-AllMintty
if ($mintties.Count -eq 0) {
    Log-Raw "  (none found)"
} else {
    foreach ($m in $mintties) {
        Log-Raw ("  HWND 0x{0:X} - PID {1} - visible={2} - `"{3}`"" -f $m.HWND.ToInt64(), $m.PID, $m.Visible, $m.Title)
    }
}

Log-Line "=== end diagnostic ==="
Log-Raw ""
