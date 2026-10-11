$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'agent-sessions.ps1')
$module=Join-Path (Split-Path $PSScriptRoot -Parent) 'completion-popups.ps1'
if (Test-Path $module) { . $module }
function Assert($value,[string]$message) { if (-not $value) { throw $message } }
$testDir=Join-Path $env:TEMP ('agent-popup-tests-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDir | Out-Null
try {
    $bad=$false
    try { Write-AgentPopupRequest -Provider Codex -SessionId '../../bad' -Name Test -Directory $testDir } catch { $bad=$true }
    Assert $bad 'invalid target accepted'
    $name='Project <review> & "quotes"'
    Write-AgentPopupRequest -Provider Codex -SessionId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -Name $name -Snippet 'Completed the work.' -Silent -Directory $testDir
    $requests=@(Read-AgentPopupRequests -Directory $testDir)
    Assert ($requests.Count -eq 1) 'request was not delivered exactly once'
    Assert ($requests[0].Name -eq $name) 'display text was damaged'
    Assert ($requests[0].Silent -eq $true) 'silent test request would beep'
    Assert (@(Read-AgentPopupRequests -Directory $testDir).Count -eq 0) 'request replayed'
    Write-Output 'PASS valid popup request is delivered once with literal text and silent flag'
    $stale=@{Provider='Codex';SessionId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';CreatedUtc=[datetime]::UtcNow.AddHours(-1).ToString('o')}
    $stale | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $testDir 'old.json')
    Assert (@(Read-AgentPopupRequests -Directory $testDir).Count -eq 0) 'old popup replayed'
    Write-Output 'PASS stale popup requests do not replay'
    $view=Get-AgentPopupView -Request ([pscustomobject]@{Provider='Codex';Name=$name;Snippet=('x'*600)})
    Assert ($view.Title -eq 'Codex finished') 'missing completion title'
    Assert ($view.Name -eq $name) 'markup-like text interpreted'
    Assert ($view.Preview.Length -le 240) 'preview exceeds readable card size'
    Write-Output 'PASS popup presentation preserves project and bounds preview length'
    $script:recentAgentCompletions=@()
    foreach($i in 1..25) {
        Add-AgentRecentCompletion ([pscustomobject]@{Provider='Codex';SessionId=('{0:x8}-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -f $i);Name="Session $i";Snippet='Done'})
    }
    Assert ($script:recentAgentCompletions.Count -eq 20) 'recent completions are unbounded'
    Assert ($script:recentAgentCompletions[0].Name -eq 'Session 25') 'recent completions are not newest first'
    Add-AgentRecentCompletion ([pscustomobject]@{Provider='Codex';SessionId='00000019-aaaa-aaaa-aaaa-aaaaaaaaaaaa';Name='Updated';Snippet='Again'})
    Assert ($script:recentAgentCompletions.Count -eq 20) 'same session duplicated in tray'
    Assert ($script:recentAgentCompletions[0].Name -eq 'Updated') 'latest completion did not replace previous'
    Write-Output 'PASS tray history keeps newest twenty unique sessions'
    $state=Get-CodexTurnState @('{"type":"event_msg","payload":{"type":"user_message","message":"Question"}}','{"type":"event_msg","timestamp":"now","payload":{"type":"task_complete","turn_id":"1","last_agent_message":"Answer"}}')
    Assert ($state.Snippet -eq 'Answer') 'completion preview shows prompt instead of answer'
    Write-Output 'PASS completion preview uses assistant result'
    Write-AgentPopupRequest -Provider Codex -SessionId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -Name $name -Snippet ('x'*70000) -Directory $testDir
    Assert (@(Read-AgentPopupRequests -Directory $testDir).Count -eq 1) 'long assistant response silently lost completion notification'
    Write-Output 'PASS oversized assistant result still delivers completion'
    Write-AgentPopupRequest -Provider Codex -SessionId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -Name $name -Silent -AutoFocus -Directory $testDir
    $activation=@(Read-AgentPopupRequests -Directory $testDir)[0]
    Assert ($activation.AutoFocus -eq $true) 'saved notification lost focus intent'
    Write-Output 'PASS user activation request carries explicit focus intent'
} finally { Remove-Item -LiteralPath $testDir -Recurse -Force }
