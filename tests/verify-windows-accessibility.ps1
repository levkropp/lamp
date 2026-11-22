param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$out=if($OutputDirectory){$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)}else{Join-Path $root 'bin'}
$vs=& "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdk="${env:ProgramFiles(x86)}\Windows Kits\10"
$v=(Get-ChildItem -LiteralPath (Join-Path $sdk 'Include') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
& "$msvc\bin\Hostx64\x64\cl.exe" /nologo /O2 /MD "/I$msvc\include" "/I$sdk\Include\$v\ucrt" "/I$sdk\Include\$v\um" "/I$sdk\Include\$v\shared" "/Fo$out\verify-windows-accessibility.obj" "/Fe$out\verify-windows-accessibility.exe" "$PSScriptRoot\verify-windows-accessibility.c" "$out\obj\accessibility.obj" /link "/libpath:$msvc\lib\x64" "/libpath:$sdk\Lib\$v\ucrt\x64" "/libpath:$sdk\Lib\$v\um\x64" ole32.lib oleacc.lib oleaut32.lib comctl32.lib user32.lib uuid.lib
if($LASTEXITCODE){throw 'Accessibility oracle compilation failed'}
$result=& "$out\verify-windows-accessibility.exe"
if($LASTEXITCODE){throw 'Native Windows accessibility verification failed'}
$report=$result | ConvertFrom-Json
$report | Add-Member -NotePropertyName scope -NotePropertyValue 'Native hidden trackbars: MSAA names, replacement/Unicode/cleanup, retained values and balanced COM initialization; no desktop input or screen-reader session.'
$report | Add-Member -NotePropertyName platform -NotePropertyValue ([Environment]::OSVersion.VersionString)
$report | Add-Member -NotePropertyName object_sha256 -NotePropertyValue ((Get-FileHash -LiteralPath "$out\obj\accessibility.obj").Hash)
$report | Add-Member -NotePropertyName gui_sha256 -NotePropertyValue ((Get-FileHash -LiteralPath "$out\lamp.exe").Hash)
[IO.File]::WriteAllText((Join-Path $out 'windows-accessibility-verification.json'),($report | ConvertTo-Json)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
$result
