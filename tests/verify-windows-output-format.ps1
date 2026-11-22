param([string]$OutputDirectory,[switch]$DeviceProbe)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$out=if($OutputDirectory){$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)}else{Join-Path $root 'bin'}
$vs=& "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdk="${env:ProgramFiles(x86)}\Windows Kits\10"
$v=(Get-ChildItem -LiteralPath (Join-Path $sdk 'Include') -Directory | Sort-Object Name -Descending | Select-Object -First 1).Name
& "$msvc\bin\Hostx64\x64\cl.exe" /nologo /O2 /MD "/I$msvc\include" "/I$sdk\Include\$v\ucrt" "/I$sdk\Include\$v\um" "/I$sdk\Include\$v\shared" "/Fo$out\verify-windows-output-format.obj" "/Fe$out\verify-windows-output-format.exe" "$PSScriptRoot\verify-windows-output-format.c" "$out\obj\output_format.obj" "$out\obj\output_exclusive.obj" /link "/libpath:$msvc\lib\x64" "/libpath:$sdk\Lib\$v\ucrt\x64" "/libpath:$sdk\Lib\$v\um\x64" kernel32.lib ole32.lib
if($LASTEXITCODE){throw 'Output format oracle compilation failed'}
$result=if($DeviceProbe){& "$out\verify-windows-output-format.exe" --device-probe}else{& "$out\verify-windows-output-format.exe"}
if($LASTEXITCODE){throw 'Output format verification failed'}
$report=$result | ConvertFrom-Json
$report | Add-Member -NotePropertyName scope -NotePropertyValue 'Guarded descriptors, mock exclusive negotiation/setup, fresh-client alignment recovery and cleanup at every COM failure; independent numeric packing model, gain/clipping and exact buffers. Optional real device queries never Initialize/Start a stream; no exclusive playback.'
$report | Add-Member -NotePropertyName platform -NotePropertyValue ([Environment]::OSVersion.VersionString)
$report | Add-Member -NotePropertyName object_sha256 -NotePropertyValue ((Get-FileHash -LiteralPath "$out\obj\output_format.obj").Hash)
$report | Add-Member -NotePropertyName setup_object_sha256 -NotePropertyValue ((Get-FileHash -LiteralPath "$out\obj\output_exclusive.obj").Hash)
$report | Add-Member -NotePropertyName test_sha256 -NotePropertyValue ((Get-FileHash -LiteralPath "$out\verify-windows-output-format.exe").Hash)
$report | Add-Member -NotePropertyName format_source_sha256 -NotePropertyValue ((Get-FileHash -LiteralPath "$root\src\win\output_format.s").Hash)
$report | Add-Member -NotePropertyName setup_source_sha256 -NotePropertyValue ((Get-FileHash -LiteralPath "$root\src\win\output_exclusive.s").Hash)
$report | Add-Member -NotePropertyName oracle_source_sha256 -NotePropertyValue ((Get-FileHash -LiteralPath "$PSScriptRoot\verify-windows-output-format.c").Hash)
$report | Add-Member -NotePropertyName msvc -NotePropertyValue (Split-Path $msvc -Leaf)
$report | Add-Member -NotePropertyName windows_sdk -NotePropertyValue $v
$report | Add-Member -NotePropertyName recorded_utc -NotePropertyValue ([DateTime]::UtcNow.ToString('o'))
[IO.File]::WriteAllText((Join-Path $out 'windows-output-format-verification.json'),($report | ConvertTo-Json -Depth 8)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
$result
