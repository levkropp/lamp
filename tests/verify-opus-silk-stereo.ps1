$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$version=(Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
$tools=Join-Path $msvc 'bin\Hostx64\x64'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'bin\silk-stereo-oracle') | Out-Null
. (Join-Path $PSScriptRoot 'opus-reference.ps1')
$reference=Get-LampOpusReference
foreach($stage in @('stereo')){
 & node (Join-Path $PSScriptRoot "generate-silk-$stage-tables.js") $reference --check
 if($LASTEXITCODE){throw "SILK $stage table verification failed"}
}
$objects=@('opus_silk_stereo','opus_range')
foreach($name in $objects){
 & (Join-Path $tools 'ml64.exe') /nologo /c "/I$root\src" "/Fo$root\bin\$name.obj" (Join-Path $root "src\$name.asm")
 if($LASTEXITCODE){throw "Assembly failed $name"}
}
$cfiles=@(Join-Path $PSScriptRoot 'opus-silk-stereo-oracle.c')
$cfiles+=@(@('celt\entdec.c','celt\entcode.c','celt\entenc.c','silk\stereo_decode_pred.c','silk\stereo_MS_to_LR.c','silk\tables_other.c') | ForEach-Object {Join-Path $reference $_})
$objfiles=@($objects | ForEach-Object {Join-Path $root "bin\$_.obj"})
& (Join-Path $tools 'cl.exe') /nologo /O2 /Gy /MD /DOPUS_BUILD /DUSE_ALLOCA /DWIN32 "/I$msvc\include" "/I$sdkRoot\Include\$version\ucrt" "/I$reference\include" "/I$reference\celt" "/I$reference\silk" "/Fo$root\bin\silk-stereo-oracle\\" "/Fe$root\bin\opus-silk-stereo-oracle.exe" @cfiles @objfiles /link /OPT:REF "/libpath:$msvc\lib\x64" "/libpath:$sdkRoot\Lib\$version\ucrt\x64" "/libpath:$sdkRoot\Lib\$version\um\x64"
if($LASTEXITCODE){throw 'SILK stereo test oracle failed to build'}
$result=& (Join-Path $root 'bin\opus-silk-stereo-oracle.exe')
if($LASTEXITCODE){throw "Assembly SILK stereo mismatch $result"}
Write-Output $result
[pscustomobject]@{result='passed';reference='RFC6716 + RFC8251 (archive86a927223e73d2476646a1b933fcd3fffb6ecc8c,patch029e3aa88fc342c91e67a21e7bfbc9458661cd5f)';scope='SILK predictor and mid-only entropy decoding, adaptive mid/side reconstruction, interpolation, saturated left/right PCM and stereo history';comparison='exact complete entropy/stereo state and int16 PCM, capacity/canary guards';stats="$result"} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'bin\opus-silk-stereo-verification.json') -Encoding utf8
