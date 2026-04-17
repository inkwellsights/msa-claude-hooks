$ErrorActionPreference = "Stop"

$ShortcutName = "Claude Session Picker"
$ShortcutPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$ShortcutName.lnk"
$PickerScript = Join-Path $env:USERPROFILE ".claude\hooks\session-picker.ps1"

if (-not (Test-Path $PickerScript)) {
    Write-Error "Picker script not found: $PickerScript"
    exit 1
}

$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut($ShortcutPath)
$sc.TargetPath   = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
$sc.Arguments    = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PickerScript`""
$sc.WorkingDirectory = Join-Path $env:USERPROFILE ".claude\hooks"
$sc.IconLocation = "$env:WINDIR\System32\imageres.dll,-27"
$sc.WindowStyle  = 7  # Minimized (won't actually show since -WindowStyle Hidden handles PS)
$sc.Hotkey       = "CTRL+ALT+C"
$sc.Save()

Write-Host "Created shortcut: $ShortcutPath" -ForegroundColor Green
Write-Host "Hotkey: Ctrl+Alt+C" -ForegroundColor Green
Write-Host ""
Write-Host "Press Ctrl+Alt+C anywhere in Windows to open the session picker."
Write-Host "If Ctrl+Alt+C conflicts with another app, edit the shortcut's Properties -> Shortcut key."
