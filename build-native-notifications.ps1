$ErrorActionPreference='Stop'
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$toolkit=Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Modules\BurntToast\1.1.0\lib\Microsoft.Toolkit.Uwp.Notifications\net461\Microsoft.Toolkit.Uwp.Notifications.dll'
$foundation='C:\Program Files (x86)\Windows Kits\10\References\10.0.19041.0\Windows.Foundation.FoundationContract\4.0.0.0\Windows.Foundation.FoundationContract.winmd'
$universal='C:\Program Files (x86)\Windows Kits\10\References\10.0.19041.0\Windows.Foundation.UniversalApiContract\10.0.0.0\Windows.Foundation.UniversalApiContract.winmd'
$framework=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$exe=Join-Path $PSScriptRoot 'AgentNotifications.exe'
& $compiler /nologo /target:winexe /optimize+ "/out:$exe" "/reference:$toolkit" "/reference:$foundation" "/reference:$universal" "/reference:$framework\System.Runtime.dll" "/reference:$framework\System.Runtime.WindowsRuntime.dll" /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll (Join-Path $PSScriptRoot 'AgentNotifications.cs')
if($LASTEXITCODE -ne 0){throw 'Native notification host failed to compile'}
Copy-Item -LiteralPath $toolkit -Destination (Join-Path $PSScriptRoot 'Microsoft.Toolkit.Uwp.Notifications.dll') -Force
'Native notification host built'
