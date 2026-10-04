$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$version=(Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
$tools=Join-Path $msvc 'bin\Hostx64\x64'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'bin\lpc-oracle') | Out-Null
. (Join-Path $PSScriptRoot 'opus-reference.ps1')
$reference=Get-LampOpusReference
& (Join-Path $tools 'ml64.exe') /nologo /c "/I$root\src" "/Fo$root\bin\opus_lpc.obj" (Join-Path $root 'src\opus_lpc.asm')
if($LASTEXITCODE){throw 'LPC assembly failed'}
$includes=@("/I$msvc\include","/I$sdkRoot\Include\$version\ucrt","/I$reference\include","/I$reference\celt")
& (Join-Path $tools 'cl.exe') /nologo /O2 /fp:strict /Gy /MD /DOPUS_BUILD /DUSE_ALLOCA /DWIN32 /DSMALL_FOOTPRINT @includes "/Fo$root\bin\lpc-oracle\\" "/Fe$root\bin\opus-lpc-oracle.exe" (Join-Path $PSScriptRoot 'opus-lpc-oracle.c') (Join-Path $reference 'celt\celt_lpc.c') (Join-Path $root 'bin\opus_lpc.obj') /link /OPT:REF "/libpath:$msvc\lib\x64" "/libpath:$sdkRoot\Lib\$version\ucrt\x64" "/libpath:$sdkRoot\Lib\$version\um\x64"
if($LASTEXITCODE){throw 'LPC test oracle failed to build'}
$result=& (Join-Path $root 'bin\opus-lpc-oracle.exe')
if($LASTEXITCODE){throw "Assembly CELT prediction mismatch $result"}
Write-Output $result
[pscustomobject]@{result='passed';reference='RFC6716 + RFC8251 (archive86a927223e73d2476646a1b933fcd3fffb6ecc8c,patch029e3aa88fc342c91e67a21e7bfbc9458661cd5f)';scope='CELT float windowed autocorrelation, Levinson-Durbin LPC and stateful causal/in-place FIR/IIR kernels, also used by the separate CELT frame concealment suite';scale_adjusted_absolute_tolerance=0.00001;stats="$result"} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'bin\opus-lpc-verification.json') -Encoding utf8
