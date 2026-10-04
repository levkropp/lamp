$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$version=(Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
$tools=Join-Path $msvc 'bin\Hostx64\x64'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'bin\spectral-oracle') | Out-Null
. (Join-Path $PSScriptRoot 'opus-reference.ps1')
$reference=Get-LampOpusReference
& node (Join-Path $PSScriptRoot 'generate-celt-spectral-tables.js') $reference --check
if($LASTEXITCODE){throw 'Spectral table verification failed'}
$objects=@('opus_spectral','opus_vq','opus_cwrs','opus_range')
foreach($name in $objects){
 & (Join-Path $tools 'ml64.exe') /nologo /c "/I$root\src" "/Fo$root\bin\$name.obj" (Join-Path $root "src\$name.asm")
 if($LASTEXITCODE){throw "Assembly failed $name"}
}
$includeArgs=@("/I$msvc\include","/I$sdkRoot\Include\$version\ucrt","/I$reference\include","/I$reference\celt")
& (Join-Path $tools 'cl.exe') /nologo /c /O2 /fp:precise /Gy /MD /DOPUS_BUILD /DUSE_ALLOCA /DWIN32 /DSMALL_FOOTPRINT @includeArgs "/Fo$root\bin\spectral-oracle\quant_bands.obj" (Join-Path $reference 'celt\quant_bands.c')
if($LASTEXITCODE){throw 'Energy reference compilation failed'}
$cfiles=@(Join-Path $PSScriptRoot 'opus-spectral-oracle.c')
$cfiles+=@(@('celt\entdec.c','celt\entcode.c','celt\entenc.c','celt\mathops.c','celt\vq.c','celt\cwrs.c','celt\laplace.c') | ForEach-Object {Join-Path $reference $_})
$objfiles=@($objects | ForEach-Object {Join-Path $root "bin\$_.obj"})
$objfiles+=Join-Path $root 'bin\spectral-oracle\quant_bands.obj'
& (Join-Path $tools 'cl.exe') /nologo /O2 /fp:strict /Gy /MD /DOPUS_BUILD /DUSE_ALLOCA /DWIN32 /DSMALL_FOOTPRINT @includeArgs "/Fo$root\bin\spectral-oracle\\" "/Fe$root\bin\opus-spectral-oracle.exe" @cfiles @objfiles /link /OPT:REF "/libpath:$msvc\lib\x64" "/libpath:$sdkRoot\Lib\$version\ucrt\x64" "/libpath:$sdkRoot\Lib\$version\um\x64"
if($LASTEXITCODE){throw 'Spectral test oracle failed to build'}
$result=& (Join-Path $root 'bin\opus-spectral-oracle.exe')
if($LASTEXITCODE){throw "Assembly spectral mismatch $result"}
Write-Output $result
[pscustomobject]@{result='passed';reference='RFC6716 + RFC8251 (archive86a927223e73d2476646a1b933fcd3fffb6ecc8c,patch029e3aa88fc342c91e67a21e7bfbc9458661cd5f)';scope='normal-mode CELT transient anti-collapse, mean energy/exponent conversion and denormalization with all output-rate boundaries; not inverse MDCT or PCM decoding';anti_collapse_absolute_tolerance=0.000003;spectral_relative_tolerance=0.0000003;exponent_maximum_ulp=1;stats="$result"} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'bin\opus-spectral-verification.json') -Encoding utf8
