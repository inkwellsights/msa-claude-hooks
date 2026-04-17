$ErrorActionPreference = "SilentlyContinue"

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

# Last user-typed prompt from transcript (string-content user messages only;
# array-content ones are tool_results/skill outputs, not user input)
$lastPrompt = ""
if ($data -and $data.transcript_path -and (Test-Path $data.transcript_path)) {
    $lines = Get-Content -LiteralPath $data.transcript_path
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        try {
            $entry = $lines[$i] | ConvertFrom-Json
            if ($entry.type -eq "user" -and $entry.message -and ($entry.message.content -is [string])) {
                $lastPrompt = $entry.message.content
                break
            }
        } catch { }
    }
}

# Collapse whitespace
$lastPrompt = ($lastPrompt -replace '\s+', ' ').Trim()

# Derive "main idea": first sentence (stops at . ! ? or newline), truncated to 60 chars
$mainIdea = $lastPrompt
if ($mainIdea -match '^([^\.\!\?\n]+)') { $mainIdea = $matches[1].Trim() }
if ($mainIdea.Length -gt 60) { $mainIdea = $mainIdea.Substring(0, 57) + "..." }
if (-not $mainIdea) { $mainIdea = "Session complete" }

# Update status sidecar so the picker shows the orange "done" dot
if ($sessionId) {
    $statusDir = Join-Path $env:USERPROFILE ".claude\session-windows"
    if (-not (Test-Path -LiteralPath $statusDir)) { New-Item -ItemType Directory -Path $statusDir -Force | Out-Null }
    $statusFile = Join-Path $statusDir "$sessionId.status"
    Set-Content -LiteralPath $statusFile -Value "done" -Encoding ASCII -ErrorAction SilentlyContinue
}

# Beep
try { [console]::beep(800, 200) } catch { }

# Toast via BurntToast (handles AppId registration + click activation properly)
try { Import-Module BurntToast -ErrorAction Stop } catch { exit 0 }

$bodyText = "$projectName - done"

$silentAudio = New-BTAudio -Silent

if ($sessionId) {
    $encodedId = [System.Uri]::EscapeDataString($sessionId)
    $launchUri = "clauderecall://$encodedId"

    # Toast-body click -> protocol activation
    $t1 = New-BTText -Text $mainIdea
    $t2 = New-BTText -Text $bodyText
    $binding = New-BTBinding -Children $t1, $t2
    $visual  = New-BTVisual -BindingGeneric $binding

    # Also include a visible button as belt-and-suspenders (some Windows configs route
    # button clicks even when body clicks don't)
    $btn    = New-BTButton -Content "Switch" -Arguments $launchUri -ActivationType Protocol
    $action = New-BTAction -Buttons $btn

    $content = New-BTContent -Visual $visual -Actions $action -Audio $silentAudio -Launch $launchUri -ActivationType Protocol
    Submit-BTNotification -Content $content
} else {
    New-BurntToastNotification -Text $mainIdea, $bodyText -Silent
}
