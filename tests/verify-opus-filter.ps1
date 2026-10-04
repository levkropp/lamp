$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$version=(Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
$tools=Join-Path $msvc 'bin\Hostx64\x64'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'bin\filter-oracle') | Out-Null
. (Join-Path $PSScriptRoot 'opus-reference.ps1')
$reference=Get-LampOpusReference
& node (Join-Path $PSScriptRoot 'generate-celt-transform-tables.js') $reference --check
if($LASTEXITCODE){throw 'Transform table verification failed'}
$objects=@('opus_filter','opus_mdct','opus_fft')
foreach($name in $objects){
 & (Join-Path $tools 'ml64.exe') /nologo /c "/I$root\src" "/Fo$root\bin\$name.obj" (Join-Path $root "src\$name.asm")
 if($LASTEXITCODE){throw "Assembly failed $name"}
}
$objfiles=@($objects | ForEach-Object {Join-Path $root "bin\$_.obj"})
& (Join-Path $tools 'cl.exe') /nologo /O2 /fp:strict /Gy /MD /DOPUS_BUILD /DUSE_ALLOCA /DWIN32 /DSMALL_FOOTPRINT "/I$msvc\include" "/I$sdkRoot\Include\$version\ucrt" "/I$reference\include" "/I$reference\celt" "/I$root\bin" "/Fo$root\bin\filter-oracle\\" "/Fe$root\bin\opus-filter-oracle.exe" (Join-Path $PSScriptRoot 'opus-filter-oracle.c') @objfiles /link /OPT:REF "/libpath:$msvc\lib\x64" "/libpath:$sdkRoot\Lib\$version\ucrt\x64" "/libpath:$sdkRoot\Lib\$version\um\x64"
if($LASTEXITCODE){throw 'Output filter test oracle failed to build'}
$result=& (Join-Path $root 'bin\opus-filter-oracle.exe')
if($LASTEXITCODE){throw "Assembly output filter mismatch $result"}
Write-Output $result
[pscustomobject]@{result='passed';reference='RFC6716 + RFC8251 (archive86a927223e73d2476646a1b933fcd3fffb6ecc8c,patch029e3aa88fc342c91e67a21e7bfbc9458661cd5f)';scope='CELT causal/window-transition comb postfilter, tapsets, standard-mode deemphasis, PCM scaling and all output rates with persistent memory; not complete Opus decoding';scale_adjusted_absolute_tolerance=0.00001;stats="$result"} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'bin\opus-filter-verification.json') -Encoding utf8
