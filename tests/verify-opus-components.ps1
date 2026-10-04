# No FFmpeg or audio device required. Reference C executables are test-only.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'opus-reference.ps1')
$reference=Get-LampOpusReference
& node (Join-Path $PSScriptRoot 'generate-celt-tables.js') $reference --check
if($LASTEXITCODE){throw 'CELT table provenance verification failed'}
foreach($stage in @('range','packet','cwrs','energy','silk-pulses','silk-indices','silk-parameters','silk-nlsf','silk-lpc','silk-state','silk-prediction','silk-synthesis','silk-resampler','silk-cng','silk-plc','silk-stereo','silk-frame','allocation','vq','band-transform','controls','theta','band','spectral','transform','filter','lpc','pitch','decoder')){
    & (Join-Path $PSScriptRoot "verify-opus-$stage.ps1")
}
Write-Output 'All twenty-nine Opus component suites passed, including complete source-rate SILK channel frames, stereo/resampling components and CELT frame-to-PCM, loss concealment and recovery. Full Opus playback is not yet implemented.'
