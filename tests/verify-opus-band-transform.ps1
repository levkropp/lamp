$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$version=(Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
$tools=Join-Path $msvc 'bin\Hostx64\x64'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'bin') | Out-Null
. (Join-Path $PSScriptRoot 'opus-reference.ps1')
$reference=Get-LampOpusReference
& (Join-Path $tools 'ml64.exe') /nologo /c "/Fo$root\bin\opus_band_transform.obj" (Join-Path $root 'src\opus_band_transform.asm')
if($LASTEXITCODE) {throw 'Band transform assembly failed'}
$oracleOut=Join-Path $root 'bin\band-transform-oracle'
New-Item -ItemType Directory -Force -Path $oracleOut | Out-Null
$cfiles=@(Join-Path $PSScriptRoot 'opus-band-transform-oracle.c')
$cfiles+=@(@('celt\vq.c','celt\cwrs.c','celt\mathops.c','celt\entdec.c','celt\entcode.c','celt\entenc.c') | ForEach-Object {Join-Path $reference $_})
& (Join-Path $tools 'cl.exe') /nologo /O2 /fp:strict /Gy /MD /DOPUS_BUILD /DUSE_ALLOCA /DWIN32 /DSMALL_FOOTPRINT "/I$msvc\include" "/I$sdkRoot\Include\$version\ucrt" "/I$reference\include" "/I$reference\celt" "/Fo$oracleOut\\" "/Fe$root\bin\opus-band-transform-oracle.exe" @cfiles "$root\bin\opus_band_transform.obj" /link /OPT:REF "/libpath:$msvc\lib\x64" "/libpath:$sdkRoot\Lib\$version\ucrt\x64" "/libpath:$sdkRoot\Lib\$version\um\x64"
if($LASTEXITCODE) {throw 'Band transform test oracle failed to build'}
$result=& (Join-Path $root 'bin\opus-band-transform-oracle.exe')
if($LASTEXITCODE) {throw "Assembly band transform mismatch $result"}
Write-Output $result
[pscustomobject]@{result='passed';reference='RFC6716 + RFC8251 (archive86a927223e73d2476646a1b933fcd3fffb6ecc8c,patch029e3aa88fc342c91e67a21e7bfbc9458661cd5f)';scope='CELT Haar time/frequency transforms and Hadamard interleave/deinterleave; not recursive bands or audio decoding';stats="$result"} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'bin\opus-band-transform-verification.json') -Encoding utf8
