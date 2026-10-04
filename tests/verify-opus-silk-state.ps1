$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$version=(Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
$tools=Join-Path $msvc 'bin\Hostx64\x64'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'bin\silk-state-oracle') | Out-Null
. (Join-Path $PSScriptRoot 'opus-reference.ps1')
$reference=Get-LampOpusReference
foreach($stage in @('lpc','nlsf','indices','parameters')){
 & node (Join-Path $PSScriptRoot "generate-silk-$stage-tables.js") $reference --check
 if($LASTEXITCODE){throw "SILK $stage table verification failed"}
}
$objects=@('opus_silk_state','opus_silk_lpc','opus_silk_parameters','opus_silk_nlsf','opus_silk_indices','opus_range')
foreach($name in $objects){
 & (Join-Path $tools 'ml64.exe') /nologo /c "/I$root\src" "/Fo$root\bin\$name.obj" (Join-Path $root "src\$name.asm")
 if($LASTEXITCODE){throw "Assembly failed $name"}
}
$cfiles=@(Join-Path $PSScriptRoot 'opus-silk-state-oracle.c')
$cfiles+=@(@('celt\entdec.c','celt\entcode.c','silk\decode_parameters.c','silk\gain_quant.c','silk\log2lin.c','silk\lin2log.c','silk\decode_pitch.c','silk\pitch_est_tables.c','silk\NLSF2A.c','silk\LPC_inv_pred_gain.c','silk\bwexpander.c','silk\bwexpander_32.c','silk\table_LSF_cos.c','silk\NLSF_decode.c','silk\NLSF_unpack.c','silk\NLSF_VQ_weights_laroia.c','silk\NLSF_stabilize.c','silk\sort.c','silk\decode_indices.c','silk\tables_other.c','silk\tables_gain.c','silk\tables_pitch_lag.c','silk\tables_LTP.c','silk\tables_NLSF_CB_NB_MB.c','silk\tables_NLSF_CB_WB.c') | ForEach-Object {Join-Path $reference $_})
$objfiles=@($objects | ForEach-Object {Join-Path $root "bin\$_.obj"})
& (Join-Path $tools 'cl.exe') /nologo /O2 /Gy /MD /DOPUS_BUILD /DUSE_ALLOCA /DWIN32 "/I$msvc\include" "/I$sdkRoot\Include\$version\ucrt" "/I$reference\include" "/I$reference\celt" "/I$reference\silk" "/Fo$root\bin\silk-state-oracle\\" "/Fe$root\bin\opus-silk-state-oracle.exe" @cfiles @objfiles /link /OPT:REF "/libpath:$msvc\lib\x64" "/libpath:$sdkRoot\Lib\$version\ucrt\x64" "/libpath:$sdkRoot\Lib\$version\um\x64"
if($LASTEXITCODE){throw 'SILK stateful parameter test oracle failed to build'}
$result=& (Join-Path $root 'bin\opus-silk-state-oracle.exe')
if($LASTEXITCODE){throw "Assembly SILK stateful parameter mismatch $result"}
Write-Output $result
[pscustomobject]@{result='passed';scope='Complete SILK gain/NLSF/LPC/pitch/LTP parameter orchestration, previous gain/NLSF history, first-frame interpolation reset, interpolation and bandwidth expansion after loss; atomic public and invalid-NLSF failures; synthesis, resampling and complete audio remain pending';comparison='exact normative decoder controls, SideInfoIndices and parameter history';stats="$result"} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'bin\opus-silk-state-verification.json') -Encoding utf8
