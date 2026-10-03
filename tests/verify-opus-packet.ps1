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
$source=Get-Content -Raw -LiteralPath (Join-Path $reference 'src\opus_decoder.c')
# Preserve the reference license and extract just the normative packet helpers.
$header=$source.Substring(0,$source.IndexOf('#ifdef HAVE_CONFIG_H'))+"`n#include <stddef.h>`ntypedef int opus_int32;`n#define OPUS_BAD_ARG -1`n#define OPUS_INVALID_PACKET -4`n"
$first=$source.IndexOf('int opus_packet_get_samples_per_frame(')
$last=$source.IndexOf('int opus_packet_get_nb_channels(',$first)
$duration=$source.Substring($first,$last-$first).Replace('opus_packet_get_samples_per_frame','reference_samples_per_frame')
$first=$source.IndexOf('static int parse_size(')
$last=$source.IndexOf('int opus_decode_native(',$first)
$parser=$source.Substring($first,$last-$first).Replace('opus_packet_get_samples_per_frame','reference_samples_per_frame').Replace('int opus_packet_parse(','int reference_packet_parse(')
$generated=Join-Path $root 'bin\opus_packet_reference.h'
[IO.File]::WriteAllText($generated,$header+"`n"+$duration+"`n"+$parser+"`n")
& (Join-Path $tools 'ml64.exe') /nologo /c "/Fo$root\bin\opus_packet.obj" (Join-Path $root 'src\opus_packet.asm')
if($LASTEXITCODE) {throw 'Packet assembly failed'}
& (Join-Path $tools 'cl.exe') /nologo /O2 /MD "/I$msvc\include" "/I$sdkRoot\Include\$version\ucrt" "/I$root\bin" "/Fo$root\bin\\" "/Fe$root\bin\opus-packet-oracle.exe" (Join-Path $PSScriptRoot 'opus-packet-oracle.c') "$root\bin\opus_packet.obj" /link "/libpath:$msvc\lib\x64" "/libpath:$sdkRoot\Lib\$version\ucrt\x64" "/libpath:$sdkRoot\Lib\$version\um\x64"
if($LASTEXITCODE) {throw 'Packet test oracle failed to build'}
$result=& (Join-Path $root 'bin\opus-packet-oracle.exe')
if($LASTEXITCODE) {throw "Assembly packet mismatch $result"}
Write-Output $result
[pscustomobject]@{result='passed';scope='packet framing, frame sizes and pointers, TOC and duration; not audio decoding';stats="$result"} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'bin\opus-packet-verification.json') -Encoding utf8
