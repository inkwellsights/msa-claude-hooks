$sessionId = 'test-abc-123'
$launchAttr = ""
if ($sessionId) {
    $encodedId = [System.Uri]::EscapeDataString($sessionId)
    $launchUri = [System.Security.SecurityElement]::Escape("clauderecall://$encodedId")
    $launchAttr = " activationType=`"protocol`" launch=`"$launchUri`""
}
$safeTitle = "test title"
$safeBody = "test body"

$toastXml = @"
<toast$launchAttr>
  <visual>
    <binding template="ToastText02">
      <text id="1">$safeTitle</text>
      <text id="2">$safeBody</text>
    </binding>
  </visual>
</toast>
"@

Write-Host "=== GENERATED XML ==="
Write-Host $toastXml
Write-Host "=== END ==="
