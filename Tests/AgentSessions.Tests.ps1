$ErrorActionPreference = 'Stop'
$common = Join-Path (Split-Path $PSScriptRoot -Parent) 'agent-sessions.ps1'
$failures = 0
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Output "PASS $Name" } catch { $script:failures++; Write-Output "FAIL ${Name}: $_" }
}
if (Test-Path $common) { . $common }
function Assert($Value, [string]$Message) { if (-not $Value) { throw $Message } }
$start = [datetime]'2026-10-10T01:51:29Z'
$metas = @(
    [pscustomobject]@{ Id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; Started=$start.AddSeconds(6); Source='cli'; Cwd='C:\test'; Path='a.jsonl' },
    [pscustomobject]@{ Id='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'; Started=$start.AddSeconds(7); Source='subagent'; Cwd='C:\test'; Path='b.jsonl' }
)
Check 'fresh CLI maps to its startup transcript, excluding subagents' {
    $m = Resolve-CodexMetadata -CommandLine 'codex.exe --yolo --no-daemon' -Started $start -Metadata $metas
    Assert ($m.Id -eq 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') 'wrong transcript'
}
Check 'resume selects exact ID even when transcript is older' {
    $m = Resolve-CodexMetadata -CommandLine 'codex.exe resume bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' -Started $start.AddDays(1) -Metadata $metas
    Assert ($m.Id -eq 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') 'resume ID ignored'
}
Check 'ambiguous startup does not focus an arbitrary session' {
    $extra = [pscustomobject]@{ Id='cccccccc-cccc-cccc-cccc-cccccccccccc'; Started=$start.AddSeconds(8); Source='cli'; Cwd='C:\test'; Path='c.jsonl' }
    $m = Resolve-CodexMetadata -CommandLine 'codex.exe' -Started $start -Metadata ($metas + $extra)
    Assert ($null -eq $m) 'ambiguous mapping accepted'
}
Check 'sound disabled persists across reads' {
    $path = Join-Path $env:TEMP ('agent-sound-test-' + [guid]::NewGuid() + '.json')
    try { Set-AgentSound -Enabled $false -Path $path; Assert (-not (Get-AgentSettings -Path $path).SoundEnabled) 'sound remains enabled' }
    finally { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
}
Check 'only actual completion events mark the turn done' {
    $lines = @('{"type":"event_msg","timestamp":"2026-10-10T00:00:00Z","payload":{"type":"task_started","turn_id":"1"}}', '{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"commentary"}}')
    Assert ((Get-CodexTurnState -Lines $lines).Status -eq 'running') 'commentary marked complete'
    $lines += '{"type":"event_msg","timestamp":"2026-10-10T00:01:00Z","payload":{"type":"task_complete","turn_id":"1"}}'
    Assert ((Get-CodexTurnState -Lines $lines).Status -eq 'done') 'completion missed'
}
Check 'protocol rejects malformed or path traversal IDs' {
    Assert ($null -eq (ConvertFrom-AgentRecallUri 'clauderecall://../../bad')) 'path traversal accepted'
    Assert ((ConvertFrom-AgentRecallUri 'clauderecall://codex/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa').Provider -eq 'Codex') 'Codex protocol rejected'
    Assert ((ConvertFrom-AgentRecallUri 'clauderecall://aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/').Provider -eq 'Claude') 'legacy protocol rejected'
}
Check 'a long turn still shows running when its start is beyond the tail buffer' {
    $path = Join-Path $env:TEMP ('agent-state-test-' + [guid]::NewGuid() + '.jsonl')
    try {
        $startLine = '{"type":"event_msg","payload":{"type":"task_started","turn_id":"long"}}'
        $noise = '{"type":"response_item","payload":{"type":"message","text":"' + ('x' * 140000) + '"}}'
        [IO.File]::WriteAllText($path, $startLine + "`n" + $noise + "`n")
        Assert ((Get-CodexFileState -Path $path).Status -eq 'running') 'long active turn lost its running status'
    } finally { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
}
Check 'completion monitor baselines history and emits one alert per new completed turn' {
    & {
        $path = Join-Path $env:TEMP ('agent-monitor-test-' + [guid]::NewGuid() + '.jsonl')
        $script:agentMonitorReadyPath = $path + '.ready.json'
        $script:testSession = [pscustomobject]@{ Provider='Codex'; TranscriptPath=$path; SessionId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; Name='Test window' }
        $script:codexStates=@{}; $script:codexAcknowledged=@{}; $script:notifications=@()
        # Replace only OS discovery and audible/desktop output at their boundaries.
        function Get-AgentSessions { return @($script:testSession) }
        function Write-AgentNativeSessionSnapshot { param($Sessions) }
        function Log { param([string]$m) }
        function Send-AgentNotification { param($Provider,$SessionId,$Name,$Snippet); $script:notifications += "$Provider|$SessionId" }
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'session-picker-daemon.ps1'),[ref]$tokens,[ref]$errors)
        $definition=$ast.Find({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Update-CodexCompletions' },$true)
        . ([scriptblock]::Create($definition.Extent.Text))
        try {
            [IO.File]::WriteAllText($path, '{"type":"event_msg","timestamp":"old","payload":{"type":"task_complete","turn_id":"old"}}' + "`n")
            Update-CodexCompletions
            Assert ($script:notifications.Count -eq 0) 'old alert replayed at startup'
            [IO.File]::AppendAllText($path, '{"type":"event_msg","payload":{"type":"task_started","turn_id":"new"}}' + "`n")
            [IO.File]::AppendAllText($path, '{"type":"response_item","payload":{"text":"' + ('x' * 140000) + '"}}' + "`n")
            Update-CodexCompletions
            Assert ($script:codexStates[$script:testSession.SessionId].Status -eq 'running') 'new turn not running'
            [IO.File]::AppendAllText($path, '{"type":"event_msg","timestamp":"new","payload":{"type":"task_complete","turn_id":"new"}}' + "`n")
            Update-CodexCompletions; Update-CodexCompletions
            Assert ($script:notifications.Count -eq 1) 'completion missing or duplicated'
            Assert ($script:notifications[0] -eq 'Codex|aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') 'alert addressed wrong session'
        } finally { Remove-Item -LiteralPath $path,($path+'.ready.json') -ErrorAction SilentlyContinue }
    }
}
Check 'toast body and switch button route to the same session, with Windows audio silent' {
    [xml]$xml=(New-AgentToastContent -Provider Codex -SessionId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -Title 'Test' -Body 'Done').GetContent()
    Assert ($xml.toast.launch -eq 'clauderecall://codex/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') 'wrong toast launch target'
    Assert ($xml.toast.activationType -eq 'protocol') 'body is not a protocol link'
    Assert ($xml.toast.actions.action.arguments -eq 'clauderecall://codex/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') 'button routes elsewhere'
    Assert ($xml.toast.audio.silent -eq 'true') 'Windows audio bypasses the sound setting'
}
Check 'invalid HWND or owner is rejected before activation' {
    Initialize-AgentNative
    Assert (-not [AgentWindows]::Focus(0,12345)) 'invalid window accepted'
    Assert (-not [AgentWindows]::FocusFromNotification(0,12345)) 'notification fallback accepted an invalid window'
}
Check 'a stale Claude mapping does not attach to a replacement agent in the same terminal' {
    $procs = @([pscustomobject]@{ProcessId=10; ParentProcessId=0; Name='alacritty.exe'; CommandLine='alacritty.exe'; CreationDate=$start.AddHours(-1)}, [pscustomobject]@{ProcessId=11; ParentProcessId=10; Name='claude.exe'; CommandLine='claude.exe'; CreationDate=$start})
    $mapping = [pscustomobject]@{pid=10; captured_at=$start.AddMinutes(-1).ToString('o')}
    Assert ($null -eq (Resolve-ClaudeAgentForMapping -Mapping $mapping -Processes $procs)) 'stale session claimed replacement'
    $mapping.captured_at = $start.AddSeconds(3).ToString('o')
    Assert ((Resolve-ClaudeAgentForMapping -Mapping $mapping -Processes $procs).ProcessId -eq 11) 'current Claude rejected'
    Assert ($null -eq (Resolve-ClaudeAgentForMapping -Mapping $mapping -Processes @($procs[0]))) 'empty terminal claimed live'
}
Check 'Codex hook fields route only to their matching live session' {
    $sessions = @([pscustomobject]@{Provider='Codex';SessionId='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'}, [pscustomobject]@{Provider='Codex';SessionId='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'})
    $data = [pscustomobject]@{session_id='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';cwd='C:\same-project'}
    Assert ((Get-CodexHookTarget -Data $data -Sessions $sessions).SessionId -eq 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') 'hook focused a different session'
    $data = [pscustomobject]@{'thread-id'='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'}
    Assert ((Get-CodexHookTarget -Data $data -Sessions $sessions).SessionId -eq 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') 'legacy notify field ignored'
    Assert ($null -eq (Get-CodexHookTarget -Data ([pscustomobject]@{cwd='C:\same-project'}) -Sessions $sessions)) 'unknown session guessed from project'
}
Check 'Stop hook defers only after that live daemon has baselined this session' {
    $ready=[pscustomobject]@{Pid=123;SessionIds=@('known')}
    $daemons=@([pscustomobject]@{ProcessId=123})
    Assert (Test-AgentMonitorOwnsSession -Ready $ready -Daemons $daemons -SessionId 'known') 'ready session did not defer'
    Assert (-not (Test-AgentMonitorOwnsSession -Ready $null -Daemons $daemons -SessionId 'known')) 'startup alert suppressed'
    Assert (-not (Test-AgentMonitorOwnsSession -Ready $ready -Daemons $daemons -SessionId 'new')) 'new session alert suppressed'
    Assert (-not (Test-AgentMonitorOwnsSession -Ready $ready -Daemons @([pscustomobject]@{ProcessId=456}) -SessionId 'known')) 'stale readiness accepted'
}
Check 'native notification launcher rejects command injection and extra arguments before starting a handler' {
    $exe=Join-Path (Split-Path $PSScriptRoot -Parent) 'AgentRecall.exe'
    Assert (Test-Path -LiteralPath $exe) 'native launcher is not built'
    foreach ($arguments in @('"clauderecall://../../bad"', '"clauderecall://codex/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa?command=bad"', '"clauderecall://codex/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" "extra"')) {
        $info=New-Object Diagnostics.ProcessStartInfo($exe,$arguments)
        $info.UseShellExecute=$false; $info.CreateNoWindow=$true
        $process=[Diagnostics.Process]::Start($info)
        try {
            Assert ($process.WaitForExit(5000)) 'invalid URI launcher hung'
            Assert ($process.ExitCode -eq 2) 'invalid URI reached the handler'
        } finally { $process.Dispose() }
    }
}
if ($failures) { throw "$failures tests failed" }
