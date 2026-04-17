$ErrorActionPreference = "SilentlyContinue"

$raw = [Console]::In.ReadToEnd()
$data = $null
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }

$sessionId = $data.session_id
if (-not $sessionId) { exit 0 }

$dir = Join-Path $env:USERPROFILE ".claude\session-windows"
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

# Status -> running
$statusFile = Join-Path $dir "$sessionId.status"
Set-Content -LiteralPath $statusFile -Value "running" -Encoding ASCII

# Cache the prompt snippet so the picker can show it without parsing the transcript
$prompt = $data.prompt
if ($prompt) {
    $snip = ($prompt -replace '\s+', ' ').Trim()
    if ($snip -match '^([^\.\!\?\n]+)') { $snip = $matches[1].Trim() }
    if ($snip.Length -gt 100) { $snip = $snip.Substring(0, 97) + "..." }
    $snipFile = Join-Path $dir "$sessionId.snippet"
    Set-Content -LiteralPath $snipFile -Value $snip -Encoding UTF8
}
