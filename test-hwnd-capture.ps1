param(
    [Parameter(Mandatory = $true)] [int]$MinttyWinPid
)

$ErrorActionPreference = "Stop"

Add-Type -Namespace W32 -Name U -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
[DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
[DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
public struct RECT { public int Left, Top, Right, Bottom; }
'@

Write-Host ""
Write-Host "=== Looking up HWND for mintty PID $MinttyWinPid ===" -ForegroundColor Cyan

# Pin to script scope so the EnumWindows callback can access it reliably
$script:TargetPid = $MinttyWinPid
$script:found = @()

$callback = [W32.U+EnumWindowsProc] {
    param($hwnd, $lparam)
    $procId = 0
    [void][W32.U]::GetWindowThreadProcessId($hwnd, [ref]$procId)
    if ($procId -eq $script:TargetPid -and [W32.U]::IsWindowVisible($hwnd)) {
        $sb = New-Object System.Text.StringBuilder 256
        [void][W32.U]::GetWindowText($hwnd, $sb, 256)
        $script:found += [PSCustomObject]@{ HWND = $hwnd; Title = $sb.ToString() }
    }
    return $true
}

[void][W32.U]::EnumWindows($callback, [IntPtr]::Zero)

if ($script:found.Count -eq 0) {
    Write-Error "No visible windows found for PID $MinttyWinPid. HWND capture via EnumWindows failed."
    exit 1
}

Write-Host ""
Write-Host "Matching windows:"
$script:found | ForEach-Object {
    Write-Host ("  HWND 0x{0:X} - '{1}'" -f $_.HWND.ToInt64(), $_.Title)
}

$target = $script:found[0]
Write-Host ""
Write-Host ("Using HWND 0x{0:X} - '{1}'" -f $target.HWND.ToInt64(), $target.Title) -ForegroundColor Green

$rect = New-Object W32.U+RECT
[void][W32.U]::GetWindowRect($target.HWND, [ref]$rect)
$w = $rect.Right - $rect.Left
$h = $rect.Bottom - $rect.Top
Write-Host ("Current rect: ({0},{1}) {2}x{3}" -f $rect.Left, $rect.Top, $w, $h)

Write-Host ""
Write-Host "=== Visual proof: MoveWindow in 2 seconds ===" -ForegroundColor Cyan
Start-Sleep -Seconds 2
[void][W32.U]::MoveWindow($target.HWND, ($rect.Left + 300), ($rect.Top + 200), $w, $h, $true)
Write-Host "Moved. If the CORRECT mintty window jumped down-right by (300, 200), capture works." -ForegroundColor Green
