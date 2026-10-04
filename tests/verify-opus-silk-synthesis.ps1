$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$version=(Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
$tools=Join-Path $msvc 'bin\Hostx64\x64'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'bin\silk-synthesis-oracle') | Out-Null
. (Join-Path $PSScriptRoot 'opus-reference.ps1')
$reference=Get-LampOpusReference
foreach($stage in @('lpc','nlsf','indices','parameters')){
 & node (Join-Path $PSScriptRoot "generate-silk-$stage-tables.js") $reference --check
 if($LASTEXITCODE){throw "SILK $stage table verification failed"}
}
$objects=@('opus_silk_synthesis','opus_silk_prediction','opus_silk_state','opus_silk_lpc','opus_silk_parameters','opus_silk_nlsf','opus_silk_indices','opus_silk_pulses','opus_range')
foreach($name in $objects){
 & (Join-Path $tools 'ml64.exe') /nologo /c "/I$root\src" "/Fo$root\bin\$name.obj" (Join-Path $root "src\$name.asm")
 if($LASTEXITCODE){throw "Assembly failed $name"}
}
$cfiles=@(Join-Path $PSScriptRoot 'opus-silk-synthesis-oracle.c')
$cfiles+=@(@('celt\entdec.c','celt\entcode.c','celt\entenc.c','silk\decode_core.c','silk\LPC_analysis_filter.c','silk\decode_parameters.c','silk\gain_quant.c','silk\log2lin.c','silk\lin2log.c','silk\decode_pitch.c','silk\pitch_est_tables.c','silk\NLSF2A.c','silk\LPC_inv_pred_gain.c','silk\bwexpander.c','silk\bwexpander_32.c','silk\table_LSF_cos.c','silk\NLSF_decode.c','silk\NLSF_unpack.c','silk\NLSF_VQ_weights_laroia.c','silk\NLSF_stabilize.c','silk\sort.c','silk\decode_indices.c','silk\decode_pulses.c','silk\shell_coder.c','silk\code_signs.c','silk\tables_other.c','silk\tables_gain.c','silk\tables_pitch_lag.c','silk\tables_LTP.c','silk\tables_NLSF_CB_NB_MB.c','silk\tables_NLSF_CB_WB.c','silk\tables_pulses_per_block.c') | ForEach-Object {Join-Path $reference $_})
$objfiles=@($objects | ForEach-Object {Join-Path $root "bin\$_.obj"})
& (Join-Path $tools 'cl.exe') /nologo /O2 /Gy /MD /DOPUS_BUILD /DUSE_ALLOCA /DWIN32 "/I$msvc\include" "/I$sdkRoot\Include\$version\ucrt" "/I$reference\include" "/I$reference\celt" "/I$reference\silk" "/Fo$root\bin\silk-synthesis-oracle\\" "/Fe$root\bin\opus-silk-synthesis-oracle.exe" @cfiles @objfiles /link /OPT:REF "/libpath:$msvc\lib\x64" "/libpath:$sdkRoot\Lib\$version\ucrt\x64" "/libpath:$sdkRoot\Lib\$version\um\x64"
if($LASTEXITCODE){throw 'SILK synthesis test oracle failed to build'}
$result=& (Join-Path $root 'bin\opus-silk-synthesis-oracle.exe')
if($LASTEXITCODE){throw "Assembly SILK synthesis mismatch $result"}
Write-Output $result
[pscustomobject]@{result='passed';scope='SILK inverse-NSQ excitation/random signs, LTP rewhitening/prediction/gain scaling, LPC synthesis, int16 PCM saturation, loss-to-normal blending and core history, including connected indices/pulses/parameters; concealment/CNG, resampling, stereo framing and complete audio conformance remain pending';comparison='exact source-rate mono int16 PCM, excitation/LPC/output history and mutable controls';stats="$result"} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'bin\opus-silk-synthesis-verification.json') -Encoding utf8
