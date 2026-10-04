$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$version=(Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
$tools=Join-Path $msvc 'bin\Hostx64\x64'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'bin\silk-nlsf-oracle') | Out-Null
. (Join-Path $PSScriptRoot 'opus-reference.ps1')
$reference=Get-LampOpusReference
& node (Join-Path $PSScriptRoot 'generate-silk-nlsf-tables.js') $reference --check
if($LASTEXITCODE){throw 'SILK NLSF table verification failed'}
& node (Join-Path $PSScriptRoot 'generate-silk-indices-tables.js') $reference --check
if($LASTEXITCODE){throw 'SILK selector table verification failed'}
$objects=@('opus_silk_nlsf','opus_silk_indices','opus_range')
foreach($name in $objects){
 & (Join-Path $tools 'ml64.exe') /nologo /c "/I$root\src" "/Fo$root\bin\$name.obj" (Join-Path $root "src\$name.asm")
 if($LASTEXITCODE){throw "Assembly failed $name"}
}
$cfiles=@(Join-Path $PSScriptRoot 'opus-silk-nlsf-oracle.c')
$cfiles+=@(@('celt\entdec.c','celt\entcode.c','silk\decode_indices.c','silk\NLSF_unpack.c','silk\NLSF_VQ_weights_laroia.c','silk\NLSF_stabilize.c','silk\sort.c','silk\tables_other.c','silk\tables_gain.c','silk\tables_pitch_lag.c','silk\tables_LTP.c','silk\tables_NLSF_CB_NB_MB.c','silk\tables_NLSF_CB_WB.c') | ForEach-Object {Join-Path $reference $_})
$objfiles=@($objects | ForEach-Object {Join-Path $root "bin\$_.obj"})
& (Join-Path $tools 'cl.exe') /nologo /O2 /Gy /MD /DOPUS_BUILD /DUSE_ALLOCA /DWIN32 "/I$msvc\include" "/I$sdkRoot\Include\$version\ucrt" "/I$reference\include" "/I$reference\celt" "/I$reference\silk" "/Fo$root\bin\silk-nlsf-oracle\\" "/Fe$root\bin\opus-silk-nlsf-oracle.exe" @cfiles @objfiles /link /OPT:REF "/libpath:$msvc\lib\x64" "/libpath:$sdkRoot\Lib\$version\ucrt\x64" "/libpath:$sdkRoot\Lib\$version\um\x64"
if($LASTEXITCODE){throw 'SILK NLSF test oracle failed to build'}
$result=& (Join-Path $root 'bin\opus-silk-nlsf-oracle.exe')
if($LASTEXITCODE){throw "Assembly SILK NLSF mismatch $result"}
Write-Output $result
[pscustomobject]@{result='passed';scope='SILK fixed-point NLSF codebook and predictive residual reconstruction, Laroia weights, integer square-root approximation, clipping and 20-iteration stabilization/fallback, including connected side information; invalid reference-result spacing/range is rejected before LPC conversion; LPC conversion, synthesis, resampling and complete audio remain pending';comparison='exact integer vectors, residuals, weights and selectors, plus independent result-validity rejection checks';stats="$result"} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'bin\opus-silk-nlsf-verification.json') -Encoding utf8
