$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$version=(Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
$tools=Join-Path $msvc 'bin\Hostx64\x64'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'bin\stream-oracle') | Out-Null
. (Join-Path $PSScriptRoot 'opus-reference.ps1')
$reference=Get-LampOpusReference
& node (Join-Path $PSScriptRoot 'generate-celt-tables.js') $reference --check
if($LASTEXITCODE){throw 'CELT table verification failed'}
& node (Join-Path $PSScriptRoot 'generate-silk-packet-reference.js') $reference --check
if($LASTEXITCODE){throw 'SILK packet table verification failed'}
foreach($stage in @('stereo','resampler','lpc','nlsf','indices','parameters')){
 & node (Join-Path $PSScriptRoot "generate-silk-$stage-tables.js") $reference --check
 if($LASTEXITCODE){throw "SILK $stage table verification failed"}
}
$objects=@('opus_stream','opus_packet','opus_mode','opus_silk_decoder','opus_silk_packet','opus_silk_stereo','opus_silk_frame','opus_silk_plc','opus_silk_cng','opus_silk_resampler','opus_silk_synthesis','opus_silk_prediction','opus_silk_state','opus_silk_lpc','opus_silk_parameters','opus_silk_nlsf','opus_silk_indices','opus_silk_pulses','opus_decoder','opus_plc','opus_pitch','opus_lpc','opus_range','opus_controls','opus_energy','opus_allocation','opus_band','opus_bands','opus_theta','opus_vq','opus_cwrs','opus_band_transform','opus_spectral','opus_fft','opus_mdct','opus_filter')
foreach($name in $objects){
 & (Join-Path $tools 'ml64.exe') /nologo /c "/I$root\src" "/Fo$root\bin\$name.obj" (Join-Path $root "src\$name.asm")
 if($LASTEXITCODE){throw "Assembly failed $name"}
}
$includes=@("/I$msvc\include","/I$sdkRoot\Include\$version\ucrt","/I$reference\include","/I$reference\celt","/I$reference\src","/I$reference\silk","/I$reference\silk\float","/I$root\bin")
$flags=@('/nologo','/O2','/Gy','/MD','/DOPUS_BUILD','/DUSE_ALLOCA','/DWIN32','/DSMALL_FOOTPRINT')
# Test includes RFC8251-updated celt.c/opus_decoder.c to inspect complete histories.
$cfiles=@(Join-Path $PSScriptRoot 'opus-stream-oracle.c')
$cfiles+=@(@('bands','cwrs','entcode','entdec','entenc','kiss_fft','laplace','mathops','mdct','modes','pitch','celt_lpc','rate','vq') | ForEach-Object {Join-Path $reference "celt\$_.c"})
$cfiles+=@('src\opus.c','src\opus_encoder.c','src\repacketizer.c' | ForEach-Object {Join-Path $reference $_})
$sourceList=[IO.File]::ReadAllText((Join-Path $reference 'silk_sources.mk'))
$silkFiles=@([regex]::Matches($sourceList,'(?m)^silk/(?!fixed/)[^\s\\]+\.c') | ForEach-Object {Join-Path $reference $_.Value})
& (Join-Path $tools 'cl.exe') @flags /c /fp:precise @includes "/Fo$root\bin\stream-oracle\quant_bands.obj" (Join-Path $reference 'celt\quant_bands.c')
if($LASTEXITCODE){throw 'Energy reference compilation failed'}
New-Item -ItemType Directory -Force -Path (Join-Path $root 'bin\stream-oracle\silk') | Out-Null
& (Join-Path $tools 'cl.exe') @flags /c /fp:precise @includes "/Fo$root\bin\stream-oracle\silk\\" @silkFiles
if($LASTEXITCODE){throw 'SILK reference compilation failed'}
$objfiles=@($objects | ForEach-Object {Join-Path $root "bin\$_.obj"})
$objfiles+=Join-Path $root 'bin\stream-oracle\quant_bands.obj'
$objfiles+=@($silkFiles | ForEach-Object {Join-Path $root ('bin\stream-oracle\silk\'+[IO.Path]::GetFileNameWithoutExtension($_)+'.obj')})
& (Join-Path $tools 'cl.exe') @flags /fp:strict @includes "/Fo$root\bin\stream-oracle\\" "/Fe$root\bin\opus-stream-oracle.exe" @cfiles @objfiles /link /OPT:REF "/libpath:$msvc\lib\x64" "/libpath:$sdkRoot\Lib\$version\ucrt\x64" "/libpath:$sdkRoot\Lib\$version\um\x64"
if($LASTEXITCODE){throw 'Opus packet API test oracle failed to build'}
$result=& (Join-Path $root 'bin\opus-stream-oracle.exe')
if($LASTEXITCODE){throw "Assembly Opus packet API mismatch $result"}
Write-Output $result
[pscustomobject]@{result='passed';reference='RFC6716 + RFC8251 (archive86a927223e73d2476646a1b933fcd3fffb6ecc8c,patch029e3aa88fc342c91e67a21e7bfbc9458661cd5f)';scope='Complete normal Opus packet-to-PCM dispatch: four framing codes, CBR/VBR, padding, up to48 frames/120ms, all32 TOC configurations, five output rates, mono/stereo conversion, FEC/loss and zero/one-byte DTX; 2048 malformed packets, capacity/canary/immutable-input/sticky failure checks';comparison='exact mapped integer SILK history and defined resampler state; float PCM/CELT-history at stated tolerance; deterministic complete ASM state with distinct scratch fills; RFC8251-updated reference decoder and test-only encoder, with a wrapper observing intermediate CELT errors that later frames/resets can clear';scale_adjusted_absolute_tolerance=0.00004;stats="$result"} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'bin\opus-stream-verification.json') -Encoding utf8
