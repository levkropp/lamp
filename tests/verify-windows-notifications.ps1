param([string]$OutputDirectory,[switch]$Playback)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$out=if($OutputDirectory){$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)}else{Join-Path $root 'bin'}
$vs=& "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdk="${env:ProgramFiles(x86)}\Windows Kits\10"
$v=(Get-ChildItem -LiteralPath (Join-Path $sdk 'Include') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
& "$msvc\bin\Hostx64\x64\cl.exe" /nologo /O2 /MD "/I$msvc\include" "/I$sdk\Include\$v\ucrt" "/I$sdk\Include\$v\um" "/I$sdk\Include\$v\shared" "/Fo$out\verify-windows-notifications.obj" "/Fe$out\verify-windows-notifications.exe" "$PSScriptRoot\verify-windows-notifications.c" "$out\obj\output_notifications.obj" /link "/libpath:$msvc\lib\x64" "/libpath:$sdk\Lib\$v\ucrt\x64" "/libpath:$sdk\Lib\$v\um\x64" kernel32.lib uuid.lib ole32.lib
if($LASTEXITCODE){throw 'Notification oracle compilation failed'}
$result=& "$out\verify-windows-notifications.exe"
if($LASTEXITCODE){throw 'Native Windows notification verification failed'}
$report=$result | ConvertFrom-Json
$report | Add-Member -NotePropertyName scope -NotePropertyValue 'Native callback ABI, render/console filtering, coalescing, explicit selection, failure cleanup, registration ownership and concurrent event teardown; mock server plus 32 real MMDevice registrations, no physical output switches or system selection changes.'
$report | Add-Member -NotePropertyName platform -NotePropertyValue ([Environment]::OSVersion.VersionString)
$report | Add-Member -NotePropertyName object_sha256 -NotePropertyValue ((Get-FileHash -LiteralPath "$out\obj\output_notifications.obj").Hash)
foreach($component in @(@('player_object_sha256','obj\player.obj'),@('cli_sha256','lamp-cli.exe'),@('gui_sha256','lamp.exe'))){
 $report | Add-Member -NotePropertyName $component[0] -NotePropertyValue ((Get-FileHash -LiteralPath (Join-Path $out $component[1])).Hash)
}
$playbackChecks=@()
if($Playback){
 $scratch=Join-Path $PSScriptRoot 'generated\default-output'
 New-Item -ItemType Directory -Force -Path $scratch | Out-Null
 foreach($spec in @(@('wav','wav','pcm_s16le',48000,'stereo'),@('flac','flac','flac',44100,'5.1'),@('mp3','mp3','libmp3lame',44100,'stereo'),@('vorbis','ogg','libvorbis',48000,'7.1'),@('opus','opus','libopus',48000,'5.1'),@('aiff','aiff','pcm_f64be',48000,'5.1'))){
  $path=Join-Path $scratch ("silence-"+$spec[0]+'.'+$spec[1])
  & ffmpeg -hide_banner -loglevel error -y -f lavfi -i "anullsrc=r=$($spec[3]):cl=$($spec[4]):d=30" -c:a $spec[2] $path
  if($LASTEXITCODE){throw "Notification playback fixture failed: $($spec[0])"}
  $message=& "$out\engine-probe.exe" $path
  if($LASTEXITCODE -or ($message -join "`n") -notmatch 'Default-device callback: paused and active restart passed'){throw "Default-device playback verification failed (build with --probe-default-device): $($spec[0])"}
  $playbackChecks+=[pscustomobject]@{codec=$spec[0];rate=$spec[3];layout=$spec[4];result='passed';scope='Silent native WASAPI; synthetic callback into this process, paused/active heard-position restart and pending user-command preservation; pause/resume/stop/reopen/seek/cancel regression; system default unchanged.'}
  Write-Output "$($spec[0]): paused/active default notification lifecycle passed"
 }
 $report | Add-Member -NotePropertyName engine_probe_sha256 -NotePropertyValue ((Get-FileHash -LiteralPath "$out\engine-probe.exe").Hash)
}
$report | Add-Member -NotePropertyName playback_checks -NotePropertyValue $playbackChecks
[IO.File]::WriteAllText((Join-Path $out 'windows-notifications-verification.json'),($report | ConvertTo-Json)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
$result
