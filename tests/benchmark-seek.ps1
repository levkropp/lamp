param([string]$OutputDirectory,[ValidateRange(30,3600)][int]$Seconds=600,[ValidateRange(3,20)][int]$Runs=5,[switch]$ReuseFixtures,[string]$OggObject,[ValidatePattern('^[a-zA-Z0-9._-]+\.json$')][string]$ReportName='seek-benchmark.json')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$out=if($OutputDirectory){$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)}else{Join-Path $root 'bin'}
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$version=(Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
$objects=@('decoder','mp3','mp3_synthesis','vorbis','vorbis_transform') | ForEach-Object {Join-Path $out "$_.obj"}
$objects+=if($OggObject){$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OggObject)}else{Join-Path $out 'ogg.obj'}
$objects+=@(Get-ChildItem -LiteralPath $out -Filter 'opus*.obj' | ForEach-Object {$_.FullName})
& (Join-Path $msvc 'bin\Hostx64\x64\cl.exe') /nologo /O2 /MD "/I$msvc\include" "/I$sdkRoot\Include\$version\ucrt" "/I$sdkRoot\Include\$version\um" "/I$sdkRoot\Include\$version\shared" "/Fo$out\benchmark-seek.obj" "/Fe$out\benchmark-seek.exe" (Join-Path $PSScriptRoot 'benchmark-seek.c') @objects /link /OPT:REF "/libpath:$msvc\lib\x64" "/libpath:$sdkRoot\Lib\$version\ucrt\x64" "/libpath:$sdkRoot\Lib\$version\um\x64" kernel32.lib psapi.lib
if($LASTEXITCODE){throw 'Seek benchmark compilation failed'}
$scratch=Join-Path $PSScriptRoot 'generated\benchmark-seek'
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$checks=@()
foreach($codec in @('wav','flac','mp3','vorbis','opus')){
 $extension=if($codec -eq 'vorbis'){'ogg'}else{$codec}
 $file=Join-Path $scratch "$codec-$Seconds.$extension"
 $encoding=switch($codec){'wav'{@('-c:a','pcm_s16le')};'flac'{@('-c:a','flac')};'mp3'{@('-c:a','libmp3lame','-b:a','320k')};'vorbis'{@('-c:a','libvorbis','-q:a','8')};'opus'{@('-c:a','libopus','-b:a','128k')}}
 if(-not $ReuseFixtures -or -not (Test-Path -LiteralPath $file)){
  $source="anoisesrc=r=48000:d=$($Seconds):seed=7722:a=0.2[a];anoisesrc=r=48000:d=$($Seconds):seed=7793:a=0.2[b];[a][b]amerge=inputs=2,volume='if(lt(mod(t,60),20),0,1)':eval=frame"
  & ffmpeg -hide_banner -loglevel error -y -f lavfi -i $source @encoding $file
  if($LASTEXITCODE){throw "Seek benchmark fixture failed: $codec"}
 }
 $result=& (Join-Path $out 'benchmark-seek.exe') $file ($Seconds*48000) $Runs
 if($LASTEXITCODE){throw "Seek benchmark failed: $codec $result"}
 $record=$result | ConvertFrom-Json
 $record | Add-Member NoteProperty file ([IO.Path]::GetFileName($file))
 $record | Add-Member NoteProperty bytes (Get-Item -LiteralPath $file).Length
 $record | Add-Member NoteProperty fixture_sha256 (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
 $checks+=$record
 $medOpen=(@($record.runs.open_us | Sort-Object))[[int][Math]::Floor($record.runs.Count/2)]
 $medReady=(@($record.runs.ready_us | Sort-Object))[[int][Math]::Floor($record.runs.Count/2)]
 Write-Output "$codec median reopen=$([Math]::Round($medOpen/1000,3))ms ready750ms=$([Math]::Round($medReady/1000,3))ms"
}
$cpu=Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors
$os=Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber
$objectHashes=@($objects | ForEach-Object {[pscustomobject]@{object=[IO.Path]::GetFileName($_);sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash}})
$ffmpegVersion=@(& ffmpeg -version)
if($LASTEXITCODE){throw 'Could not record FFmpeg version'}
$report=[pscustomobject]@{result='passed';source_version=(Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim();recorded_utc=[DateTime]::UtcNow.ToString('o');scope='Operation-level in-process assembly decoder timings in a test-only C/CRT harness; warm filesystem after encoding, no deliberate disk-cache eviction; open/reopen, index positioning, discarded PCM and750ms decoded PCM measured separately with QPC; excludes process creation,WASAPI,UI and audible endpoint latency. Process CPU accounting is coarse; harness memory includes its CRT and mapped input, not production-player working set. No other-player comparison.';fixture="${Seconds}s48kHz stereo seeded noise alternating20s silence/40s noise; MP3320k,Vorbisq8,Opus128k; targets10/14/50/54/90/94percent (silence/noise pairs at600s)";ffmpeg_version=$ffmpegVersion[0];benchmark_harness_sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'benchmark-seek.c') -Algorithm SHA256).Hash;hardware=$cpu;os=$os;decoder_objects=$objectHashes;checks=$checks}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $out $ReportName) -Encoding UTF8
exit 0
