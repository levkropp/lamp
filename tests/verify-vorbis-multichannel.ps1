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
$oracle=Join-Path $out 'vorbis-multichannel-oracle'
New-Item -ItemType Directory -Force -Path $oracle | Out-Null
$referenceRoot=Join-Path $PSScriptRoot 'reference'
$pins=Get-Content -LiteralPath (Join-Path $referenceRoot 'vorbis-reference-hashes.json') -Raw -Encoding UTF8 | ConvertFrom-Json
foreach($pin in $pins.archives){
 $archive=Join-Path $referenceRoot $pin.file
 if((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $pin.sha256){throw "Reference archive hash differs: $($pin.file)"}
 $members=@(& tar.exe tf $archive)
 if($LASTEXITCODE -or !$members.Count){throw "Cannot list reference archive: $($pin.file)"}
 foreach($member in $members){if(!$member.StartsWith($pin.directory+'/') -or $member.Contains('\') -or ($member -split '/') -contains '..'){throw "Unsafe reference archive member: $member"}}
 & tar.exe xf $archive -C $referenceRoot
 if($LASTEXITCODE){throw "Cannot extract reference archive: $($pin.file)"}
}
$vorbis=Join-Path $referenceRoot 'libvorbis-1.3.7'
$ogg=Join-Path $referenceRoot 'libogg-1.3.6'
$referenceDirectory=Join-Path $oracle 'reference'
New-Item -ItemType Directory -Force -Path $referenceDirectory | Out-Null
$includes=@("/I$msvc\include","/I$sdkRoot\Include\$version\ucrt","/I$sdkRoot\Include\$version\um","/I$sdkRoot\Include\$version\shared","/I$vorbis\include","/I$vorbis\lib","/I$ogg\include")
$referenceSources=@('mdct','smallft','block','envelope','window','lsp','lpc','analysis','synthesis','psy','info','floor1','floor0','res0','mapping0','registry','codebook','sharedbook','lookup','bitrate','vorbisfile') | ForEach-Object {Join-Path $vorbis "lib\$_.c"}
$referenceSources+=@('bitwise','framing') | ForEach-Object {Join-Path $ogg "src\$_.c"}
& (Join-Path $msvc 'bin\Hostx64\x64\cl.exe') /nologo /O2 /MD /D_CRT_SECURE_NO_WARNINGS /c @includes "/Fo$referenceDirectory/" @referenceSources
if($LASTEXITCODE){throw 'Xiph reference compilation failed'}
$referenceObjects=@($referenceSources | ForEach-Object {Join-Path $referenceDirectory ([IO.Path]::GetFileNameWithoutExtension($_)+'.obj')})
foreach($name in @('seek-oracle','vorbis-native-oracle','vorbis-native-reference')){
 $runtime=if($name -eq 'vorbis-native-reference'){$referenceObjects}else{$objects}
 & (Join-Path $msvc 'bin\Hostx64\x64\cl.exe') /nologo /O2 /MD @includes "/Fo$oracle\$name.obj" "/Fe$oracle\$name.exe" (Join-Path $PSScriptRoot "$name.c") @runtime /link "/libpath:$msvc\lib\x64" "/libpath:$sdkRoot\Lib\$version\ucrt\x64" "/libpath:$sdkRoot\Lib\$version\um\x64" kernel32.lib psapi.lib
 if($LASTEXITCODE){throw "Vorbis oracle compilation failed: $name"}
}
$scratch=Join-Path $PSScriptRoot 'generated\vorbis-multichannel'
$taskPreference=$ErrorActionPreference
try{$ErrorActionPreference='Continue'; & node (Join-Path $PSScriptRoot 'vorbis-multichannel-fixtures.js') (Join-Path $out 'lamp-cli.exe') $oracle $scratch; $taskExit=$LASTEXITCODE}
finally{$ErrorActionPreference=$taskPreference}
if($taskExit){throw 'Vorbis multichannel verification failed'}
Copy-Item -LiteralPath (Join-Path $scratch 'vorbis-multichannel-verification.json') -Destination (Join-Path $out 'vorbis-multichannel-verification.json')
