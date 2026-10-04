param([string]$Ffmpeg = 'ffmpeg', [switch]$SkipPlayback,[string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out=if($OutputDirectory){$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)}else{Join-Path $root 'bin'}
$exe = Join-Path $out 'lamp-cli.exe'
$scratch = Join-Path $PSScriptRoot 'generated'
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$results = [System.Collections.Generic.List[object]]::new()
function Invoke-FF([string[]]$Arguments) {
    & $Ffmpeg -hide_banner -loglevel error -y @Arguments
    if ($LASTEXITCODE) { throw 'Reference fixture generation failed.' }
}
function Check-Decode([string]$Path, [bool]$Mono = $false) {
    $label = [IO.Path]::GetFileName($Path)
    $ours = Join-Path $scratch "$label.ours.f32"
    $reference = Join-Path $scratch "$label.reference.f32"
    if (Test-Path -LiteralPath $ours) { Remove-Item -LiteralPath $ours }
    $stats = & $exe --decode $Path $ours
    $code = $LASTEXITCODE
    if ($code) { throw "Decode failed ($code): $label $stats" }
    $arguments = @('-i', $Path)
    if ($Mono) { $arguments += @('-af','pan=stereo|c0=c0|c1=c0') }
    $arguments += @('-c:a','pcm_f32le','-f','f32le',$reference)
    Invoke-FF $arguments
    $hashA = (Get-FileHash -LiteralPath $ours -Algorithm SHA256).Hash
    $hashB = (Get-FileHash -LiteralPath $reference -Algorithm SHA256).Hash
    if ($hashA -ne $hashB) {
        $a = [IO.File]::ReadAllBytes($ours)
        $b = [IO.File]::ReadAllBytes($reference)
        $first = -1
        for ($i=0; $i -lt [Math]::Min($a.Length,$b.Length); $i++) { if ($a[$i] -ne $b[$i]) { $first=$i; break } }
        throw "Sample mismatch: $label, lengths=$($a.Length)/$($b.Length), first byte=$first"
    }
    $results.Add([pscustomobject]@{test=$label; result='exact'; bytes=(Get-Item -LiteralPath $ours).Length; stats="$stats"})
}
$stereoSource = 'aevalsrc=0.08*sin(2*PI*997*t)+0.03*sin(2*PI*71*t)|0.06*sin(2*PI*431*t):s=48000:d=0.3'
foreach ($codec in @('pcm_u8','pcm_s16le','pcm_s24le','pcm_s32le','pcm_f32le')) {
    foreach ($channels in @(1,2)) {
        $file = Join-Path $scratch "$codec-$channels.wav"
        Invoke-FF @('-f','lavfi','-i',$stereoSource,'-ac',"$channels",'-c:a',$codec,$file)
        Check-Decode $file ($channels -eq 1)
    }
}
foreach ($bits in @(16,24)) {
    foreach ($channels in @(1,2)) {
        foreach ($level in @(0,5,12)) {
            $inputFile = Join-Path $scratch "pcm_s$($bits)le-$channels.wav"
            $file = Join-Path $scratch "flac-$bits-$channels-level$level.flac"
            Invoke-FF @('-i',$inputFile,'-c:a','flac','-compression_level',"$level",$file)
            Check-Decode $file ($channels -eq 1)
        }
    }
}
foreach ($pattern in @('anullsrc=r=44100:cl=stereo','anoisesrc=r=44100:d=0.3:seed=1234:a=0.07')) {
    $kind = if ($pattern.StartsWith('anull')) {'silence'} else {'noise'}
    $file = Join-Path $scratch "$kind.flac"
    Invoke-FF @('-f','lavfi','-i',$pattern,'-t','0.3','-ac','2','-c:a','flac','-compression_level','12',$file)
    Check-Decode $file
}
. (Join-Path $PSScriptRoot 'flac-vectors.ps1')
foreach ($file in (New-FlacVectors $scratch)) { Check-Decode $file }
# Files whose advertised structure or CRC contradicts the bytes must fail.
$valid = Join-Path $scratch 'flac-16-2-level5.flac'
$bytes = [IO.File]::ReadAllBytes($valid)
$bad = Join-Path $scratch 'bad-crc.flac'
$bytes[$bytes.Length-3] = $bytes[$bytes.Length-3] -bxor 1
[IO.File]::WriteAllBytes($bad,$bytes)
$stats = & $exe --check $bad
if ($LASTEXITCODE -eq 0) { throw 'Corrupt FLAC was accepted.' }
$results.Add([pscustomobject]@{test='corrupt-flac';result='rejected';bytes=0;stats="$stats"})
foreach ($format in @('wav','flac')) {
    $source = Join-Path $scratch $(if ($format -eq 'wav') {'pcm_s16le-2.wav'} else {'flac-16-2-level5.flac'})
    $bytes = [IO.File]::ReadAllBytes($source)
    $bad = Join-Path $scratch "truncated.$format"
    [IO.File]::WriteAllBytes($bad,$bytes[0..($bytes.Length-11)])
    $stats = & $exe --check $bad
    if ($LASTEXITCODE -eq 0) { throw "Truncated $format was accepted." }
    $results.Add([pscustomobject]@{test="truncated-$format";result='rejected';bytes=0;stats="$stats"})
}
if (-not $SkipPlayback) {
    # Digital silence exercises real WASAPI rendering without audible output.
    $file = Join-Path $scratch 'playback-silence.flac'
    Invoke-FF @('-f','lavfi','-i','anullsrc=r=48000:cl=stereo','-t','1.2','-c:a','flac',$file)
    $stats = & $exe $file
    $code = $LASTEXITCODE
    if ($code) { throw "WASAPI playback failed ($code): $stats" }
    if ("$stats" -notmatch 'underruns=0 ') { throw "Playback underrun: $stats" }
    $results.Add([pscustomobject]@{test='wasapi-silence';result='played';bytes=0;stats="$stats"})
}
$report = if($OutputDirectory){Join-Path $out 'verification.json'}else{Join-Path $root 'verification.json'}
$results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $report -Encoding utf8
$results | Format-Table test,result,bytes -AutoSize
Write-Output "Passed $($results.Count) checks. Report: $report"
exit 0
