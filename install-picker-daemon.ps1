$ErrorActionPreference = "Stop"

$DaemonScript     = Join-Path $env:USERPROFILE ".claude\hooks\session-picker-daemon.ps1"
$StartupFolder    = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
$StartupShortcut  = Join-Path $StartupFolder "Claude Session Picker Daemon.lnk"
$OldShortcut      = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Claude Session Picker.lnk"

if (-not (Test-Path $DaemonScript)) {
    Write-Error "Daemon script not found: $DaemonScript"
    exit 1
}

# Step 1: strip hotkey from the old Start Menu shortcut (daemon now owns Ctrl+Alt+C)
if (Test-Path $OldShortcut) {
    try {
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($OldShortcut)
        $sc.Hotkey = ""   # empty = no hotkey
        $sc.Save()
        Write-Host "Removed hotkey from old Start Menu shortcut" -ForegroundColor Yellow
    } catch {
        Write-Host "Warning: couldn't modify old shortcut: $_" -ForegroundColor Yellow
    }
}

# Step 2: create Startup folder shortcut for the daemon
if (-not (Test-Path $StartupFolder)) { New-Item -ItemType Directory -Path $StartupFolder -Force | Out-Null }

$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut($StartupShortcut)
$sc.TargetPath       = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
$sc.Arguments        = "-NoProfile -NoLogo -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$DaemonScript`""
$sc.WorkingDirectory = Join-Path $env:USERPROFILE ".claude\hooks"
$sc.IconLocation     = "$env:WINDIR\System32\imageres.dll,-27"
$sc.WindowStyle      = 7   # minimized
$sc.Save()

Write-Host "Created autostart shortcut: $StartupShortcut" -ForegroundColor Green

# Step 3: kill any existing daemon (release the single-instance mutex), then launch fresh
$existing = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*session-picker-daemon*' }
foreach ($p in $existing) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    Write-Host "Killed existing daemon PID $($p.ProcessId)" -ForegroundColor Yellow
}
Start-Sleep -Milliseconds 500  # let mutex release

$psExe = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
Start-Process -FilePath $psExe `
    -ArgumentList @("-NoProfile", "-NoLogo", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", $DaemonScript) `
    -WindowStyle Hidden

Write-Host "Launched daemon (running in background)" -ForegroundColor Green
Write-Host ""
Write-Host "Press Ctrl+Alt+C anywhere to open the session picker (should be instant)."
Write-Host "Daemon will auto-start on next login from the Startup folder."
