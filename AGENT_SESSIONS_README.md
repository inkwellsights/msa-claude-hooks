# Codex and Claude session picker

Press **Alt + backtick** to show live Codex and Claude terminal sessions. Arrow keys and Enter, numbers 1-9, and double-click switch to a session. Escape dismisses the picker.

## Completion alerts and tray menu

The resident service now shows its own dark completion cards at the lower-right. Clicking a card switches to the exact live session. The card receives the mouse click itself and hands focus to the terminal before closing. Physical clicks have been confirmed for Barcode and the current session, with foreground focus retained after two seconds.

Right-click the **Codex and Claude Sessions** tray icon beside the clock, or inside Windows' hidden-icons area, then choose **Recent completions**. The menu keeps the newest completion from up to twenty sessions while the service runs. Selecting a session creates a silent card and attempts to focus its terminal. If Windows blocks that attempt, the card remains available for a direct click. Closed sessions show an explanation on the card. The user confirmed physical tray selection brings the correct terminal forward.

Choose **Settings > Completion sound** in the picker, or **Completion sound** on the tray menu, to enable or disable the beep. The choice persists in `agent-settings.json`. Each new card plays the optional beep once; reopening one from the tray is silent.

At most three cards appear together. Cards expire after five seconds. Hovering pauses dismissal, and leaving restarts the five-second countdown. Dismissal and expiry leave the recent-completions tray entry available. Restarting the service clears that menu and baselines existing Codex completions without replaying old alerts.

## Discovery and completion delivery

Codex CLI terminals in Alacritty and mintty are discovered through their process ancestry. Resumed sessions use their exact ID; fresh sessions use an unambiguous transcript startup match. Ambiguous terminals remain selectable in the picker but cannot receive routed completion alerts. Codex app-server processes are excluded. The existing Codex `notify` integration is preserved.

Codex transcripts are checked every three seconds while their CLI processes are live. Orange dots indicate completed turns; green spinners indicate running turns. Claude uses its existing lifecycle hooks. Assistant results supply completion previews, bounded before queue serialization so long responses do not lose alerts.

The shared notification function writes an atomic request to `popup-queue` when `agent-monitor-ready.json` identifies a live popup-enabled daemon. Only the resident UI consumes these requests and plays their sound. The separate Codex Stop hook defers only after that daemon has baselined its exact session, preventing duplicate alerts. If the daemon is unavailable, shared delivery falls back to the previous native toast.

The existing Startup shortcut starts `session-picker-daemon.ps1`. Popup display and focus evidence are recorded in `popup.log`; picker activity is in `daemon.log`.

## Saved Windows notification activation

New saved entries are owned by **Agent Sessions**, through the resident `AgentNotifications.exe` host and the installed Windows Community Toolkit. Body and button use native foreground activation arguments (`provider` and exact session UUID), not the old protocol handoff. Its COM callback resolves a fresh session snapshot, verifies the terminal HWND/PID and agent process start time, and synchronously requests terminal focus. No custom card is opened by this path. Retained focus is logged after two seconds in `native-notifications.log`.

The daemon starts this host and atomically refreshes `native-session-targets.json` each completion poll. Shared delivery writes bounded requests to `native-toast-queue`; the host saves silent history entries with `SuppressPopup`, avoiding duplicate banners and beeps. The helper is built from `AgentNotifications.cs` using `build-native-notifications.ps1`, the existing Toolkit net461 library, and installed Windows SDK metadata.

Native history storage and exact activation arguments have been read back through Windows' history API. The user confirmed the latest one-click notification test works on this machine. Other Windows installations still require a physical notification click test.

Old entries under the previous PowerShell/BurntToast sender retain the protocol path and may reopen a card requiring a second click. That path's popup-activation probe failed a physical click: Windows still owned the foreground and the popup activation returned false, even when the handler logged a successful permission grant. Native direct URI tests are insufficient evidence for saved notification clicks.

## Installation dependencies

Install this checkout at `~/.claude/hooks`. The native notification build currently expects BurntToast 1.1.0 in the user's WindowsPowerShell modules directory, the .NET Framework compiler, and Windows SDK 10.0.19041.0 metadata. Run `build-native-notifications.ps1` to create the notification host and copy its Toolkit dependency, then `install-protocol.ps1` to build and register the fallback launcher. Run `install-picker-daemon.ps1` to install startup and launch the service. Generated executables, dependency DLLs, runtime data, and local settings are excluded from Git.

The optional existing Codex Stop-hook integration is preserved in `codex-hooks/notify-done.ps1`. Copy it to `~/.codex/hooks/notify-done.ps1` when that hook is already configured. It defers to the live daemon for sessions the daemon has baselined. No Codex notification configuration is changed by this checkout.

## Verification commands

Run `Tests/AgentSessions.Tests.ps1`, `Tests/CompletionPopups.Tests.ps1`, and `Tests/NotificationHistory.Tests.ps1`, and `Tests/NativeToast.Tests.ps1` under Windows PowerShell 5.1 and PowerShell 7. The checks cover exact session discovery, ambiguity rejection, persistent sound settings, completion lifecycle and deduplication, stale window mappings, protocol validation, atomic popup delivery, stale request rejection, bounded previews, unique recent-session ordering, and oversized response delivery.

`Tests/Test-NotificationActivation.ps1` tests direct native URI delivery and retained focus only. Physical popup and tray clicks must be tested separately.

Backups before custom popups are in `backups/20261011-123625-custom-popup`. The original picker backup is `backups/20261010-075843`.
