# Official RFC8251 vectors are downloaded test inputs, never runtime links.
function Get-LampOpusVectors {
    $root=Split-Path $PSScriptRoot -Parent
    $parent=Join-Path $root 'bin\reference'
    $reference=Join-Path $parent 'opus-vectors-rfc8251'
    $archive=Join-Path $parent 'opus-vectors-rfc8251.tar.gz'
    $manifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'reference\opus-rfc8251-vector-hashes.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    if(-not (Test-Path -LiteralPath $archive)) {
        Invoke-WebRequest -UseBasicParsing $manifest.archive_url -OutFile $archive
    }
    if(-not (Test-Path -LiteralPath (Join-Path $reference 'testvector12m.dec'))) {
        New-Item -ItemType Directory -Force -Path $reference | Out-Null
        & tar -xzf $archive -C $reference --strip-components=1
        if($LASTEXITCODE) {throw 'Official Opus vector extraction failed'}
    }
    foreach($file in $manifest.files.PSObject.Properties) {
        $hash=(Get-FileHash -LiteralPath (Join-Path $reference $file.Name) -Algorithm SHA1).Hash
        if($hash -ne $file.Value) {throw "Official Opus vector hash differs from RFC8251: $($file.Name)"}
    }
    return $reference
}
