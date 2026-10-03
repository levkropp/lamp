$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$out = Join-Path (Split-Path $root -Parent) 'outputs'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$version = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()
$zipPath = Join-Path $out "lamp-windows-x64-v$version.zip"
$files = @('README.md','ROADMAP.md','VERSION','LICENSE','THIRD_PARTY_NOTICES','build.ps1','package.ps1','.gitignore','.gitattributes','bin\lamp.exe','bin\lamp-cli.exe')
foreach ($directory in @('src','assets','scripts','docs','reports','site','.github')) {
    $files += Get-ChildItem -LiteralPath (Join-Path $root $directory) -File -Recurse -Force | ForEach-Object { $_.FullName.Substring($root.Length+1) }
}
$files += Get-ChildItem -LiteralPath (Join-Path $root 'tests') -File | ForEach-Object { $_.FullName.Substring($root.Length+1) }
$files += Get-ChildItem -LiteralPath (Join-Path $root 'tests\fixtures') -File | ForEach-Object { $_.FullName.Substring($root.Length+1) }
$files += @('tests\reference\dr_mp3.h','tests\reference\stb_vorbis.c','tests\reference\opus-rfc6716.tar.gz')
$files += Get-ChildItem -LiteralPath $root -Filter '*.json' -File | Where-Object Name -ne 'manifest.json' | ForEach-Object Name
$files = $files | Sort-Object -Unique
$manifest = @()
foreach ($file in $files) {
    $path = Join-Path $root $file
    $manifest += [pscustomobject]@{path=$file.Replace('\','/');bytes=(Get-Item -LiteralPath $path).Length;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
}
[IO.File]::WriteAllText((Join-Path $root 'manifest.json'),($manifest | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
$files += 'manifest.json'
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($zipPath,[IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in $files) {
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,(Join-Path $root $file),('lamp/'+$file.Replace('\','/')),[IO.Compression.CompressionLevel]::Optimal)
    }
} finally { $archive.Dispose() }
$archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($item in $manifest) {
            $entry = $archive.GetEntry('lamp/'+$item.path)
            if (-not $entry -or $entry.Length -ne $item.bytes) { throw "Archive length mismatch: $($item.path)" }
            $stream = $entry.Open()
            try { $hash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','') }
            finally { $stream.Dispose() }
            if ($hash -ne $item.sha256) { throw "Archive hash mismatch: $($item.path)" }
        }
    } finally { $sha.Dispose() }
    Write-Output "Verified $($archive.Entries.Count) archive entries."
} finally { $archive.Dispose() }
Get-Item -LiteralPath $zipPath | Select-Object FullName,Length
