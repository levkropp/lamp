param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$out=if($OutputDirectory){$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)}else{Join-Path $root 'bin'}
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$version=(Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
& (Join-Path $msvc 'bin\Hostx64\x64\cl.exe') /nologo /O2 /MD "/I$msvc\include" "/I$sdkRoot\Include\$version\ucrt" "/I$sdkRoot\Include\$version\um" "/I$sdkRoot\Include\$version\shared" "/Fo$out\ogg-crc-oracle.obj" "/Fe$out\ogg-crc-oracle.exe" (Join-Path $PSScriptRoot 'ogg-crc-oracle.c') (Join-Path $out 'ogg.obj') /link /OPT:REF "/libpath:$msvc\lib\x64" "/libpath:$sdkRoot\Lib\$version\ucrt\x64" "/libpath:$sdkRoot\Lib\$version\um\x64" kernel32.lib
if($LASTEXITCODE){throw 'Ogg CRC test failed to compile'}
$result=& (Join-Path $out 'ogg-crc-oracle.exe')
if($LASTEXITCODE){throw 'Ogg CRC verification failed'}
Write-Output $result
$result | Set-Content -LiteralPath (Join-Path $out 'ogg-crc-verification.json') -Encoding UTF8
exit 0
