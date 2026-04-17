$ErrorActionPreference = "SilentlyContinue"

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

Add-Type -Namespace W -Name P -MemberDefinition @'
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
    # Claude Code project-dir convention: drive colon + backslashes become hyphens
    $sanitized = $Cwd -replace '[:\\\/]', '-'
    $candidate = Join-Path $env:USERPROFILE ".claude\projects\$sanitized\$SessionId.jsonl"
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return $null
}

function Get-LastUserPromptSnippet {
    param([string]$TranscriptPath, [int]$MaxLen = 70)
    if (-not $TranscriptPath -or -not (Test-Path -LiteralPath $TranscriptPath)) { return "" }
    $lines = @(Get-Content -LiteralPath $TranscriptPath -Tail 80)
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

# Load sessions
$dir = Join-Path $env:USERPROFILE ".claude\session-windows"
$sessions = @()
if (Test-Path -LiteralPath $dir) {
    Get-ChildItem -LiteralPath $dir -Filter "*.json" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object {
            try {
                $d = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
                $project = if ($d.cwd) { Split-Path -Leaf $d.cwd } else { "Claude" }
                $tp = $d.transcript_path
                if (-not $tp) { $tp = Resolve-TranscriptPath -Cwd $d.cwd -SessionId $d.session_id }
                $snippet = Get-LastUserPromptSnippet -TranscriptPath $tp
                $live = Test-SessionLive -HwndInt $d.hwnd -ExpectedPid $d.pid
                $sessions += [PSCustomObject]@{
                    File      = $_.FullName
                    SessionId = $d.session_id
                    Project   = $project
                    Snippet   = $snippet
                    Hwnd      = [int64]$d.hwnd
                    Pid       = [int]$d.pid
                    Live      = $live
                }
            } catch { }
        }
}

if ($sessions.Count -eq 0) { exit 0 }

# XAML
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
        ShowInTaskbar="False">
  <Border BorderBrush="#3A3A3A" BorderThickness="1" CornerRadius="6" Background="#151515" Padding="10">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <TextBlock Grid.Row="0" Text="Active Claude Sessions" FontWeight="Bold" FontSize="14" Margin="4,0,0,8" Foreground="#EEE"/>
      <ListBox Name="SessionList" Grid.Row="1" Background="Transparent" Foreground="#EEE" BorderThickness="0" MaxHeight="400" FontSize="13">
        <ListBox.ItemContainerStyle>
          <Style TargetType="ListBoxItem">
            <Setter Property="Padding" Value="6,4"/>
            <Setter Property="BorderThickness" Value="0"/>
          </Style>
        </ListBox.ItemContainerStyle>
      </ListBox>
      <TextBlock Grid.Row="2" Foreground="#777" FontSize="11" Margin="4,8,0,0"
                 Text="Up/Down navigate   Enter switch   1-9 quick pick   Esc dismiss"/>
    </Grid>
  </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$list = $window.FindName('SessionList')

# Populate
$idx = 0
foreach ($s in $sessions) {
    $idx++
    $numPrefix = if ($idx -le 9) { "$idx. " } else { "   " }
    $suffix = if (-not $s.Live) { "   (closed)" } else { "" }

    $item = New-Object System.Windows.Controls.ListBoxItem
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'

    $lbl1 = New-Object System.Windows.Controls.TextBlock
    $lbl1.Text = "$numPrefix["
    $lbl1.Foreground = [System.Windows.Media.Brushes]::Gray

    $lbl2 = New-Object System.Windows.Controls.TextBlock
    $lbl2.Text = $s.Project
    $lbl2.FontWeight = 'Bold'

    $lbl3 = New-Object System.Windows.Controls.TextBlock
    $lbl3.Text = "]  "
    $lbl3.Foreground = [System.Windows.Media.Brushes]::Gray

    $lbl4 = New-Object System.Windows.Controls.TextBlock
    $lbl4.Text = $s.Snippet

    $lbl5 = New-Object System.Windows.Controls.TextBlock
    $lbl5.Text = $suffix
    $lbl5.Foreground = [System.Windows.Media.Brushes]::OrangeRed
    $lbl5.FontStyle = 'Italic'

    [void]$sp.Children.Add($lbl1)
    [void]$sp.Children.Add($lbl2)
    [void]$sp.Children.Add($lbl3)
    [void]$sp.Children.Add($lbl4)
    [void]$sp.Children.Add($lbl5)

    if (-not $s.Live) {
        $lbl2.Foreground = [System.Windows.Media.Brushes]::DimGray
        $lbl4.Foreground = [System.Windows.Media.Brushes]::DimGray
    }

    $item.Content = $sp
    $item.Tag = $s
    [void]$list.Items.Add($item)
}
if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 }

# Activation
$script:activated = $false
$activate = {
    if ($script:activated) { return }
    $sel = $list.SelectedItem
    if (-not $sel) { return }
    $s = $sel.Tag
    $script:activated = $true
    if (-not $s.Live) {
        Remove-Item -LiteralPath $s.File -ErrorAction SilentlyContinue
    } else {
        [W.P]::SwitchToThisWindow([IntPtr]([int64]$s.Hwnd), $true)
    }
    $window.Close()
}

$window.Add_KeyDown({
    param($sender, $e)
    $k = $e.Key.ToString()
    if ($k -eq 'Escape') { $window.Close(); return }
    if ($k -eq 'Enter')  { & $activate; return }
    $digit = 0
    if ($k -match '^D([1-9])$')       { $digit = [int]$matches[1] }
    elseif ($k -match '^NumPad([1-9])$') { $digit = [int]$matches[1] }
    if ($digit -ge 1 -and $digit -le $list.Items.Count) {
        $list.SelectedIndex = $digit - 1
        & $activate
    }
})

# Double-click activates
$list.Add_MouseDoubleClick({ & $activate })

# Dismiss on blur (clicking outside)
$window.Add_Deactivated({ $window.Close() })

$window.Add_Loaded({ $list.Focus() })
[void]$window.ShowDialog()
