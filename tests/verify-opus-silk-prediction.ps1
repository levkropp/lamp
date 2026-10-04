$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$version=(Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
$tools=Join-Path $msvc 'bin\Hostx64\x64'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'bin\silk-prediction-oracle') | Out-Null
. (Join-Path $PSScriptRoot 'opus-reference.ps1')
$reference=Get-LampOpusReference
& (Join-Path $tools 'ml64.exe') /nologo /c "/I$root\src" "/Fo$root\bin\opus_silk_prediction.obj" (Join-Path $root 'src\opus_silk_prediction.asm')
if($LASTEXITCODE){throw 'Assembly failed opus_silk_prediction'}
$cfiles=@((Join-Path $PSScriptRoot 'opus-silk-prediction-oracle.c'),(Join-Path $reference 'silk\LPC_analysis_filter.c'))
& (Join-Path $tools 'cl.exe') /nologo /O2 /Gy /MD /DOPUS_BUILD /DUSE_ALLOCA /DWIN32 "/I$msvc\include" "/I$sdkRoot\Include\$version\ucrt" "/I$reference\include" "/I$reference\celt" "/I$reference\silk" "/Fo$root\bin\silk-prediction-oracle\\" "/Fe$root\bin\opus-silk-prediction-oracle.exe" @cfiles "$root\bin\opus_silk_prediction.obj" /link /OPT:REF "/libpath:$msvc\lib\x64" "/libpath:$sdkRoot\Lib\$version\ucrt\x64" "/libpath:$sdkRoot\Lib\$version\um\x64"
if($LASTEXITCODE){throw 'SILK prediction test oracle failed to build'}
$result=& (Join-Path $root 'bin\opus-silk-prediction-oracle.exe')
if($LASTEXITCODE){throw "Assembly SILK prediction mismatch $result"}
Write-Output $result
[pscustomobject]@{result='passed';reference='RFC6716 + RFC8251 (archive86a927223e73d2476646a1b933fcd3fffb6ecc8c,patch029e3aa88fc342c91e67a21e7bfbc9458661cd5f)';scope='SILK signed fixed-point division for gain adjustment and zero-state LPC analysis/rewhitening, including integer wrap/rounding/saturation and public guards';comparison='exact integers and complete output samples';stats="$result"} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'bin\opus-silk-prediction-verification.json') -Encoding utf8
