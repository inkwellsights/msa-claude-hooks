# Completion cards owned by the resident picker's UI thread.
if (-not $script:completionPopups) { $script:completionPopups = New-Object Collections.ArrayList }
if (-not $script:popupFocusObservers) { $script:popupFocusObservers=@{} }
if (-not $script:popupAutoFocusTimers) { $script:popupAutoFocusTimers=@{} }
$script:agentPopupQueue = Join-Path $env:USERPROFILE '.claude\hooks\popup-queue'
if (-not $script:recentAgentCompletions) { $script:recentAgentCompletions=@() }
function Add-AgentRecentCompletion {
    param($Request)
    $script:recentAgentCompletions=@($Request)+@($script:recentAgentCompletions | Where-Object {
        $_.Provider -ne $Request.Provider -or $_.SessionId -ne $Request.SessionId
    } | Select-Object -First 19)
}
function Update-AgentCompletionTray {
    if (-not $script:recentCompletionsMenu) { return }
    while($script:recentCompletionsMenu.DropDownItems.Count) {
        $oldItem=$script:recentCompletionsMenu.DropDownItems[0]
        $script:recentCompletionsMenu.DropDownItems.Remove($oldItem)
        $oldItem.Dispose()
    }
    foreach($request in $script:recentAgentCompletions) {
        $view=Get-AgentPopupView $request
        $item=New-Object System.Windows.Forms.ToolStripMenuItem("$($request.Provider): $($view.Name)")
        $item.Tag=$request
        $item.ToolTipText=$view.Preview
        $item.Add_Click({ param($sender,$event)
            # The tray click opens the same card that has passed physical focus tests.
            # Keep a card available when Windows rejects direct tray activation.
            $r=$sender.Tag
            $copy=[pscustomobject]@{Provider=$r.Provider;SessionId=$r.SessionId;Name=$r.Name;Snippet=$r.Snippet;Silent=$true}
            Show-AgentCompletionPopup $copy
            $popup=$script:completionPopups[$script:completionPopups.Count-1]
            $popup.Activate() | Out-Null
            Activate-AgentCompletionPopup $popup
        })
        [void]$script:recentCompletionsMenu.DropDownItems.Add($item)
    }
    if ($script:recentAgentCompletions.Count -eq 0) {
        $empty=$script:recentCompletionsMenu.DropDownItems.Add('No recent completions')
        $empty.Enabled=$false
    }
}
function Write-PopupLog([string]$Message) {
    Add-Content -LiteralPath (Join-Path $PSScriptRoot 'popup.log') -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] $Message"
}
function Write-AgentPopupRequest {
    param([string]$Provider,[string]$SessionId,[string]$Name,[string]$Snippet='',[switch]$Silent,[switch]$AutoFocus,[string]$Directory=$script:agentPopupQueue)
    if (-not (ConvertFrom-AgentRecallUri "clauderecall://$Provider/$SessionId")) { throw 'Invalid completion popup session.' }
    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    $path=Join-Path $Directory ([guid]::NewGuid().ToString('N')+'.json')
    $temp=$path+'.tmp'
    $view=Get-AgentPopupView ([pscustomobject]@{Provider=$Provider;Name=$Name;Snippet=$Snippet})
    try {
        @{Provider=$Provider;SessionId=$SessionId;Name=$view.Name;Snippet=$view.Preview;Silent=[bool]$Silent;AutoFocus=[bool]$AutoFocus;CreatedUtc=[datetime]::UtcNow.ToString('o')} |
            ConvertTo-Json | Set-Content -LiteralPath $temp -Encoding UTF8
        Move-Item -LiteralPath $temp -Destination $path
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp } }
}
function Read-AgentPopupRequests {
    param([string]$Directory=$script:agentPopupQueue)
    if (-not (Test-Path -LiteralPath $Directory)) { return @() }
    $requests=@()
    foreach($file in @(Get-ChildItem -LiteralPath $Directory -Filter '*.json' | Sort-Object CreationTimeUtc)) {
        try {
            if ($file.Length -gt 65536) { continue }
            $r=Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            if (-not (ConvertFrom-AgentRecallUri "clauderecall://$($r.Provider)/$($r.SessionId)")) { continue }
            $age=([datetime]::UtcNow-([datetime]$r.CreatedUtc).ToUniversalTime()).TotalSeconds
            if ($age -lt -30 -or $age -gt 120) { continue }
            $requests += $r
        } catch { Write-PopupLog "discarded malformed request: $($_.Exception.Message)" }
        finally { Remove-Item -LiteralPath $file.FullName -ErrorAction SilentlyContinue }
    }
    return $requests
}
function Get-AgentPopupView {
    param($Request)
    $name=([string]$Request.Name -replace '\s+',' ').Trim()
    $preview=([string]$Request.Snippet -replace '\s+',' ').Trim()
    if ($name.Length -gt 160) { $name=$name.Substring(0,157)+'...' }
    if ($preview.Length -gt 240) { $preview=$preview.Substring(0,237)+'...' }
    if (-not $preview) { $preview='The session has finished its response.' }
    [pscustomobject]@{Title="$($Request.Provider) finished";Name=$name;Preview=$preview}
}
function Arrange-AgentCompletionPopups {
    $area=[Windows.SystemParameters]::WorkArea
    $bottom=$area.Bottom-18
    foreach($popup in @($script:completionPopups | Select-Object -Last 3 | Sort-Object { $_.Tag.Created } -Descending)) {
        $popup.Left=$area.Right-$popup.Width-18
        $popup.Top=$bottom-$popup.Height
        $bottom=$popup.Top-10
    }
}
function Close-AgentCompletionPopup {
    param([Windows.Window]$Window)
    if (-not $Window) { return }
    $Window.Close()
}
function Activate-AgentCompletionPopup {
    param([Windows.Window]$Window)
    if ($Window.Tag.Busy) { return }
    $Window.Tag.Busy=$true
    try {
        $r=$Window.Tag.Request
        $session=Get-AgentSessions | Where-Object { $_.Provider -eq $r.Provider -and $_.SessionId -eq $r.SessionId } | Select-Object -First 1
        if (-not $session) { throw 'This session has closed. Press Alt + backtick for current sessions.' }
        Write-PopupLog "click provider=$($r.Provider) sid=$($r.SessionId) target=$($session.Hwnd) foreground=$([AgentWindows]::GetForegroundWindow())"
        # The real click activates this card. Retain that permission until focus
        # has been handed to the target, just like the working picker.
        if (-not [AgentWindows]::Focus([int64]$session.Hwnd,[int]$session.Pid)) { throw 'Switching failed. Press Alt + backtick to open this session.' }
        Write-PopupLog "focus verified hwnd=$($session.Hwnd)"
        if ($session.Provider -eq 'Codex' -and $script:codexStates -and $script:codexStates.ContainsKey($session.SessionId)) {
            $script:codexAcknowledged[$session.SessionId]=$script:codexStates[$session.SessionId].EventKey
        } elseif ($session.Provider -eq 'Claude') {
            $status=Join-Path $env:USERPROFILE ".claude\session-windows\$($session.SessionId).status"
            if ((Test-Path -LiteralPath $status) -and (Get-Content -LiteralPath $status -Raw).Trim() -eq 'done') { Set-Content -LiteralPath $status -Value idle -Encoding ASCII }
        }
        # Observe after closing the card without blocking the UI or taking focus back.
        $observation=New-Object Windows.Threading.DispatcherTimer
        $observation.Interval=[timespan]::FromSeconds(2)
        $script:popupFocusObservers[$observation]=[pscustomobject]@{Hwnd=$session.Hwnd;SessionId=$session.SessionId}
        $observation.Add_Tick({ param($sender,$event)
            $sender.Stop()
            $observer=$script:popupFocusObservers[$sender]
            $front=[AgentWindows]::GetForegroundWindow().ToInt64()
            Write-PopupLog "focus after 2s sid=$($observer.SessionId) target=$($observer.Hwnd) foreground=$front retained=$($front -eq $observer.Hwnd)"
            $script:popupFocusObservers.Remove($sender)
        })
        $observation.Start()
        Close-AgentCompletionPopup $Window
    } catch {
        $Window.Tag.Preview.Text=$_.Exception.Message
        $Window.Tag.Busy=$false
        Write-PopupLog "click failed: $($_.Exception.Message)"
    }
}
function Show-AgentCompletionPopup {
    param($Request)
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    $view=Get-AgentPopupView $Request
    [xml]$markup=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
 xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="410" Height="208"
 Title="Session completion" WindowStyle="None" ResizeMode="NoResize" ShowInTaskbar="False"
 ShowActivated="False" Topmost="True" Background="#202020">
 <Border BorderBrush="#606060" BorderThickness="1" Padding="18,14,18,14">
  <Grid>
   <Grid.RowDefinitions><RowDefinition Height="28"/><RowDefinition Height="40"/><RowDefinition Height="*"/><RowDefinition Height="26"/></Grid.RowDefinitions>
   <TextBlock x:Name="TitleText" Foreground="#F2F2F2" FontFamily="Segoe UI" FontSize="15" FontWeight="SemiBold" VerticalAlignment="Center"/>
   <Button x:Name="DismissButton" Content="X" Width="28" Height="26" HorizontalAlignment="Right" VerticalAlignment="Top"
    Background="#202020" Foreground="#CCCCCC" BorderThickness="0" ToolTip="Dismiss notification"/>
   <TextBlock x:Name="NameText" Grid.Row="1" Foreground="#F2F2F2" FontFamily="Segoe UI" FontSize="14" TextWrapping="Wrap" TextTrimming="CharacterEllipsis" Margin="0,5,0,5"/>
   <TextBlock x:Name="PreviewText" Grid.Row="2" Foreground="#C0C0C0" FontFamily="Segoe UI" FontSize="12" TextWrapping="Wrap" TextTrimming="CharacterEllipsis"/>
   <TextBlock Grid.Row="3" Text="Click to switch to this session" Foreground="#F5B94F" FontFamily="Segoe UI" FontSize="12" VerticalAlignment="Bottom"/>
  </Grid>
 </Border>
</Window>
'@
    $reader=New-Object Xml.XmlNodeReader $markup
    $popup=[Windows.Markup.XamlReader]::Load($reader)
    $popup.FindName('TitleText').Text=$view.Title
    $popup.FindName('NameText').Text=$view.Name
    $preview=$popup.FindName('PreviewText'); $preview.Text=$view.Preview
    $popup.Tag=[pscustomobject]@{Request=$Request;Busy=$false;Created=[datetime]::UtcNow;Deadline=[datetime]::UtcNow.AddSeconds(5);Preview=$preview}
    $popup.Add_MouseLeftButtonUp({ param($sender,$event)
        $source=$event.OriginalSource
        while($source -and $source -ne $sender) {
            if ($source -is [Windows.Controls.Button]) { return }
            if (-not ($source -is [Windows.DependencyObject])) { break }
            $source=[Windows.Media.VisualTreeHelper]::GetParent($source)
        }
        Activate-AgentCompletionPopup -Window $sender
    })
    $dismiss=$popup.FindName('DismissButton'); $dismiss.Tag=$popup
    $dismiss.Add_Click({ param($sender,$event) Close-AgentCompletionPopup -Window $sender.Tag; $event.Handled=$true })
    $popup.Add_Closed({ param($sender,$event) [void]$script:completionPopups.Remove($sender); Arrange-AgentCompletionPopups })
    $popup.Add_MouseLeave({ param($sender,$event) $sender.Tag.Deadline=[datetime]::UtcNow.AddSeconds(5) })
    while($script:completionPopups.Count -ge 3) { Close-AgentCompletionPopup $script:completionPopups[0] }
    [void]$script:completionPopups.Add($popup)
    Arrange-AgentCompletionPopups
    $before=[AgentWindows]::GetForegroundWindow()
    $popup.Show()
    Write-PopupLog "shown provider=$($Request.Provider) sid=$($Request.SessionId) foregroundBefore=$before foregroundAfter=$([AgentWindows]::GetForegroundWindow())"
    if (-not $Request.Silent -and (Get-AgentSettings).SoundEnabled) { try { [Console]::Beep(800,200) } catch {} }
    if($Request.AutoFocus) {
        # One bounded attempt after Notification Center has started dismissing.
        # Ordinary completion cards never request foreground activation.
        $timer=New-Object Windows.Threading.DispatcherTimer
        $timer.Interval=[timespan]::FromMilliseconds(600)
        $script:popupAutoFocusTimers[$timer]=$popup
        $timer.Add_Tick({ param($sender,$event)
            $sender.Stop()
            $card=$script:popupAutoFocusTimers[$sender]
            $script:popupAutoFocusTimers.Remove($sender)
            if(-not $card.IsVisible -or $card.Tag.Busy){return}
            $activated=$card.Activate()
            Write-PopupLog "saved notification auto-activate sid=$($card.Tag.Request.SessionId) popupActivated=$activated"
            if($activated){Activate-AgentCompletionPopup $card}
        })
        $timer.Start()
    }
}
function Update-AgentCompletionPopups {
    foreach($request in @(Read-AgentPopupRequests)) {
        try { Add-AgentRecentCompletion $request; Show-AgentCompletionPopup $request } catch { Write-PopupLog "show failed: $($_.Exception.Message)" }
    }
    foreach($popup in @($script:completionPopups.ToArray())) {
        if (-not $popup.IsMouseOver -and -not $popup.Tag.Busy -and [datetime]::UtcNow -gt $popup.Tag.Deadline) {
            Write-PopupLog "expired sid=$($popup.Tag.Request.SessionId)"
            Close-AgentCompletionPopup $popup
        }
    }
}
