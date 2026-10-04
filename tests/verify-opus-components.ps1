# No FFmpeg or audio device required. Reference C executables are test-only.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'opus-reference.ps1')
$reference=Get-LampOpusReference
& node (Join-Path $PSScriptRoot 'generate-celt-tables.js') $reference --check
if($LASTEXITCODE){throw 'CELT table provenance verification failed'}
foreach($stage in @('range','packet','cwrs','energy','silk-pulses','allocation','vq','band-transform','controls','theta','band','spectral','transform','filter')){
    & (Join-Path $PSScriptRoot "verify-opus-$stage.ps1")
}
Write-Output 'All fourteen Opus component suites passed. Full Opus audio decoding is not yet implemented.'
