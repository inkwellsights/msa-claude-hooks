$ErrorActionPreference = "Stop"

# ========= Error logging =========
$logPath = Join-Path $env:USERPROFILE ".claude\hooks\daemon.log"
function Log { param([string]$m) "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $m | Add-Content -LiteralPath $logPath }

try {

# Single-instance guard
$mutex = New-Object System.Threading.Mutex($false, 'Global\ClaudeSessionPickerDaemon_MSA')
if (-not $mutex.WaitOne(0)) { Log "another instance already running; exiting"; exit 0 }
Log "daemon starting, PID $PID"

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

Add-Type -Namespace W -Name P -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr hWnd, bool fAltTab);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
[DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);
[DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr hObject);
[DllImport("kernel32.dll")] public static extern bool QueryFullProcessImageName(IntPtr hProcess, uint dwFlags, System.Text.StringBuilder lpExeName, ref uint lpdwSize);
'@

# Compiled low-level keyboard hook. Gated to KbdHook.PickerVisible so it only suppresses
# arrow/Enter/Escape WHILE THE PICKER IS ON SCREEN. At all other times every key passes
# through unchanged. Static fields hold the delegate so the GC can't collect it.
if (-not ('KbdHook' -as [type])) {
    Add-Type -ReferencedAssemblies WindowsBase -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Threading;

public static class KbdHook {
    public delegate IntPtr LLKbdProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LLKbdProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN     = 0x0100;
    private const int WM_SYSKEYDOWN  = 0x0104;

    public static bool PickerVisible = false;
    public static Dispatcher PickerDispatcher = null;
    public static Action<int> OnKey = null;

    private static IntPtr _hHook = IntPtr.Zero;
    private static LLKbdProc _proc;

    public static int LastInstallError = 0;

    public static bool Install() {
        if (_hHook != IntPtr.Zero) return true;
        _proc = HookProc;
        IntPtr hmod = GetModuleHandle("user32.dll");
        _hHook = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, hmod, 0);
        if (_hHook == IntPtr.Zero) {
            LastInstallError = Marshal.GetLastWin32Error();
            return false;
        }
        return true;
    }

    public static void Uninstall() {
        if (_hHook != IntPtr.Zero) {
            UnhookWindowsHookEx(_hHook);
            _hHook = IntPtr.Zero;
        }
    }

    private static IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam) {
        try {
            if (nCode >= 0 && PickerVisible) {
                int msg = wParam.ToInt32();
                if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) {
                    KBDLLHOOKSTRUCT kb = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
                    int vk = (int)kb.vkCode;
                    // VK_UP=0x26, VK_DOWN=0x28, VK_RETURN=0x0D, VK_ESCAPE=0x1B
                    if (vk == 0x26 || vk == 0x28 || vk == 0x0D || vk == 0x1B) {
                        if (PickerDispatcher != null && OnKey != null) {
                            int v = vk;
                            Action act = delegate { try { OnKey(v); } catch { } };
                            PickerDispatcher.BeginInvoke(act);
                        }
                        return new IntPtr(1);
                    }
                }
            }
        } catch { }
        return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
    }
}
'@
}

# Compiled WinForms HotkeyForm - event fires on main thread (runspace available)
if (-not ('HotkeyForm' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class HotkeyForm : Form {
    [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    public event Action HotkeyPressed;

    public HotkeyForm() {
        this.FormBorderStyle = FormBorderStyle.None;
        this.ShowInTaskbar = false;
        this.Size = new System.Drawing.Size(0, 0);
        this.Opacity = 0;
        // Force handle creation without showing
        var _ = this.Handle;
    }

    protected override void SetVisibleCore(bool value) {
        // Never become visible
        base.SetVisibleCore(false);
    }

    public bool Register(int id, uint modifiers, uint vk) {
        return RegisterHotKey(this.Handle, id, modifiers, vk);
    }

    public void Deregister(int id) {
        UnregisterHotKey(this.Handle, id);
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312) { // WM_HOTKEY
            if (HotkeyPressed != null) HotkeyPressed();
            return;
        }
        base.WndProc(ref m);
    }
}
'@
}

# ========= Helpers =========
function Test-SessionLive {
    param([int64]$HwndInt, [int]$ExpectedPid)
    $hwnd = [IntPtr]$HwndInt
    if (-not [W.P]::IsWindow($hwnd)) { return $false }
    $actualPid = 0
    [void][W.P]::GetWindowThreadProcessId($hwnd, [ref]$actualPid)
    if ($actualPid -ne $ExpectedPid) { return $false }
    $h = [W.P]::OpenProcess(0x1000, $false, [uint32]$actualPid)
    if ($h -eq [IntPtr]::Zero) { return $false }
    $sb = New-Object System.Text.StringBuilder 1024
    $sz = [uint32]$sb.Capacity
    $ok = [W.P]::QueryFullProcessImageName($h, 0, $sb, [ref]$sz)
    [void][W.P]::CloseHandle($h)
    if (-not $ok) { return $false }
    return ((Split-Path -Leaf $sb.ToString()) -eq 'mintty.exe')
}

function Resolve-TranscriptPath {
    param([string]$Cwd, [string]$SessionId)
    if (-not $Cwd -or -not $SessionId) { return $null }
    $sanitized = $Cwd -replace '[:\\\/]', '-'
    $candidate = Join-Path $env:USERPROFILE ".claude\projects\$sanitized\$SessionId.jsonl"
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return $null
}

function Get-LastUserPromptSnippet {
    param([string]$TranscriptPath, [string]$SessionId, [int]$MaxLen = 70)

    # Fast path: snippet sidecar written by prompt-submit hook
    if ($SessionId) {
        $snipFile = Join-Path $env:USERPROFILE ".claude\session-windows\$SessionId.snippet"
        if (Test-Path -LiteralPath $snipFile) {
            try {
                $cached = (Get-Content -LiteralPath $snipFile -Raw -ErrorAction Stop).Trim()
                if ($cached) {
                    if ($cached.Length -gt $MaxLen) { $cached = $cached.Substring(0, $MaxLen - 3) + "..." }
                    return $cached
                }
            } catch { }
        }
    }

    # Fallback: parse the transcript (slow; only hit for sessions started before this hook existed)
    if (-not $TranscriptPath -or -not (Test-Path -LiteralPath $TranscriptPath)) { return "" }
    $lines = @(Get-Content -LiteralPath $TranscriptPath -Tail 20)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        try {
            $entry = $lines[$i] | ConvertFrom-Json
            if ($entry.type -eq "user" -and $entry.message -and ($entry.message.content -is [string])) {
                $t = ($entry.message.content -replace '\s+', ' ').Trim()
                if ($t -match '^([^\.\!\?\n]+)') { $t = $matches[1].Trim() }
                if ($t.Length -gt $MaxLen) { $t = $t.Substring(0, $MaxLen - 3) + "..." }
                return $t
            }
        } catch { }
    }
    return ""
}

function Get-SessionStatus {
    param([string]$SessionId)
    if (-not $SessionId) { return "idle" }
    $f = Join-Path $env:USERPROFILE ".claude\session-windows\$SessionId.status"
    if (-not (Test-Path -LiteralPath $f)) { return "idle" }
    try {
        $s = (Get-Content -LiteralPath $f -Raw -ErrorAction Stop).Trim()
        if ($s -eq 'running' -or $s -eq 'done' -or $s -eq 'idle') { return $s }
    } catch { }
    return "idle"
}

function Get-Sessions {
    $dir = Join-Path $env:USERPROFILE ".claude\session-windows"
    $result = @()
    if (-not (Test-Path -LiteralPath $dir)) { return ,$result }
    Get-ChildItem -LiteralPath $dir -Filter "*.json" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object {
            try {
                $d = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
                $project = if ($d.cwd) { Split-Path -Leaf $d.cwd } else { "Claude" }
                $tp = $d.transcript_path
                if (-not $tp) { $tp = Resolve-TranscriptPath -Cwd $d.cwd -SessionId $d.session_id }
                $snippet = Get-LastUserPromptSnippet -TranscriptPath $tp -SessionId $d.session_id
                $live = Test-SessionLive -HwndInt $d.hwnd -ExpectedPid $d.pid
                $status = Get-SessionStatus -SessionId $d.session_id
                $result += [PSCustomObject]@{
                    File = $_.FullName; SessionId = $d.session_id; Project = $project
                    Snippet = $snippet; Hwnd = [int64]$d.hwnd; Pid = [int]$d.pid; Live = $live
                    Status = $status
                }
            } catch { }
        }
    return ,$result
}

# ========= Build WPF window once =========
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Sessions"
        WindowStartupLocation="CenterScreen"
        SizeToContent="Height"
        Width="720"
        Background="#151515"
        Foreground="#EEE"
        FontFamily="Segoe UI"
        FontSize="13"
        WindowStyle="None"
        ResizeMode="NoResize"
        AllowsTransparency="True"
        Topmost="True"
        ShowInTaskbar="False"
        KeyboardNavigation.DirectionalNavigation="None"
        KeyboardNavigation.TabNavigation="None"
        KeyboardNavigation.ControlTabNavigation="None">
  <Border BorderBrush="#3A3A3A" BorderThickness="1" CornerRadius="6" Background="#151515" Padding="10">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <TextBlock Grid.Row="0" Text="Active Claude Sessions" FontWeight="Bold" FontSize="14" Margin="4,0,0,8" Foreground="#EEE"/>
      <ListBox Name="SessionList" Grid.Row="1" Background="Transparent" Foreground="#EEE" BorderThickness="0" MaxHeight="560" FontSize="13" Focusable="False">
        <ListBox.ItemContainerStyle>
          <Style TargetType="ListBoxItem">
            <Setter Property="Padding" Value="6,4"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Focusable" Value="False"/>
            <Style.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter Property="Background" Value="#2A4A6A"/>
              </Trigger>
            </Style.Triggers>
          </Style>
        </ListBox.ItemContainerStyle>
      </ListBox>
      <TextBlock Grid.Row="2" Foreground="#777" FontSize="11" Margin="4,8,0,0"
                 Text="Up/Down navigate   Enter switch   1-9 quick pick   Esc dismiss   (mouse double-click also works)"/>
    </Grid>
  </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$script:window = [Windows.Markup.XamlReader]::Load($reader)
$script:list   = $script:window.FindName('SessionList')
$script:activated = $false

$script:window.Add_Closing({ param($s, $e) $e.Cancel = $true; $s.Hide() })
$script:window.Add_Deactivated({
    if ($script:window.IsVisible) { $script:window.Hide() }
    if ($script:timer) { $script:timer.Stop() }
})

$activate = {
    if ($script:activated) { return }
    $sel = $script:list.SelectedItem
    if (-not $sel -and $script:list.Items.Count -gt 0) {
        $idx = $script:list.SelectedIndex
        if ($idx -lt 0) { $idx = 0 }
        $sel = $script:list.Items[$idx]
    }
    if (-not $sel) { return }
    $s = $sel.Tag
    $script:activated = $true
    if (-not $s.Live) {
        Remove-Item -LiteralPath $s.File -ErrorAction SilentlyContinue
    } else {
        [W.P]::SwitchToThisWindow([IntPtr]([int64]$s.Hwnd), $true)
        # User opened this terminal via picker -- clear 'done' dot. Leaves
        # 'running' alone (still in progress) and 'idle' alone (nothing to clear).
        try {
            if ($s.SessionId -and $s.Status -eq 'done') {
                $statusFile = Join-Path $env:USERPROFILE ".claude\session-windows\$($s.SessionId).status"
                Remove-Item -LiteralPath $statusFile -ErrorAction SilentlyContinue
                Log "cleared done status for $($s.SessionId)"
            }
        } catch { Log "clear status error: $_" }
    }
    $script:window.Hide()
}

$navUp = {
    if ($script:list.Items.Count -eq 0) { return }
    $i = $script:list.SelectedIndex
    if ($i -le 0) { $i = $script:list.Items.Count - 1 } else { $i-- }
    $script:list.SelectedIndex = $i
    $script:list.ScrollIntoView($script:list.Items[$i])
}
$navDown = {
    if ($script:list.Items.Count -eq 0) { return }
    $i = $script:list.SelectedIndex
    if ($i -ge $script:list.Items.Count - 1) { $i = 0 } else { $i++ }
    $script:list.SelectedIndex = $i
    $script:list.ScrollIntoView($script:list.Items[$i])
}

$script:window.Add_KeyDown({
    param($sender, $e)
    $k = $e.Key.ToString()
    Log "KeyDown: $k  (selIdx=$($script:list.SelectedIndex))"
    if ($k -eq 'Escape')                    { $script:window.Hide(); $e.Handled = $true; return }
    if ($k -eq 'Enter' -or $k -eq 'Return') { & $activate; $e.Handled = $true; return }
    if ($k -eq 'Up')                        { & $navUp;   $e.Handled = $true; return }
    if ($k -eq 'Down')                      { & $navDown; $e.Handled = $true; return }
    $digit = 0
    if ($k -match '^D([1-9])$')         { $digit = [int]$matches[1] }
    elseif ($k -match '^NumPad([1-9])$'){ $digit = [int]$matches[1] }
    if ($digit -ge 1 -and $digit -le $script:list.Items.Count) {
        $script:list.SelectedIndex = $digit - 1
        & $activate
    }
})
# ListBoxItem Focusable=False (needed for our keyboard hook design) disables the
# default click-to-select. Re-wire it explicitly: walk up the visual tree to find
# the clicked ListBoxItem and sync SelectedIndex, so both single-click highlight
# and double-click activation work.
$script:list.Add_PreviewMouseLeftButtonDown({
    param($sender, $e)
    try {
        $src = $e.OriginalSource
        while ($src -and -not ($src -is [System.Windows.Controls.ListBoxItem])) {
            if (-not ($src -is [System.Windows.DependencyObject])) { $src = $null; break }
            $src = [System.Windows.Media.VisualTreeHelper]::GetParent($src)
        }
        if ($src) {
            $idx = $script:list.ItemContainerGenerator.IndexFromContainer($src)
            if ($idx -ge 0) { $script:list.SelectedIndex = $idx }
        }
    } catch { Log "mouse select error: $_" }
})
$script:list.Add_MouseDoubleClick({ & $activate })

# ========= InputBindings: route nav keys via CommandManager so they bypass focus consumption =========
$noMod     = [System.Windows.Input.ModifierKeys]::None
$ownerType = [System.Windows.Window]
$cmdUp   = New-Object System.Windows.Input.RoutedUICommand -ArgumentList @('NavUp',   'NavUp',   $ownerType)
$cmdDown = New-Object System.Windows.Input.RoutedUICommand -ArgumentList @('NavDown', 'NavDown', $ownerType)
$cmdAct  = New-Object System.Windows.Input.RoutedUICommand -ArgumentList @('Act',     'Act',     $ownerType)
$cmdDis  = New-Object System.Windows.Input.RoutedUICommand -ArgumentList @('Dis',     'Dis',     $ownerType)

[void]$script:window.InputBindings.Add((New-Object System.Windows.Input.KeyBinding $cmdUp,   ([System.Windows.Input.Key]::Up),     $noMod))
[void]$script:window.InputBindings.Add((New-Object System.Windows.Input.KeyBinding $cmdDown, ([System.Windows.Input.Key]::Down),   $noMod))
[void]$script:window.InputBindings.Add((New-Object System.Windows.Input.KeyBinding $cmdAct,  ([System.Windows.Input.Key]::Enter),  $noMod))
[void]$script:window.InputBindings.Add((New-Object System.Windows.Input.KeyBinding $cmdDis,  ([System.Windows.Input.Key]::Escape), $noMod))

$execUp   = [System.Windows.Input.ExecutedRoutedEventHandler]{ param($s,$e) Log "InputBinding: Up";       & $navUp;   $e.Handled = $true }
$execDown = [System.Windows.Input.ExecutedRoutedEventHandler]{ param($s,$e) Log "InputBinding: Down";     & $navDown; $e.Handled = $true }
$execAct  = [System.Windows.Input.ExecutedRoutedEventHandler]{ param($s,$e) Log "InputBinding: Activate"; & $activate; $e.Handled = $true }
$execDis  = [System.Windows.Input.ExecutedRoutedEventHandler]{ param($s,$e) Log "InputBinding: Dismiss";  $script:window.Hide(); $e.Handled = $true }

[void]$script:window.CommandBindings.Add((New-Object System.Windows.Input.CommandBinding $cmdUp,   $execUp))
[void]$script:window.CommandBindings.Add((New-Object System.Windows.Input.CommandBinding $cmdDown, $execDown))
[void]$script:window.CommandBindings.Add((New-Object System.Windows.Input.CommandBinding $cmdAct,  $execAct))
[void]$script:window.CommandBindings.Add((New-Object System.Windows.Input.CommandBinding $cmdDis,  $execDis))

# ========= Spinner / status icon timer =========
$script:spinFrames = @('|', '/', '-', '\')
$script:spinIdx = 0
$script:doneChar = [string][char]0x25CF  # filled circle, constructed at runtime to keep source ASCII

function Update-StatusIcons {
    $frame = $script:spinFrames[$script:spinIdx]
    foreach ($item in $script:list.Items) {
        $sid = $null
        try { $sid = $item.Tag.SessionId } catch { }
        if (-not $sid) { continue }
        $sp = $item.Content
        if (-not $sp -or $sp.Children.Count -lt 1) { continue }
        $iconLbl = $sp.Children[0]
        $st = Get-SessionStatus -SessionId $sid
        if ($st -eq 'running') {
            $iconLbl.Text = $frame
            $iconLbl.Foreground = [System.Windows.Media.Brushes]::LimeGreen
        } elseif ($st -eq 'done') {
            $iconLbl.Text = $script:doneChar
            $iconLbl.Foreground = [System.Windows.Media.Brushes]::Orange
        } else {
            $iconLbl.Text = ' '
        }
    }
}

$script:timer = New-Object System.Windows.Threading.DispatcherTimer
$script:timer.Interval = [TimeSpan]::FromMilliseconds(150)
$script:timer.Add_Tick({
    $script:spinIdx = ($script:spinIdx + 1) % $script:spinFrames.Count
    Update-StatusIcons
})

function Show-Picker {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $script:timer.Stop()
    $script:list.Items.Clear()
    $sessions = Get-Sessions
    $tGet = $sw.ElapsedMilliseconds
    if ($sessions.Count -eq 0) { Log ("Show: no sessions ({0}ms)" -f $tGet); return }

    $idx = 0
    foreach ($s in $sessions) {
        $idx++
        $numPrefix = if ($idx -le 9) { "$idx. " } else { "   " }
        $suffix = if (-not $s.Live) { "   (closed)" } else { "" }

        $item = New-Object System.Windows.Controls.ListBoxItem
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'

        # Status icon - fixed-width slot at the start so all rows align
        $lbl0 = New-Object System.Windows.Controls.TextBlock
        $lbl0.Width = 18
        $lbl0.TextAlignment = 'Center'
        $lbl0.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
        $lbl0.Text = ' '

        $lbl1 = New-Object System.Windows.Controls.TextBlock
        $lbl1.Text = "$numPrefix[" ; $lbl1.Foreground = [System.Windows.Media.Brushes]::Gray

        $lbl2 = New-Object System.Windows.Controls.TextBlock
        $lbl2.Text = $s.Project ; $lbl2.FontWeight = 'Bold'

        $lbl3 = New-Object System.Windows.Controls.TextBlock
        $lbl3.Text = "]  " ; $lbl3.Foreground = [System.Windows.Media.Brushes]::Gray

        $lbl4 = New-Object System.Windows.Controls.TextBlock
        $lbl4.Text = $s.Snippet

        $lbl5 = New-Object System.Windows.Controls.TextBlock
        $lbl5.Text = $suffix ; $lbl5.Foreground = [System.Windows.Media.Brushes]::OrangeRed ; $lbl5.FontStyle = 'Italic'

        [void]$sp.Children.Add($lbl0)
        [void]$sp.Children.Add($lbl1); [void]$sp.Children.Add($lbl2)
        [void]$sp.Children.Add($lbl3); [void]$sp.Children.Add($lbl4); [void]$sp.Children.Add($lbl5)

        if (-not $s.Live) {
            $lbl2.Foreground = [System.Windows.Media.Brushes]::DimGray
            $lbl4.Foreground = [System.Windows.Media.Brushes]::DimGray
        }

        $item.Content = $sp ; $item.Tag = $s
        [void]$script:list.Items.Add($item)
    }
    $script:list.SelectedIndex = 0
    $script:activated = $false
    $tBuild = $sw.ElapsedMilliseconds
    Update-StatusIcons
    $tIcons = $sw.ElapsedMilliseconds
    $script:window.Show()
    $script:window.Activate()
    $script:timer.Start()
    Log ("Show: total={0}ms (sessions={1} get={2}ms build={3}ms icons={4}ms)" -f $sw.ElapsedMilliseconds, $sessions.Count, $tGet, ($tBuild-$tGet), ($tIcons-$tBuild))
}

# Pre-materialize WPF window so first Show() is fast
$script:window.Opacity = 0
$script:window.Show()
$script:window.Hide()
$script:window.Opacity = 1
Log "WPF window pre-materialized"

# ========= WndProc hook: catch keys at Win32 layer, below WPF's input pipeline =========
# WPF + WindowStyle=None + AllowsTransparency=True + WM_HOTKEY origin makes arrow/Enter/Escape
# vanish before WPF KeyDown fires. Hooking the raw WndProc bypasses that entirely.
$script:wndHook = [System.Windows.Interop.HwndSourceHook]{
    param($hwnd, $msg, $wParam, $lParam, $handledRef)
    try {
        # Suppress menu-mode activation (Alt-press from the hotkey otherwise puts Win32
        # into menu nav, which silently eats arrow/Enter/Escape on a menu-less window)
        if ($msg -eq 0x0112) {
            $sc = ([int]$wParam) -band 0xFFF0
            if ($sc -eq 0xF100) {
                Log "ate WM_SYSCOMMAND SC_KEYMENU"
                $handledRef.Value = $true
                return [IntPtr]::Zero
            }
        }

        # WM_KEYDOWN=0x100, WM_SYSKEYDOWN=0x104
        if (($msg -eq 0x0100 -or $msg -eq 0x0104) -and $script:window.IsVisible) {
            $vk = [int]$wParam
            $handledHere = $false
            switch ($vk) {
                0x26 { Log "WndProc: VK_UP";     & $navUp;     $handledHere = $true }  # Up
                0x28 { Log "WndProc: VK_DOWN";   & $navDown;   $handledHere = $true }  # Down
                0x0D { Log "WndProc: VK_RETURN"; & $activate;  $handledHere = $true }  # Enter
                0x1B { Log "WndProc: VK_ESCAPE"; $script:window.Hide(); $handledHere = $true }  # Esc
                default { Log ("WndProc: vk=0x{0:X2} msg=0x{1:X}" -f $vk, $msg) }
            }
            if ($handledHere) {
                $handledRef.Value = $true
                return [IntPtr]::Zero
            }
        }
    } catch {
        Log "wndHook error: $_"
    }
    return [IntPtr]::Zero
}

$script:wih = New-Object System.Windows.Interop.WindowInteropHelper $script:window
$script:hwndForPicker = $script:wih.Handle
$script:hwndSrc = [System.Windows.Interop.HwndSource]::FromHwnd($script:hwndForPicker)
if ($script:hwndSrc) {
    $script:hwndSrc.AddHook($script:wndHook)
    Log ("WndProc hook attached to HWND 0x{0:X}" -f [int64]$script:hwndForPicker)
} else {
    Log "FAILED to attach WndProc hook"
}

# ========= Low-level keyboard hook =========
# Tracks visibility via IsVisibleChanged so hook only fires when picker is on screen.
$script:window.Add_IsVisibleChanged({
    [KbdHook]::PickerVisible = [bool]$script:window.IsVisible
})

[KbdHook]::PickerDispatcher = $script:window.Dispatcher
[KbdHook]::OnKey = [Action[int]]{
    param($vk)
    try {
        Log ("LLHook: vk=0x{0:X2}" -f $vk)
        switch ($vk) {
            0x26 { & $navUp }                 # Up
            0x28 { & $navDown }               # Down
            0x0D { & $activate }              # Enter
            0x1B { $script:window.Hide() }    # Escape
        }
    } catch { Log "LLHook handler error: $_" }
}
$llInstalled = [KbdHook]::Install()
if ($llInstalled) {
    Log "LL keyboard hook installed OK"
} else {
    Log ("LL keyboard hook FAILED to install (Win32 err={0})" -f [KbdHook]::LastInstallError)
}

# Bootstrap snippet sidecars for any existing sessions that don't have one yet,
# so the first picker show doesn't pay the transcript-parse cost.
function Bootstrap-Snippets {
    $dir = Join-Path $env:USERPROFILE ".claude\session-windows"
    if (-not (Test-Path -LiteralPath $dir)) { return }
    $count = 0
    Get-ChildItem -LiteralPath $dir -Filter "*.json" -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $d = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
            if (-not $d.session_id) { return }
            $snipFile = Join-Path $dir "$($d.session_id).snippet"
            if (Test-Path -LiteralPath $snipFile) { return }
            $tp = $d.transcript_path
            if (-not $tp) { $tp = Resolve-TranscriptPath -Cwd $d.cwd -SessionId $d.session_id }
            if (-not $tp -or -not (Test-Path -LiteralPath $tp)) { return }
            $lines = @(Get-Content -LiteralPath $tp -Tail 80)
            for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                try {
                    $entry = $lines[$i] | ConvertFrom-Json
                    if ($entry.type -eq "user" -and $entry.message -and ($entry.message.content -is [string])) {
                        $t = ($entry.message.content -replace '\s+', ' ').Trim()
                        if ($t -match '^([^\.\!\?\n]+)') { $t = $matches[1].Trim() }
                        if ($t.Length -gt 100) { $t = $t.Substring(0, 97) + "..." }
                        Set-Content -LiteralPath $snipFile -Value $t -Encoding UTF8
                        $script:count++
                        return
                    }
                } catch { }
            }
        } catch { }
    }
}
Bootstrap-Snippets
Log "snippet bootstrap done"

# ========= Hotkey form =========
$script:hkForm = New-Object HotkeyForm
$script:hkForm.add_HotkeyPressed({
    try {
        Log "hotkey pressed"
        Show-Picker
    } catch {
        Log "Show-Picker error: $_"
    }
})

# Alt+`: MOD_ALT=1; VK_OEM_3 (backtick) = 0xC0
$registered = $script:hkForm.Register(1, 1, 0xC0)
if (-not $registered) {
    Log "RegisterHotKey FAILED -- Alt+backtick is likely already taken."
    throw "Hotkey registration failed"
}
Log "hotkey Alt+backtick registered; entering message loop"

# ========= Message loop =========
[System.Windows.Forms.Application]::Run()
Log "message loop exited (unexpected)"

} catch {
    Log "FATAL: $($_.Exception.Message)"
    Log "stack: $($_.ScriptStackTrace)"
    throw
}
