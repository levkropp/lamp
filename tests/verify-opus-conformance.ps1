param([int[]]$Rates=@(8000,12000,16000,24000,48000),[int[]]$Channels=@(1,2),[int[]]$Vectors=(1..12))
$ErrorActionPreference='Stop'
if(@($Rates | Where-Object {$_ -notin @(8000,12000,16000,24000,48000)}).Count -or @($Channels | Where-Object {$_ -notin @(1,2)}).Count -or @($Vectors | Where-Object {$_ -lt 1 -or $_ -gt 12}).Count -or -not $Rates.Count -or -not $Channels.Count -or -not $Vectors.Count) {throw 'Invalid conformance rate/channel/vector selection'}
$root=Split-Path $PSScriptRoot -Parent
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$version=(Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
$tools=Join-Path $msvc 'bin\Hostx64\x64'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'bin\conformance-oracle') | Out-Null
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
$cfiles=@(Join-Path $PSScriptRoot 'opus-conformance-oracle.c')
$cfiles+=@(@('bands','cwrs','entcode','entdec','entenc','kiss_fft','laplace','mathops','mdct','modes','pitch','celt_lpc','rate','vq') | ForEach-Object {Join-Path $reference "celt\$_.c"})
$cfiles+=@('src\opus.c','src\opus_encoder.c','src\repacketizer.c' | ForEach-Object {Join-Path $reference $_})
$sourceList=[IO.File]::ReadAllText((Join-Path $reference 'silk_sources.mk'))
$silkFiles=@([regex]::Matches($sourceList,'(?m)^silk/(?!fixed/)[^\s\\]+\.c') | ForEach-Object {Join-Path $reference $_.Value})
& (Join-Path $tools 'cl.exe') @flags /c /fp:precise @includes "/Fo$root\bin\conformance-oracle\quant_bands.obj" (Join-Path $reference 'celt\quant_bands.c')
if($LASTEXITCODE){throw 'Energy reference compilation failed'}
New-Item -ItemType Directory -Force -Path (Join-Path $root 'bin\conformance-oracle\silk') | Out-Null
& (Join-Path $tools 'cl.exe') @flags /c /fp:precise @includes "/Fo$root\bin\conformance-oracle\silk\\" @silkFiles
if($LASTEXITCODE){throw 'SILK reference compilation failed'}
$objfiles=@($objects | ForEach-Object {Join-Path $root "bin\$_.obj"})
$objfiles+=Join-Path $root 'bin\conformance-oracle\quant_bands.obj'
$objfiles+=@($silkFiles | ForEach-Object {Join-Path $root ('bin\conformance-oracle\silk\'+[IO.Path]::GetFileNameWithoutExtension($_)+'.obj')})
& (Join-Path $tools 'cl.exe') @flags /fp:strict @includes "/Fo$root\bin\conformance-oracle\\" "/Fe$root\bin\opus-conformance-oracle.exe" @cfiles @objfiles /link /OPT:REF "/libpath:$msvc\lib\x64" "/libpath:$sdkRoot\Lib\$version\ucrt\x64" "/libpath:$sdkRoot\Lib\$version\um\x64"
if($LASTEXITCODE){throw 'Opus packet API test oracle failed to build'}

# The official perceptual comparison is compiled unchanged and test-only.
& (Join-Path $tools 'cl.exe') @flags /fp:precise @includes "/Fo$root\bin\conformance-oracle\opus_compare.obj" "/Fe$root\bin\opus-compare.exe" (Join-Path $reference 'src\opus_compare.c') /link "/libpath:$msvc\lib\x64" "/libpath:$sdkRoot\Lib\$version\ucrt\x64" "/libpath:$sdkRoot\Lib\$version\um\x64"
if($LASTEXITCODE){throw 'Official Opus comparison failed to build'}
. (Join-Path $PSScriptRoot 'opus-vectors.ps1')
$vectorsPath=Get-LampOpusVectors
$checks=[Collections.Generic.List[object]]::new()
foreach($rate in @($Rates | Select-Object -Unique)){foreach($channel in @($Channels | Select-Object -Unique)){foreach($vector in @($Vectors | Select-Object -Unique)){
    $name='testvector{0:d2}' -f $vector
    $output=Join-Path $root "bin\conformance-oracle\$name-$rate-$channel.s16"
    $stats=& (Join-Path $root 'bin\opus-conformance-oracle.exe') (Join-Path $vectorsPath "$name.bit") $output $rate $channel
    if($LASTEXITCODE){throw "Official vector packet/PCM/history mismatch: $name $rate $channel $stats"}
    $decoded=$stats | ConvertFrom-Json
    $compareArgs=@('-r',"$rate",(Join-Path $vectorsPath "$name.dec"),$output)
    if($channel -eq 2){$compareArgs=@('-s')+$compareArgs}
    $compareLog=Join-Path $root "bin\conformance-oracle\$name-$rate-$channel-compare.txt"
    $savedErrorAction=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        & (Join-Path $root 'bin\opus-compare.exe') @compareArgs 2> $compareLog
        $compareExit=$LASTEXITCODE
    } finally {$ErrorActionPreference=$savedErrorAction}
    if($compareExit){throw "Official vector perceptual comparison failed: $name $rate $channel"}
    $compareText=Get-Content -LiteralPath $compareLog -Raw
    $quality=[regex]::Match($compareText,'quality metric: ([0-9.]+)')
    if(-not $quality.Success -or $compareText -notmatch 'Test vector PASSES'){throw 'Official comparison result was not recorded'}
    $checks.Add([pscustomobject]@{vector=$name;rate=$rate;channels=$channel;result='passed';quality_percent=[double]::Parse($quality.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture);packets=$decoded.packets;frames=$decoded.frames;history_values=$decoded.history_values;maximum_scaled_error=$decoded.maximum_scaled_error})
    Write-Output "$name $rate Hz $channel channels: official comparison passed, $($quality.Groups[1].Value)% quality, $($decoded.packets) exact packet/history checks"
    Remove-Item -LiteralPath $output
}}}
$complete=$checks.Count -eq 120
[pscustomobject]@{result='passed';complete_set=$complete;scope='Official RFC8251 phase-inversion vectors, selected rates/channels/vectors recorded per check; unmodified opus_compare acceptance plus packet final-range, native PCM/history at0.00004 scaled tolerance, immutable input, canaries and distinct-scratch assembly checks';reference='Hash-verified RFC6716 archive + RFC8251 patch';vector_hashes='tests/reference/opus-rfc8251-vector-hashes.json';checks=@($checks)} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'bin\opus-conformance-verification.json') -Encoding utf8
