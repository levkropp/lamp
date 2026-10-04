param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$out=if($OutputDirectory){$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)}else{Join-Path $root 'bin'}
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdkRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$version=(Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Lib') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
$objects=@('decoder','mp3','mp3_synthesis','ogg','vorbis','vorbis_transform') | ForEach-Object {Join-Path $out "$_.obj"}
$objects+=@(Get-ChildItem -LiteralPath $out -Filter 'opus*.obj' | ForEach-Object {$_.FullName})
$oracle=Join-Path $out 'flac-layout-oracle'
New-Item -ItemType Directory -Force -Path $oracle | Out-Null
& (Join-Path $msvc 'bin\Hostx64\x64\cl.exe') /nologo /O2 /MD "/I$msvc\include" "/I$sdkRoot\Include\$version\ucrt" "/Fo$oracle\seek-oracle.obj" "/Fe$oracle\seek-oracle.exe" (Join-Path $PSScriptRoot 'seek-oracle.c') @objects /link "/libpath:$msvc\lib\x64" "/libpath:$sdkRoot\Lib\$version\ucrt\x64" "/libpath:$sdkRoot\Lib\$version\um\x64" kernel32.lib
if($LASTEXITCODE){throw 'FLAC layout seek oracle compilation failed'}
& (Join-Path $msvc 'bin\Hostx64\x64\cl.exe') /nologo /O2 /MD "/I$msvc\include" "/I$sdkRoot\Include\$version\ucrt" "/I$sdkRoot\Include\$version\um" "/I$sdkRoot\Include\$version\shared" "/Fo$oracle\flac-bounds-oracle.obj" "/Fe$oracle\flac-bounds-oracle.exe" (Join-Path $PSScriptRoot 'pcm-bounds-oracle.c') @objects /link "/libpath:$msvc\lib\x64" "/libpath:$sdkRoot\Lib\$version\ucrt\x64" "/libpath:$sdkRoot\Lib\$version\um\x64" kernel32.lib psapi.lib
if($LASTEXITCODE){throw 'FLAC guarded buffer oracle compilation failed'}
$scratch=Join-Path $PSScriptRoot 'generated\flac-layouts'
& node (Join-Path $PSScriptRoot 'flac-layout-fixtures.js') (Join-Path $out 'lamp-cli.exe') (Join-Path $oracle 'seek-oracle.exe') $scratch (Join-Path $oracle 'flac-bounds-oracle.exe')
if($LASTEXITCODE){throw 'FLAC depth/layout verification failed'}
Copy-Item -LiteralPath (Join-Path $scratch 'flac-layout-verification.json') -Destination (Join-Path $out 'flac-layout-verification.json')
