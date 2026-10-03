$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdk=(Get-ChildItem -LiteralPath (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Lib') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$tools=Join-Path $msvc 'bin\Hostx64\x64'
& (Join-Path $tools 'ml64.exe') /nologo /c "/Fo$root\bin\engine-probe.obj" (Join-Path $PSScriptRoot 'engine-probe.asm')
if($LASTEXITCODE){throw 'Probe assembly failed'}
$objects=@('engine-probe','player','decoder','mp3','mp3_synthesis','ogg','vorbis','vorbis_transform') | ForEach-Object {Join-Path $root "bin\$_.obj"}
& (Join-Path $tools 'link.exe') /nologo /entry:probe_start /subsystem:console /nodefaultlib "/out:$root\bin\engine-probe.exe" "/libpath:$sdk\um\x64" @objects kernel32.lib shell32.lib ole32.lib avrt.lib
if($LASTEXITCODE){throw 'Probe link failed'}
$scratch=Join-Path $PSScriptRoot 'generated'
$report=@()
foreach($codec in @('wav','flac','mp3','vorbis')) {
    $extension=if($codec -eq 'vorbis'){'ogg'}else{$codec}
    $encoding=switch($codec){'wav'{@('-c:a','pcm_s16le')};'flac'{@('-c:a','flac')};'mp3'{@('-c:a','libmp3lame','-b:a','192k')};'vorbis'{@('-c:a','libvorbis','-q:a','4')}}
    $path=Join-Path $scratch "engine-silence.$extension"
    & ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'anullsrc=r=48000:cl=stereo:d=30' @encoding $path
    if($LASTEXITCODE){throw 'Probe fixture failed'}
    $stats=& (Join-Path $root 'bin\engine-probe.exe') $path
    if($LASTEXITCODE){throw "Engine lifecycle failed $codec $stats"}
    $report+=[pscustomobject]@{codec=$codec;result='passed';tests=@('playback','pause','resume','stop','reopen','seek','paused seek');stats="$stats"}
    Write-Output "$codec $stats"
}
$report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $root 'bin\engine-verification.json') -Encoding utf8
