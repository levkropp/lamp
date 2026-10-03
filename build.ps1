param([switch]$Debug)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'Install Visual Studio Build Tools with the x64 C++ tools and Windows SDK.' }
$version = Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$tools = Join-Path $version.FullName 'bin\Hostx64\x64'
$sdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Lib'
$sdk = Get-ChildItem -LiteralPath $sdkRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
$out = Join-Path $root 'bin'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$rc = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin\$($sdk.Name)\x64\rc.exe"
if (-not (Test-Path -LiteralPath $rc)) { throw "Windows SDK resource compiler is missing: $rc" }
Push-Location (Join-Path $root 'assets')
try {
    & $rc /nologo "/fo$out\lamp.res" lamp.rc
    if ($LASTEXITCODE) { throw 'GUI resource compilation failed.' }
    & $rc /nologo /d LAMP_CLI "/fo$out\lamp-cli.res" lamp.rc
    if ($LASTEXITCODE) { throw 'CLI resource compilation failed.' }
} finally { Pop-Location }
foreach ($name in @('player', 'decoder', 'mp3', 'mp3_synthesis', 'ogg', 'vorbis', 'vorbis_transform', 'ui', 'opus_range', 'opus_packet', 'opus_cwrs', 'opus_energy', 'opus_silk_pulses')) {
    & (Join-Path $tools 'ml64.exe') /nologo /c "/I$root\src" "/Fo$out\$name.obj" (Join-Path $root "src\$name.asm")
    if ($LASTEXITCODE) { throw "Assembly failed: $name" }
}
$argsLink = @('/nologo', '/subsystem:console', '/entry:start', '/machine:x64', '/nodefaultlib', '/dynamicbase', '/nxcompat', '/opt:ref', '/opt:icf', "/out:$out\lamp-cli.exe", "/libpath:$($sdk.FullName)\um\x64", "$out\player.obj", "$out\decoder.obj", "$out\mp3.obj", "$out\mp3_synthesis.obj", "$out\ogg.obj", "$out\vorbis.obj", "$out\vorbis_transform.obj", 'kernel32.lib', 'ole32.lib', 'shell32.lib', 'avrt.lib')
if ($Debug) { $argsLink += '/debug' }
$argsLink += "$out\lamp-cli.res"
& (Join-Path $tools 'link.exe') @argsLink
if ($LASTEXITCODE) { throw 'Link failed.' }
$guiArgs=$argsLink | Where-Object { $_ -notmatch '^/subsystem:|^/entry:|^/out:|lamp-cli\.res$' }
$guiArgs+=@('/subsystem:windows','/entry:ui_start',"/out:$out\lamp.exe","$out\ui.obj","$out\lamp.res",'user32.lib','gdi32.lib','comdlg32.lib')
& (Join-Path $tools 'link.exe') @guiArgs
if($LASTEXITCODE) { throw 'UI link failed.' }
Get-Item -LiteralPath (Join-Path $out 'lamp.exe'),(Join-Path $out 'lamp-cli.exe') | Select-Object Name, Length
