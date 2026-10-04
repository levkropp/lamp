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
$oracle=Join-Path $out 'rf64-oracle'
New-Item -ItemType Directory -Force -Path $oracle | Out-Null
foreach($name in @('seek-oracle','pcm-bounds-oracle','rf64-sparse-oracle')){
    & (Join-Path $msvc 'bin\Hostx64\x64\cl.exe') /nologo /O2 /MD "/I$msvc\include" "/I$sdkRoot\Include\$version\ucrt" "/I$sdkRoot\Include\$version\um" "/I$sdkRoot\Include\$version\shared" "/Fo$oracle\$name.obj" "/Fe$oracle\$name.exe" (Join-Path $PSScriptRoot "$name.c") @objects /link "/libpath:$msvc\lib\x64" "/libpath:$sdkRoot\Lib\$version\ucrt\x64" "/libpath:$sdkRoot\Lib\$version\um\x64" kernel32.lib psapi.lib
    if($LASTEXITCODE){throw "RF64 oracle compilation failed: $name"}
}
$scratch=Join-Path $PSScriptRoot 'generated\rf64'
$taskPreference=$ErrorActionPreference
try {
    $ErrorActionPreference='Continue'
    & node (Join-Path $PSScriptRoot 'rf64-fixtures.js') (Join-Path $out 'lamp-cli.exe') $oracle $scratch
    $taskExitCode=$LASTEXITCODE
} finally { $ErrorActionPreference=$taskPreference }
if($taskExitCode){throw 'RF64/BW64 verification failed'}
Copy-Item -LiteralPath (Join-Path $scratch 'rf64-verification.json') -Destination (Join-Path $out 'rf64-verification.json')
