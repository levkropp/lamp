# No FFmpeg or audio device required. Reference C executables are test-only.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'opus-reference.ps1')
$reference=Get-LampOpusReference
& node (Join-Path $PSScriptRoot 'generate-celt-tables.js') $reference --check
if($LASTEXITCODE){throw 'CELT table provenance verification failed'}
foreach($stage in @('range','packet','cwrs','energy','silk-pulses','silk-indices','silk-parameters','silk-nlsf','silk-lpc','silk-state','silk-prediction','silk-synthesis','silk-resampler','silk-cng','silk-plc','silk-stereo','silk-frame','silk-packet','silk-decoder','allocation','vq','band-transform','controls','theta','band','spectral','transform','filter','lpc','pitch','decoder','mode','stream','ogg')){
    & (Join-Path $PSScriptRoot "verify-opus-$stage.ps1")
}
Write-Output 'All thirty-four Opus suites passed against the RFC8251-updated normative reference, including packet-to-PCM and Ogg family0/gain/pre-skip/end trimming, SILK/hybrid/CELT transitions, FEC, DTX and loss/recovery. Run verify-opus-conformance.ps1 separately for official vectors.'
