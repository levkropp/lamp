# No FFmpeg or audio device required. Reference C executables are test-only.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'opus-reference.ps1')
$reference=Get-LampOpusReference
& node (Join-Path $PSScriptRoot 'generate-celt-tables.js') $reference --check
if($LASTEXITCODE){throw 'CELT table provenance verification failed'}
foreach($stage in @('range','packet','cwrs','energy','silk-pulses','silk-indices','silk-parameters','silk-nlsf','silk-lpc','silk-state','silk-prediction','silk-synthesis','silk-resampler','silk-cng','silk-plc','silk-stereo','silk-frame','silk-packet','silk-decoder','allocation','vq','band-transform','controls','theta','band','spectral','transform','filter','lpc','pitch','decoder','mode','stream','ogg','multistream')){
    & (Join-Path $PSScriptRoot "verify-opus-$stage.ps1")
}
Write-Output 'All thirty-five Opus suites passed, using the RFC8251-updated PCM reference and test-only Opus1.5.2 self-delimited framing reference; packet-to-PCM, Ogg families0/1, stereo downmix, gain/pre-skip/end trimming/seeking, SILK/hybrid/CELT transitions, FEC, DTX and loss/recovery. Run verify-opus-conformance.ps1 separately for official vectors.'
