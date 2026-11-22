param([string]$OutputDirectory,[switch]$Playback,[ValidateRange(0,192000)][int]$UnsupportedRate=0)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$out=if($OutputDirectory){$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)}else{Join-Path $root 'bin'}
$vs=& "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdk="${env:ProgramFiles(x86)}\Windows Kits\10"
$v=(Get-ChildItem -LiteralPath (Join-Path $sdk 'Include') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
$objects=@(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.s' -File | ForEach-Object {Join-Path "$out\obj" ($_.BaseName+'.obj')})
$objects+=@('platform','player','output_notifications','output_format','output_exclusive','accessibility') | ForEach-Object {Join-Path "$out\obj" ($_+'.obj')}
$objects+=Join-Path $out 'ui-output-probe.obj'
$libraries=@(Get-ChildItem -LiteralPath "$out\obj" -Filter '*.lib' -File | Where-Object {$_.BaseName -ne 'lamp-test'} | ForEach-Object FullName)
& "$msvc\bin\Hostx64\x64\cl.exe" /nologo /O2 /MD "/I$msvc\include" "/I$sdk\Include\$v\ucrt" "/I$sdk\Include\$v\um" "/I$sdk\Include\$v\shared" "/Fo$out\verify-windows-ui-output.obj" "/Fe$out\verify-windows-ui-output.exe" "$PSScriptRoot\verify-windows-ui-output.c" @objects @libraries /link "/libpath:$msvc\lib\x64" "/libpath:$sdk\Lib\$v\ucrt\x64" "/libpath:$sdk\Lib\$v\um\x64" kernel32.lib user32.lib
if($LASTEXITCODE){throw 'UI output oracle compilation failed'}
if($Playback){
 $scratch=Join-Path $PSScriptRoot 'generated\ui-output'
 New-Item -ItemType Directory -Force -Path $scratch | Out-Null
 $path=Join-Path $scratch 'silent-44100-5.1.flac'
 & ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'anullsrc=r=44100:cl=5.1:d=30' -c:a flac $path
 if($LASTEXITCODE){throw 'Silent UI output fixture generation failed'}
 $result=& "$out\verify-windows-ui-output.exe" $path $UnsupportedRate
}else{$result=& "$out\verify-windows-ui-output.exe"}
if($LASTEXITCODE){throw 'UI output verification failed'}
$result
$report=$result[-1] | ConvertFrom-Json
$report | Add-Member -NotePropertyName scope -NotePropertyValue 'Native hidden Win32 menu checks, staged settings and immutable worker ownership, pause-preserving output restarts, mode-specific error hints. Optional silent native shipping-window shared/exclusive/rate/device/default-notification lifecycle and unsupported-rate paused recovery; no visible test window, desktop input or system default changes.'
$report | Add-Member -NotePropertyName platform -NotePropertyValue ([Environment]::OSVersion.VersionString)
$report | Add-Member -NotePropertyName recorded_utc -NotePropertyValue ([DateTime]::UtcNow.ToString('o'))
$report | Add-Member -NotePropertyName msvc -NotePropertyValue (Split-Path $msvc -Leaf)
$report | Add-Member -NotePropertyName windows_sdk -NotePropertyValue $v
if($Playback){$report | Add-Member -NotePropertyName fixture -NotePropertyValue ([ordered]@{name='silent-44100-5.1.flac';source_rate=44100;source_layout='5.1';duration_seconds=30;sha256=(Get-FileHash -LiteralPath $path).Hash})}
foreach($file in @('src/win/ui.s','src/win/ui_output.inc','src/win/ui_menu.inc','src/win/ui_queue.inc','src/win/ui_tracks.inc','src/win/ui_draw.inc','src/win/player.s','tests/ui-output-probe.s','tests/verify-windows-ui-output.c','tests/verify-windows-ui-output.ps1','tools/build-windows.py')){
 if(-not $report.PSObject.Properties['sources']){$report | Add-Member -NotePropertyName sources -NotePropertyValue ([ordered]@{})}
 $report.sources[$file]=(Get-FileHash -LiteralPath (Join-Path $root $file)).Hash
}
$report | Add-Member -NotePropertyName gui_sha256 -NotePropertyValue ((Get-FileHash -LiteralPath "$out\lamp.exe").Hash)
$report | Add-Member -NotePropertyName oracle_sha256 -NotePropertyValue ((Get-FileHash -LiteralPath "$out\verify-windows-ui-output.exe").Hash)
[IO.File]::WriteAllText((Join-Path $out 'windows-ui-output-verification.json'),($report | ConvertTo-Json -Depth 8)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
