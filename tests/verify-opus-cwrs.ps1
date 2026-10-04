$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$version=(Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
$tools=Join-Path $msvc 'bin\Hostx64\x64'
. (Join-Path $PSScriptRoot 'opus-reference.ps1')
$reference=Get-LampOpusReference
foreach($name in @('opus_cwrs','opus_range')){
 & (Join-Path $tools 'ml64.exe') /nologo /c "/Fo$root\bin\$name.obj" (Join-Path $root "src\$name.asm")
 if($LASTEXITCODE) {throw "Assembly failed $name"}
}
$cfiles=@(Join-Path $PSScriptRoot 'opus-cwrs-oracle.c')
$cfiles+=@(@('celt\entdec.c','celt\entcode.c','celt\entenc.c') | ForEach-Object {Join-Path $reference $_})
& (Join-Path $tools 'cl.exe') /nologo /O2 /MD /DOPUS_BUILD /DUSE_ALLOCA /DWIN32 "/I$msvc\include" "/I$sdkRoot\Include\$version\ucrt" "/I$reference\include" "/I$reference\celt" "/Fo$root\bin\\" "/Fe$root\bin\opus-cwrs-oracle.exe" @cfiles "$root\bin\opus_cwrs.obj" "$root\bin\opus_range.obj" /link "/libpath:$msvc\lib\x64" "/libpath:$sdkRoot\Lib\$version\ucrt\x64" "/libpath:$sdkRoot\Lib\$version\um\x64"
if($LASTEXITCODE) {throw 'Pulse test oracle failed to build'}
$result=& (Join-Path $root 'bin\opus-cwrs-oracle.exe')
if($LASTEXITCODE) {throw "Assembly pulse mismatch $result"}
Write-Output $result
[pscustomobject]@{result='passed';reference='RFC6716 + RFC8251 (archive86a927223e73d2476646a1b933fcd3fffb6ecc8c,patch029e3aa88fc342c91e67a21e7bfbc9458661cd5f)';scope='CELT pulse enumeration and entropy state; not audio decoding';stats="$result"} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'bin\opus-cwrs-verification.json') -Encoding utf8
