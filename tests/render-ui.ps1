param([string]$OutputDirectory, [ValidateRange(1,6)][int]$CodecKind=2)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$out=if($OutputDirectory){$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)}else{Join-Path $root 'bin'}
# ui-preview.exe links the shipping UI and engine objects (tools/build-windows.py).
$python=if(Get-Command py -ErrorAction SilentlyContinue){'py'}else{'python'}
& $python (Join-Path $root 'tools\build-windows.py') --out $out --tests --preview-codec $CodecKind
if($LASTEXITCODE){throw 'Preview build failed'}
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
