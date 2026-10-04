param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$out=if($OutputDirectory){$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)}else{Join-Path $root 'bin'}
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdk=(Get-ChildItem -LiteralPath (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Lib') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$tools=Join-Path $msvc 'bin\Hostx64\x64'
& (Join-Path $tools 'ml64.exe') /nologo /c "/Fo$out\engine-probe.obj" (Join-Path $PSScriptRoot 'engine-probe.asm')
if($LASTEXITCODE){throw 'Probe assembly failed'}
$objects=@('engine-probe','player','decoder','mp3','mp3_synthesis','ogg','vorbis','vorbis_transform') | ForEach-Object {Join-Path $out "$_.obj"}
$objects+=@(Get-ChildItem -LiteralPath $out -Filter 'opus*.obj' | ForEach-Object {$_.FullName})
& (Join-Path $tools 'link.exe') /nologo /entry:probe_start /subsystem:console /nodefaultlib "/out:$out\engine-probe.exe" "/libpath:$sdk\um\x64" @objects kernel32.lib shell32.lib ole32.lib avrt.lib
if($LASTEXITCODE){throw 'Probe link failed'}
$scratch=Join-Path $PSScriptRoot 'generated'
$report=@()
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
foreach($codec in @('wav','flac','mp3','vorbis','opus')) {
    $extension=if($codec -eq 'vorbis'){'ogg'}else{$codec}
    $encoding=switch($codec){'wav'{@('-c:a','pcm_s16le')};'flac'{@('-c:a','flac')};'mp3'{@('-c:a','libmp3lame','-b:a','192k')};'vorbis'{@('-c:a','libvorbis','-q:a','4')};'opus'{@('-c:a','libopus','-b:a','64k')}}
    $path=Join-Path $scratch "engine-silence.$extension"
    & ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'anullsrc=r=48000:cl=stereo:d=30' @encoding $path
    if($LASTEXITCODE){throw 'Probe fixture failed'}
    $stats=& (Join-Path $out 'engine-probe.exe') $path
    if($LASTEXITCODE){throw "Engine lifecycle failed $codec $stats"}
    $report+=[pscustomobject]@{codec=$codec;result='passed';tests=@('playback','pause','resume','stop','reopen','seek','paused seek','cancelled open');stats="$stats"}
    Write-Output "$codec $stats"
    if($codec -eq 'flac') {
        $indexedPath=Join-Path $scratch 'engine-silence-indexed.flac'
        & node (Join-Path $PSScriptRoot 'seek-fixtures.js') --index-flac $path $indexedPath
        if($LASTEXITCODE){throw 'Indexed engine fixture failed'}
        $stats=& (Join-Path $out 'engine-probe.exe') $indexedPath
        if($LASTEXITCODE){throw "Indexed FLAC engine lifecycle failed $stats"}
        $report+=[pscustomobject]@{codec='flac-indexed';result='passed';tests=@('playback','pause','resume','stop','reopen','seek','paused seek','cancelled open');stats="$stats"}
        Write-Output "flac-indexed $stats"
    }
}
# Exercise family1 through the actual WASAPI worker/queue path. Silence keeps
# the lifecycle check unobtrusive while all elementary streams are decoded.
foreach($layout in @('5.1','7.1')){
    $path=Join-Path $scratch "engine-silence-family1-$layout.opus"
    & ffmpeg -hide_banner -loglevel error -y -f lavfi -i "anullsrc=r=48000:cl=$($layout):d=30" -c:a libopus -mapping_family 1 -b:a 128k $path
    if($LASTEXITCODE){throw 'Family1 engine fixture failed'}
    $stats=& (Join-Path $out 'engine-probe.exe') $path
    if($LASTEXITCODE){throw "Family1 engine lifecycle failed $layout $stats"}
    $report+=[pscustomobject]@{codec="opus-family1-$layout";result='passed';tests=@('stereo downmix playback','pause','resume','stop','reopen','seek','paused seek','cancelled open');stats="$stats"}
    Write-Output "opus-family1-$layout $stats"
}
$report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $out 'engine-verification.json') -Encoding utf8
