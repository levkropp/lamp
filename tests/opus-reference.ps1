# Extract the normative reference archive and apply the verified decoder update.
# Reference C remains test-only; -Original is for historical comparisons.
function Get-LampOpusReference {
    param([switch]$Original)
    $referenceParent=Join-Path $PSScriptRoot 'reference'
    $reference=Join-Path $referenceParent 'opus-rfc6716'
    $archive=Join-Path $referenceParent 'opus-rfc6716.tar.gz'
    $hash=(Get-FileHash -LiteralPath $archive -Algorithm SHA1).Hash
    if($hash -ne '86A927223E73D2476646A1B933FCD3FFFB6ECC8C') {
        throw 'Normative Opus reference archive hash differs from RFC6716.'
    }
    if(-not (Test-Path -LiteralPath (Join-Path $reference 'celt\entdec.c'))) {
        & tar -xzf $archive -C $referenceParent
        if($LASTEXITCODE) {throw 'Could not extract the Opus test reference.'}
    }
    if($Original) { return $reference }
    $patch=Join-Path $referenceParent 'opus-rfc8251.patch'
    $patchHash=(Get-FileHash -LiteralPath $patch -Algorithm SHA1).Hash
    if($patchHash -ne '029E3AA88FC342C91E67A21E7BFBC9458661CD5F') {
        throw 'Opus decoder update patch hash differs from RFC8251.'
    }
    $updated=Join-Path $referenceParent 'opus-rfc8251'
    $marker=Join-Path $updated '.lamp-rfc8251'
    if(-not (Test-Path -LiteralPath $marker)) {
        if(Test-Path -LiteralPath $updated) { throw 'Incomplete updated reference directory; inspect tests/reference/opus-rfc8251 before retrying.' }
        New-Item -ItemType Directory -Path $updated | Out-Null
        & tar -xzf $archive -C $updated --strip-components=1
        if($LASTEXITCODE) {throw 'Could not extract the updated Opus test reference.'}
        $root=Split-Path $PSScriptRoot -Parent
        $savedErrorAction=$ErrorActionPreference
        try {
            # Git can warn about Unix executable bits on extracted Windows
            # files while applying successfully. Its exit status is decisive.
            $ErrorActionPreference='Continue'
            & git -c ('safe.directory='+$root.Replace('\','/')) -C $root apply --check --directory=tests/reference/opus-rfc8251 $patch
            if($LASTEXITCODE) {throw 'RFC8251 patch does not apply to the normative reference.'}
            & git -c ('safe.directory='+$root.Replace('\','/')) -C $root apply --directory=tests/reference/opus-rfc8251 $patch
            if($LASTEXITCODE) {throw 'Could not apply the RFC8251 decoder update.'}
        } finally {$ErrorActionPreference=$savedErrorAction}
        [IO.File]::WriteAllText($marker,$patchHash)
    }
    if([IO.File]::ReadAllText($marker) -ne $patchHash) {throw 'Updated reference patch marker differs.'}
    return $updated
}
