param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$out=if($OutputDirectory){$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)}else{Join-Path $root 'bin'}
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$version=(Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
$toolRoot=Join-Path $msvc 'bin\Hostx64\x64'
$oracleRoot=Join-Path $out 'opus-seek-reference'
New-Item -ItemType Directory -Force -Path $oracleRoot,(Join-Path $oracleRoot 'silk') | Out-Null
. (Join-Path $PSScriptRoot 'opus-reference.ps1')
$reference=Get-LampOpusReference
$includes=@("/I$msvc\include","/I$sdkRoot\Include\$version\ucrt","/I$reference\include","/I$reference\celt","/I$reference\src","/I$reference\silk","/I$reference\silk\float")
$flags=@('/nologo','/O2','/Gy','/MD','/DOPUS_BUILD','/DUSE_ALLOCA','/DWIN32','/DSMALL_FOOTPRINT')
$cfiles=@(Join-Path $PSScriptRoot 'opus-seek-oracle.c')
$cfiles+=@(@('bands','cwrs','entcode','entdec','entenc','kiss_fft','laplace','mathops','mdct','modes','pitch','celt_lpc','rate','vq') | ForEach-Object {Join-Path $reference "celt\$_.c"})
$cfiles+=@('src\opus.c','src\opus_encoder.c','src\repacketizer.c' | ForEach-Object {Join-Path $reference $_})
$sourceList=[IO.File]::ReadAllText((Join-Path $reference 'silk_sources.mk'))
$silkFiles=@([regex]::Matches($sourceList,'(?m)^silk/(?!fixed/)[^\s\\]+\.c') | ForEach-Object {Join-Path $reference $_.Value})
& (Join-Path $toolRoot 'cl.exe') @flags /c /fp:precise @includes "/Fo$oracleRoot\quant_bands.obj" (Join-Path $reference 'celt\quant_bands.c')
if($LASTEXITCODE){throw 'Energy reference compilation failed'}
& (Join-Path $toolRoot 'cl.exe') @flags /c /fp:precise @includes "/Fo$oracleRoot\silk\\" @silkFiles
if($LASTEXITCODE){throw 'SILK reference compilation failed'}
$objects=@('decoder','mp3','mp3_synthesis','ogg','vorbis','vorbis_transform') | ForEach-Object {Join-Path $out "$_.obj"}
$objects+=@(Get-ChildItem -LiteralPath $out -Filter 'opus*.obj' | ForEach-Object {$_.FullName})
$objects+=Join-Path $oracleRoot 'quant_bands.obj'
$objects+=@($silkFiles | ForEach-Object {Join-Path $oracleRoot ('silk\'+[IO.Path]::GetFileNameWithoutExtension($_)+'.obj')})
& (Join-Path $toolRoot 'cl.exe') @flags /fp:strict @includes "/Fo$oracleRoot\\" "/Fe$out\opus-seek-oracle.exe" @cfiles @objects /link /OPT:REF "/libpath:$msvc\lib\x64" "/libpath:$sdkRoot\Lib\$version\ucrt\x64" "/libpath:$sdkRoot\Lib\$version\um\x64"
if($LASTEXITCODE){throw 'Opus seek reference failed to build'}
& node (Join-Path $PSScriptRoot 'opus-seek-fixtures.js') (Join-Path $out 'lamp-cli.exe') (Join-Path $out 'opus-seek-oracle.exe') (Join-Path $PSScriptRoot 'generated\seeking\opus')
if($LASTEXITCODE){throw 'Opus indexed seek verification failed'}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'generated\seeking\opus\opus-seek-verification.json') -Destination (Join-Path $out 'opus-seek-verification.json')
exit 0
