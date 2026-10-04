# No FFmpeg or audio device required. Reference C executables are test-only.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'opus-reference.ps1')
$reference=Get-LampOpusReference
& node (Join-Path $PSScriptRoot 'generate-celt-tables.js') $reference --check
if($LASTEXITCODE){throw 'CELT table provenance verification failed'}
foreach($stage in @('range','packet','cwrs','energy','silk-pulses','allocation','vq','band-transform','controls','theta','band','spectral','transform','filter','decoder')){
    & (Join-Path $PSScriptRoot "verify-opus-$stage.ps1")
}
Write-Output 'All fifteen Opus component suites passed, including stateful CELT frame-to-PCM. Full Opus playback is not yet implemented.'
