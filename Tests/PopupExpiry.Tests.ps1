$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'agent-sessions.ps1')
$script:agentPopupQueue=Join-Path $env:TEMP ('unused-popup-queue-'+[guid]::NewGuid().ToString('N'))
Initialize-AgentNative
Show-AgentCompletionPopup ([pscustomobject]@{Provider='Codex';SessionId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';Name='Auto-dismiss test';Snippet='This quiet test card should disappear after five seconds.';Silent=$true})
$popup=$script:completionPopups[0]
if(($popup.Tag.Deadline-$popup.Tag.Created).TotalSeconds -gt 6){$popup.Close();throw 'Popup timeout still exceeds six seconds'}
$frame=New-Object Windows.Threading.DispatcherFrame
$timer=New-Object Windows.Threading.DispatcherTimer
$timer.Interval=[timespan]::FromMilliseconds(100)
$stopAt=[datetime]::UtcNow.AddSeconds(8)
$timer.Add_Tick({
    Update-AgentCompletionPopups
    if(-not $popup.IsVisible -or [datetime]::UtcNow -gt $stopAt){$timer.Stop();$frame.Continue=$false}
})
$timer.Start()
[Windows.Threading.Dispatcher]::PushFrame($frame)
if($popup.IsVisible){$popup.Close();throw 'Popup failed to expire without a click'}
'PASS popup automatically closes after five seconds without a click'
