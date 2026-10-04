$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$version=(Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
$tools=Join-Path $msvc 'bin\Hostx64\x64'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'bin\decoder-oracle') | Out-Null
. (Join-Path $PSScriptRoot 'opus-reference.ps1')
$reference=Get-LampOpusReference
$objects=@('opus_decoder','opus_range','opus_controls','opus_energy','opus_allocation','opus_band','opus_bands','opus_theta','opus_vq','opus_cwrs','opus_band_transform','opus_spectral','opus_fft','opus_mdct','opus_filter')
foreach($name in $objects){
 & (Join-Path $tools 'ml64.exe') /nologo /c "/I$root\src" "/Fo$root\bin\$name.obj" (Join-Path $root "src\$name.asm")
 if($LASTEXITCODE){throw "Assembly failed $name"}
}
$includes=@("/I$msvc\include","/I$sdkRoot\Include\$version\ucrt","/I$reference\include","/I$reference\celt","/I$reference\src","/I$root\bin")
$flags=@('/nologo','/O2','/Gy','/MD','/DOPUS_BUILD','/DUSE_ALLOCA','/DWIN32','/DSMALL_FOOTPRINT')
# Test includes unchanged celt.c to inspect complete private decoder histories.
$cfiles=@(Join-Path $PSScriptRoot 'opus-decoder-oracle.c')
$cfiles+=@(@('bands','cwrs','entcode','entdec','entenc','kiss_fft','laplace','mathops','mdct','modes','pitch','celt_lpc','rate','vq') | ForEach-Object {Join-Path $reference "celt\$_.c"})
& (Join-Path $tools 'cl.exe') @flags /c /fp:precise @includes "/Fo$root\bin\decoder-oracle\quant_bands.obj" (Join-Path $reference 'celt\quant_bands.c')
if($LASTEXITCODE){throw 'Energy reference compilation failed'}
$objfiles=@($objects | ForEach-Object {Join-Path $root "bin\$_.obj"})
$objfiles+=Join-Path $root 'bin\decoder-oracle\quant_bands.obj'
& (Join-Path $tools 'cl.exe') @flags /fp:strict @includes "/Fo$root\bin\decoder-oracle\\" "/Fe$root\bin\opus-decoder-oracle.exe" @cfiles @objfiles /link /OPT:REF "/libpath:$msvc\lib\x64" "/libpath:$sdkRoot\Lib\$version\ucrt\x64" "/libpath:$sdkRoot\Lib\$version\um\x64"
if($LASTEXITCODE){throw 'Stateful decoder test oracle failed to build'}
$result=& (Join-Path $root 'bin\opus-decoder-oracle.exe') (Join-Path $PSScriptRoot 'fixtures\tone.opus')
if($LASTEXITCODE){throw "Assembly stateful CELT decoder mismatch $result"}
Write-Output $result
[pscustomobject]@{result='passed';scope='stateful normal-mode CELT packet-to-float-PCM and histories, mono/stereo conversion, all frame sizes/output rates/bandwidths and primed entropy contexts, malformed/truncated payloads and sticky failure/reset; PLC, SILK, Hybrid, Ogg playback and complete Opus conformance remain pending';scale_adjusted_absolute_tolerance=0.00004;stats="$result"} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'bin\opus-decoder-verification.json') -Encoding utf8
