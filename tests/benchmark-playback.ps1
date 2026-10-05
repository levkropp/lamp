param(
 [string]$OutputDirectory,
 [string]$MpvPath,
 [Parameter(Mandatory=$true)][string]$VlcPath,
 [ValidateRange(1,10)][int]$Runs=3,
 [ValidateRange(3,30)][int]$SampleSeconds=8,
 [ValidateRange(1,8)][int]$LoadWorkers=4,
 [ValidateSet('wav','flac','mp3','vorbis','opus')][string[]]$Codecs=@('wav','flac','mp3','vorbis','opus'),
 [ValidateSet('lamp','mpv','vlc')][string[]]$Players=@('lamp','mpv','vlc'),
 [ValidateSet('percent','seconds')][string]$VlcSeekMode='percent',
 [ValidatePattern('^[a-zA-Z0-9._-]+\.json$')][string]$ReportName='playback-benchmark.json'
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$out=if($OutputDirectory){$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)}else{Join-Path $root 'bin'}
if(-not $MpvPath){$MpvPath=(Get-Command mpv.exe -ErrorAction Stop).Source}
$MpvPath=(Resolve-Path -LiteralPath $MpvPath).Path
$VlcPath=(Resolve-Path -LiteralPath $VlcPath).Path
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$version=(Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
# Engine objects come from build.ps1 (tools/build-windows.py), in $out\obj.
$objects=@('player','platform','decoder','mp3','mp3_synthesis','ogg','vorbis','vorbis_transform') | ForEach-Object {Join-Path $out "obj\$_.obj"}
$objects+=@(Get-ChildItem -LiteralPath (Join-Path $out 'obj') -Filter 'opus*.obj' | ForEach-Object {$_.FullName})
& (Join-Path $msvc 'bin\Hostx64\x64\cl.exe') /nologo /W4 /O2 /MD "/I$msvc\include" "/I$sdkRoot\Include\$version\ucrt" "/I$sdkRoot\Include\$version\um" "/I$sdkRoot\Include\$version\shared" "/Fo$out\benchmark-playback.obj" "/Fe$out\benchmark-playback.exe" (Join-Path $PSScriptRoot 'benchmark-playback.c') @objects /link /OPT:REF "/libpath:$msvc\lib\x64" "/libpath:$sdkRoot\Lib\$version\ucrt\x64" "/libpath:$sdkRoot\Lib\$version\um\x64" kernel32.lib shell32.lib ole32.lib avrt.lib psapi.lib
if($LASTEXITCODE){throw 'Playback benchmark bridge compilation failed'}
$metadata=[pscustomobject]@{
 source_version=(Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()
 hardware=Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors
 os=Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber
 decoder_objects=@($objects | ForEach-Object {[pscustomobject]@{object=[IO.Path]::GetFileName($_);sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash}})
 harness_sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'benchmark-playback.c') -Algorithm SHA256).Hash
 controller_sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'benchmark-playback.js') -Algorithm SHA256).Hash
 production_gui_sha256=(Get-FileHash -LiteralPath (Join-Path $out 'lamp.exe') -Algorithm SHA256).Hash
 mpv_build=@(& $MpvPath --version)
 node_version=(& node --version)
 node_arch=(& node -p 'process.arch')
}
$vlcFolder=Split-Path $VlcPath -Parent
$vlcLibraries=@('libvlc.dll','libvlccore.dll') | ForEach-Object {
 $library=Join-Path $vlcFolder $_
 if(Test-Path -LiteralPath $library){[pscustomobject]@{file=$_;sha256=(Get-FileHash -LiteralPath $library -Algorithm SHA256).Hash}}
}
$metadata | Add-Member NoteProperty vlc_core_libraries @($vlcLibraries)
$bundleName=Split-Path $vlcFolder -Leaf
if($bundleName -match '^vlc-(\d+\.\d+\.\d+)$'){
 $vlcVersion=$Matches[1]
 $archiveName="vlc-$vlcVersion-win64.zip"
 $archiveFile=Join-Path (Split-Path $vlcFolder -Parent) $archiveName
 $checksumFile="$archiveFile.sha256"
 if((Test-Path -LiteralPath $archiveFile) -and (Test-Path -LiteralPath $checksumFile)){
  $archiveHash=(Get-FileHash -LiteralPath $archiveFile -Algorithm SHA256).Hash
  $checksum=([regex]::Match((Get-Content -LiteralPath $checksumFile -Raw),'[a-fA-F0-9]{64}')).Value
  if($archiveHash -ne $checksum){throw 'VLC archive does not match the adjacent checksum file'}
  $metadata | Add-Member NoteProperty vlc_portable_archive ([pscustomobject]@{file=$archiveName;sha256=$archiveHash;bytes=(Get-Item -LiteralPath $archiveFile).Length;checksum_matched=$true;source_url="https://download.videolan.org/pub/videolan/vlc/$vlcVersion/win64/$archiveName";checksum_url="https://download.videolan.org/pub/videolan/vlc/$vlcVersion/win64/$archiveName.sha256"})
 }
}
$fixtureReport=Join-Path $out 'seek-benchmark.json'
if(Test-Path -LiteralPath $fixtureReport){
 $fixtureMetadata=Get-Content -LiteralPath $fixtureReport -Raw -Encoding UTF8 | ConvertFrom-Json
 $fixtureMatches=$fixtureMetadata.result -eq 'passed'
 foreach($check in $fixtureMetadata.checks){
  $fixtureFile=Join-Path (Join-Path $PSScriptRoot 'generated\benchmark-seek') $check.file
  if(-not(Test-Path -LiteralPath $fixtureFile) -or (Get-FileHash -LiteralPath $fixtureFile -Algorithm SHA256).Hash -ne $check.fixture_sha256){$fixtureMatches=$false;break}
 }
 if($fixtureMatches){
  $metadata | Add-Member NoteProperty fixture_encoder_version $fixtureMetadata.ffmpeg_version
  $metadata | Add-Member NoteProperty fixture_generation_report_sha256 (Get-FileHash -LiteralPath $fixtureReport -Algorithm SHA256).Hash
 }
}
$metadataFile=Join-Path $out 'playback-benchmark-metadata.json'
$metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $metadataFile -Encoding UTF8
# Generate fixtures separately with benchmark-seek.ps1, then reuse identical files.
& node (Join-Path $PSScriptRoot 'benchmark-playback.js') --bridge (Join-Path $out 'benchmark-playback.exe') --mpv $MpvPath --vlc $VlcPath --fixtures (Join-Path $PSScriptRoot 'generated\benchmark-seek') --metadata $metadataFile --report (Join-Path $out $ReportName) --runs $Runs --sample-seconds $SampleSeconds --load-workers $LoadWorkers --codecs ($Codecs -join ',') --players ($Players -join ',') --vlc-seek-mode $VlcSeekMode
if($LASTEXITCODE){throw 'Playback benchmark failed; see partial report and per-player logs'}
