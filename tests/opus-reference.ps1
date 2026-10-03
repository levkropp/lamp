# Extract the exact normative reference archive for test oracles only.
function Get-LampOpusReference {
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
    return $reference
}
