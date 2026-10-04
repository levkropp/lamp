param([string]$OutputDirectory, [ValidateRange(1,6)][int]$CodecKind=2)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$out=if($OutputDirectory){$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)}else{Join-Path $root 'bin'}
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc=(Get-ChildItem -LiteralPath (Join-Path $vs 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$sdk=(Get-ChildItem -LiteralPath (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Lib') -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName
$tools=Join-Path $msvc 'bin\Hostx64\x64'
& (Join-Path $tools 'ml64.exe') /nologo /c "/DPREVIEW_CODEC=$CodecKind" "/Fo$out\ui-preview.obj" (Join-Path $PSScriptRoot 'ui-preview.asm')
if($LASTEXITCODE){throw 'Preview assembly failed'}
$objects=@('ui-preview','ui','player','decoder','mp3','mp3_synthesis','ogg','vorbis','vorbis_transform') | ForEach-Object {Join-Path $out "$_.obj"}
$objects+=@(Get-ChildItem -LiteralPath $out -Filter 'opus*.obj' | ForEach-Object {$_.FullName})
& (Join-Path $tools 'link.exe') /nologo /entry:preview_start /subsystem:console /nodefaultlib "/out:$out\ui-preview.exe" "/libpath:$sdk\um\x64" @objects kernel32.lib user32.lib gdi32.lib comdlg32.lib shell32.lib ole32.lib avrt.lib
if($LASTEXITCODE){throw 'Preview link failed'}
$previewOut = Join-Path (Split-Path $root -Parent) 'outputs'
New-Item -ItemType Directory -Force -Path $previewOut | Out-Null
Push-Location $previewOut
try {
    & (Join-Path $out 'ui-preview.exe')
    if($LASTEXITCODE){throw 'Renderer failed'}
    Add-Type -AssemblyName System.Drawing
    $bitmap=[Drawing.Bitmap]::FromFile((Join-Path (Get-Location) 'lamp-ui-preview.bmp'))
    try{$bitmap.Save((Join-Path (Get-Location) 'lamp-ui-preview.png'),[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
}finally{Pop-Location}
