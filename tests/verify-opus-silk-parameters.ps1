$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$version=(Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
$tools=Join-Path $msvc 'bin\Hostx64\x64'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'bin\silk-parameters-oracle') | Out-Null
. (Join-Path $PSScriptRoot 'opus-reference.ps1')
$reference=Get-LampOpusReference
& node (Join-Path $PSScriptRoot 'generate-silk-parameters-tables.js') $reference --check
if($LASTEXITCODE){throw 'SILK reconstruction table verification failed'}
& node (Join-Path $PSScriptRoot 'generate-silk-indices-tables.js') $reference --check
if($LASTEXITCODE){throw 'SILK side-information table verification failed'}
$objects=@('opus_silk_parameters','opus_silk_indices','opus_range')
foreach($name in $objects){
 & (Join-Path $tools 'ml64.exe') /nologo /c "/I$root\src" "/Fo$root\bin\$name.obj" (Join-Path $root "src\$name.asm")
 if($LASTEXITCODE){throw "Assembly failed $name"}
}
$cfiles=@(Join-Path $PSScriptRoot 'opus-silk-parameters-oracle.c')
$cfiles+=@(@('celt\entdec.c','celt\entcode.c','celt\entenc.c','silk\decode_indices.c','silk\NLSF_unpack.c','silk\gain_quant.c','silk\log2lin.c','silk\lin2log.c','silk\decode_pitch.c','silk\pitch_est_tables.c','silk\tables_other.c','silk\tables_gain.c','silk\tables_pitch_lag.c','silk\tables_LTP.c','silk\tables_NLSF_CB_NB_MB.c','silk\tables_NLSF_CB_WB.c') | ForEach-Object {Join-Path $reference $_})
$objfiles=@($objects | ForEach-Object {Join-Path $root "bin\$_.obj"})
& (Join-Path $tools 'cl.exe') /nologo /O2 /Gy /MD /DOPUS_BUILD /DUSE_ALLOCA /DWIN32 "/I$msvc\include" "/I$sdkRoot\Include\$version\ucrt" "/I$reference\include" "/I$reference\celt" "/I$reference\silk" "/I$root\bin" "/Fo$root\bin\silk-parameters-oracle\\" "/Fe$root\bin\opus-silk-parameters-oracle.exe" @cfiles @objfiles /link /OPT:REF "/libpath:$msvc\lib\x64" "/libpath:$sdkRoot\Lib\$version\ucrt\x64" "/libpath:$sdkRoot\Lib\$version\um\x64"
if($LASTEXITCODE){throw 'SILK reconstruction test oracle failed to build'}
$result=& (Join-Path $root 'bin\opus-silk-parameters-oracle.exe')
if($LASTEXITCODE){throw "Assembly SILK reconstruction mismatch $result"}
Write-Output $result
[pscustomobject]@{result='passed';reference='RFC6716 + RFC8251 (archive86a927223e73d2476646a1b933fcd3fffb6ecc8c,patch029e3aa88fc342c91e67a21e7bfbc9458661cd5f)';scope='SILK integer log-to-linear gain reconstruction, persistent gain-index state, pitch contour/clamping, Q14 LTP taps and scaling, connected side-information parameter sequences';comparison='exact integers and prior-gain state';stats="$result"} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'bin\opus-silk-parameters-verification.json') -Encoding utf8
