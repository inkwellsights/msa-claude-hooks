$ErrorActionPreference='Stop'
$exe=Join-Path (Split-Path $PSScriptRoot -Parent) 'AgentNotifications.exe'
if(-not(Test-Path -LiteralPath $exe)){throw 'Native notification host not built'}
foreach($case in @(
    @{Provider='Codex';Id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';Code=0},
    @{Provider='Claude';Id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';Code=0},
    @{Provider='Other';Id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';Code=2},
    @{Provider='Codex';Id='../../bad';Code=2}
)) {
    $p=Start-Process -FilePath $exe -ArgumentList @('--validate',$case.Provider,$case.Id) -WindowStyle Hidden -PassThru -Wait
    if($p.ExitCode -ne $case.Code){throw "Invalid native activation validation: $($case.Provider) $($case.Id)"}
}
'PASS native notification activation accepts only exact supported session addresses'
