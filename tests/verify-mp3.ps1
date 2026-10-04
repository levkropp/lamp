param([string]$Ffmpeg = 'ffmpeg', [string]$Node = 'node', [switch]$SkipPlayback,[string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out=if($OutputDirectory){$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)}else{Join-Path $root 'bin'}
$exe = Join-Path $out 'lamp-cli.exe'
$scratch = Join-Path $PSScriptRoot 'generated'
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$results = [System.Collections.Generic.List[object]]::new()
function Invoke-FF([string[]]$Arguments) {
    & $Ffmpeg -hide_banner -loglevel error -y @Arguments
    if ($LASTEXITCODE) { throw 'MP3 reference fixture generation failed.' }
}
function Check-Mp3([string]$Path, [bool]$Mono) {
    $label = [IO.Path]::GetFileName($Path)
    $ours = Join-Path $scratch "$label.ours.f32"
    $reference = Join-Path $scratch "$label.reference.f32"
    if (Test-Path -LiteralPath $ours) { Remove-Item -LiteralPath $ours }
    $stats = & $exe --decode $Path $ours
    if ($LASTEXITCODE) { throw "MP3 decode failed: $label $stats" }
    $arguments = @('-c:a','mp3float','-i', $Path)
    if ($Mono) { $arguments += @('-af','pan=stereo|c0=c0|c1=c0') }
    Invoke-FF ($arguments + @('-c:a','pcm_f32le','-f','f32le',$reference))
    $comparison = & $Node (Join-Path $PSScriptRoot 'compare-pcm.js') $ours $reference
    if ($LASTEXITCODE) { throw "MP3 numerical mismatch: $label $comparison" }
    $measure = $comparison | ConvertFrom-Json
    $results.Add([pscustomobject]@{test=$label;result='matched';frames=$measure.frames;snr_db=$measure.snrDb;peak_error=$measure.peakError;stats="$stats"})
    Write-Output "$label $comparison"
}
# Every MPEG-1, MPEG-2 and MPEG-2.5 sample rate, with mono and stereo streams.
foreach ($rate in @(8000,11025,12000,16000,22050,24000,32000,44100,48000)) {
    foreach ($channels in @(1,2)) {
        $file = Join-Path $scratch "mp3-$rate-$channels.mp3"
        $source = "aevalsrc=0.15*sin(2*PI*997*t)+0.05*sin(2*PI*71*t)|0.12*sin(2*PI*431*t):s=$($rate):d=0.35"
        $bitrate = if ($rate -ge 32000) {'128k'} elseif ($rate -ge 16000) {'64k'} else {'32k'}
        Invoke-FF @('-f','lavfi','-i',$source,'-ac',"$channels",'-c:a','libmp3lame','-b:a',$bitrate,$file)
        Check-Mp3 $file ($channels -eq 1)
    }
}
# Impulses trigger short blocks; seeded noise exercises larger Huffman values.
$patterns = @(
    @('noise','anoisesrc=r=44100:d=0.7:seed=9123:a=0.2'),
    @('transient','aevalsrc=if(lt(mod(t\,0.073)\,0.001)\,0.7*sin(2*PI*9000*t)\,0.02*sin(2*PI*67*t))|0.1*sin(2*PI*433*t):s=44100:d=0.7'),
    @('correlated','aevalsrc=0.2*sin(2*PI*1997*t)|0.19*sin(2*PI*1997*t):s=44100:d=0.7')
)
foreach ($pattern in $patterns) {
    foreach ($mode in @('cbr-stereo','cbr-joint','vbr')) {
        $file = Join-Path $scratch "mp3-$($pattern[0])-$mode.mp3"
        $coding = switch ($mode) {
            'cbr-stereo' { @('-b:a','192k','-joint_stereo','0') }
            'cbr-joint' { @('-b:a','96k','-joint_stereo','1') }
            'vbr' { @('-q:a','4') }
        }
        Invoke-FF (@('-f','lavfi','-i',$pattern[1],'-ac','2','-c:a','libmp3lame') + $coding + @($file))
        Check-Mp3 $file $false
    }
}
# Headerless tagging and unknown total length: no Xing/Info, no ID3v2.
$file = Join-Path $scratch 'mp3-no-xing.mp3'
Invoke-FF @('-f','lavfi','-i','sine=frequency=771:sample_rate=44100:duration=0.2','-c:a','libmp3lame','-b:a','128k','-write_xing','0','-id3v2_version','0',$file)
Check-Mp3 $file $true
$vectors = & $Node (Join-Path $PSScriptRoot 'mp3-vectors.js') $scratch
if ($LASTEXITCODE) { throw 'MP3 vector generation failed.' }
foreach ($file in $vectors) { Check-Mp3 $file $false }
$invalid = & $Node (Join-Path $PSScriptRoot 'mp3-malformed.js') $scratch
if ($LASTEXITCODE) { throw 'MP3 malformed vector generation failed.' }
foreach ($file in $invalid) {
    $stats = & $exe --check $file
    if ($LASTEXITCODE -ne 2) { throw "Malformed MP3 was not rejected: $file $stats" }
    $results.Add([pscustomobject]@{test=[IO.Path]::GetFileName($file);result='rejected';frames=0;snr_db=$null;peak_error=0;stats="$stats"})
}
if (-not $SkipPlayback) {
    $file = Join-Path $scratch 'mp3-playback-silence.mp3'
    Invoke-FF @('-f','lavfi','-i','anullsrc=r=48000:cl=stereo','-t','1.2','-c:a','libmp3lame','-b:a','128k',$file)
    $stats = & $exe $file
    if ($LASTEXITCODE -or "$stats" -notmatch 'underruns=0 ' -or "$stats" -notmatch 'endpoint_dry=0') { throw "MP3 WASAPI playback failed: $stats" }
    $results.Add([pscustomobject]@{test='mp3-wasapi-silence';result='played';frames=57600;snr_db=$null;peak_error=0;stats="$stats"})
}
$report = if($OutputDirectory){Join-Path $out 'mp3-verification.json'}else{Join-Path $root 'mp3-verification.json'}
$results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $report -Encoding utf8
Write-Output "Passed $($results.Count) MP3 checks. Report: $report"
exit 0
