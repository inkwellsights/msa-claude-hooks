$ErrorActionPreference = "SilentlyContinue"
. (Join-Path $PSScriptRoot 'agent-sessions.ps1')

# Read Stop hook JSON from stdin
$raw = [Console]::In.ReadToEnd()
$data = $null
try { $data = $raw | ConvertFrom-Json } catch { }

$sessionId = if ($data) { $data.session_id } else { $null }

# Project name from cwd
$projectName = "Claude Code"
if ($data -and $data.cwd) {
    $projectName = Split-Path -Leaf $data.cwd
}

# Latest assistant answer, falling back to the latest typed prompt.
$lastPrompt = ""
if ($data -and $data.transcript_path -and (Test-Path $data.transcript_path)) {
    $lines = @(Read-AgentTail -Path $data.transcript_path)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        try {
            $entry = $lines[$i] | ConvertFrom-Json
            if ($entry.type -eq "assistant" -and $entry.message) {
                $answer = @($entry.message.content | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join " "
                if ($answer) { $lastPrompt=$answer; break }
            }
            if ($entry.type -eq "user" -and $entry.message -and ($entry.message.content -is [string])) {
                $lastPrompt = $entry.message.content
                break
            }
        } catch { }
    }
}

# Collapse whitespace
$lastPrompt = ($lastPrompt -replace '\s+', ' ').Trim()

# Update status sidecar so the picker shows the orange "done" dot
if ($sessionId) {
    $statusDir = Join-Path $env:USERPROFILE ".claude\session-windows"
    if (-not (Test-Path -LiteralPath $statusDir)) { New-Item -ItemType Directory -Path $statusDir -Force | Out-Null }
    $statusFile = Join-Path $statusDir "$sessionId.status"
    Set-Content -LiteralPath $statusFile -Value "done" -Encoding ASCII -ErrorAction SilentlyContinue
}

# The resident picker owns completion cards and plays the optional sound once.
if ($sessionId -and (ConvertFrom-AgentRecallUri "clauderecall://Claude/$sessionId")) {
    Send-AgentNotification -Provider Claude -SessionId $sessionId -Name $projectName -Snippet $lastPrompt
}
