$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'agent-sessions.ps1')
function Assert($value,[string]$message) { if(-not $value){throw $message} }
function Test-AgentNativeNotificationService {return $false}
function New-AgentToastContent { param($Provider,$SessionId,$Title,$Body,$ButtonText) [pscustomobject]@{Provider=$Provider;SessionId=$SessionId;Title=$Title;Body=$Body;ButtonText=$ButtonText} }
function Submit-BTNotification { [CmdletBinding()]param($Content,$UniqueIdentifier,[switch]$SuppressPopup) $script:saved=[pscustomobject]@{Content=$Content;Id=$UniqueIdentifier;SilentBanner=[bool]$SuppressPopup} }
Save-AgentNotificationHistory -Provider Codex -SessionId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -Name Project -Snippet ('x'*70000)
Assert $script:saved.SilentBanner 'history creates a second banner'
Assert ($script:saved.Content.ButtonText -eq 'Open session popup') 'history promises unsupported direct focus'
Assert ($script:saved.Content.Body.Length -lt 500) 'history message is unbounded'
Assert ($script:saved.Id -eq 'Codex-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') 'history routes wrong session'
'PASS history stores bounded session entry without duplicate banner'
