$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$version=(Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
$tools=Join-Path $msvc 'bin\Hostx64\x64'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'bin\band-oracle') | Out-Null
. (Join-Path $PSScriptRoot 'opus-reference.ps1')
$reference=Get-LampOpusReference
& node (Join-Path $PSScriptRoot 'generate-celt-bands-reference.js') $reference
if($LASTEXITCODE){throw 'Full-band reference extraction failed'}
& node (Join-Path $PSScriptRoot 'generate-celt-controls-reference.js') $reference
if($LASTEXITCODE){throw 'Frame-prefix reference extraction failed'}
$objects=@('opus_band','opus_bands','opus_theta','opus_allocation','opus_vq','opus_cwrs','opus_band_transform','opus_range','opus_controls','opus_energy')
foreach($name in $objects){
 & (Join-Path $tools 'ml64.exe') /nologo /c "/I$root\src" "/Fo$root\bin\$name.obj" (Join-Path $root "src\$name.asm")
 if($LASTEXITCODE){throw "Assembly failed $name"}
}
$cfiles=@(Join-Path $PSScriptRoot 'opus-band-oracle.c')
$cfiles+=@(@('celt\entdec.c','celt\entcode.c','celt\entenc.c','celt\mathops.c','celt\vq.c','celt\cwrs.c','celt\laplace.c') | ForEach-Object {Join-Path $reference $_})
$objfiles=@($objects | ForEach-Object {Join-Path $root "bin\$_.obj"})
# MSVC strict floating point rejects RFC static double-to-float expressions.
# Compile the unchanged energy reference separately, as in its own oracle.
& (Join-Path $tools 'cl.exe') /nologo /c /O2 /fp:precise /Gy /MD /DOPUS_BUILD /DUSE_ALLOCA /DWIN32 /DSMALL_FOOTPRINT "/I$msvc\include" "/I$sdkRoot\Include\$version\ucrt" "/I$reference\include" "/I$reference\celt" "/Fo$root\bin\band-oracle\quant_bands.obj" (Join-Path $reference 'celt\quant_bands.c')
if($LASTEXITCODE){throw 'Energy reference compilation failed'}
$objfiles+=Join-Path $root 'bin\band-oracle\quant_bands.obj'
& (Join-Path $tools 'cl.exe') /nologo /O2 /fp:strict /Gy /MD /DOPUS_BUILD /DUSE_ALLOCA /DWIN32 /DSMALL_FOOTPRINT "/I$msvc\include" "/I$sdkRoot\Include\$version\ucrt" "/I$reference\include" "/I$reference\celt" "/I$root\bin" "/Fo$root\bin\band-oracle\\" "/Fe$root\bin\opus-band-oracle.exe" @cfiles @objfiles /link /OPT:REF "/libpath:$msvc\lib\x64" "/libpath:$sdkRoot\Lib\$version\ucrt\x64" "/libpath:$sdkRoot\Lib\$version\um\x64"
if($LASTEXITCODE){throw 'Recursive band test oracle failed to build'}
$result=& (Join-Path $root 'bin\opus-band-oracle.exe') (Join-Path $PSScriptRoot 'fixtures\tone.opus')
if($LASTEXITCODE){throw "Assembly recursive band mismatch $result"}
Write-Output $result
[pscustomobject]@{result='passed';scope='normal-mode CELT recursive vectors and full spectral frame loop, stereo, folding, TF, collapse masks, exact entropy/budget/seed state and connected real-frame prefixes; not synthesis or audio decoding';vector_absolute_tolerance=0.00001;folding_output_absolute_tolerance=0.00004;stats="$result"} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'bin\opus-band-verification.json') -Encoding utf8
