param([string]$Ffmpeg='ffmpeg', [string]$Node='node', [switch]$SkipPlayback)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$exe=Join-Path $root 'bin\lamp-cli.exe'
$scratch=Join-Path $PSScriptRoot 'generated'
$results=[Collections.Generic.List[object]]::new()
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
function FF([string[]]$Arguments) {
    & $Ffmpeg -hide_banner -loglevel error -y @Arguments
    if ($LASTEXITCODE) { throw 'Vorbis fixture/reference failed' }
}
function Compare-Vorbis([string]$Path,[bool]$Mono) {
    $name=[IO.Path]::GetFileName($Path)
    $ours=Join-Path $scratch "$name.ours.f32"
    $ref=Join-Path $scratch "$name.reference.f32"
    if(Test-Path -LiteralPath $ours) { Remove-Item -LiteralPath $ours }
    $stats=& $exe --decode $Path $ours
    if($LASTEXITCODE) { throw "Decode failed $name $stats" }
    # FFmpeg's Ogg demuxer counts a first packet that only primes overlap.
    # Request untrimmed PCM, explicitly remove its initial delay, and trim to
    # the stream's final granule. This avoids its 128-sample end-trim discrepancy.
    $frames=[int64]([regex]::Match("$stats",' frames=(\d+)').Groups[1].Value)
    $vector=$name.StartsWith('vorbis-vector-')
    $decoder=@()
    if($vector) {
        $decoder=@('-c:a','libvorbis')
        $filter="atrim=end_sample=$frames"
    } else {
        $probe=(& ffprobe -v error -select_streams a -show_packets -show_entries packet=duration -of json $Path | ConvertFrom-Json)
        $delay=[int64]$probe.packets[0].duration
        $filter="atrim=start_sample=$($delay):end_sample=$($delay+$frames)"
    }
    if($Mono) { $filter += ',pan=stereo|c0=c0|c1=c0' }
    FF ($decoder + @('-flags2','+skip_manual','-i',$Path,'-af',$filter,'-f','f32le',$ref))
    if($vector) {
        # FFmpeg's libvorbis wrapper exposes signed 16-bit PCM. Its quantisation
        # limits SNR; allow two PCM LSBs for its integer transform rounding.
        $comparison=& $Node (Join-Path $PSScriptRoot 'compare-pcm.js') $ours $ref '65' '0.000062'
    } else { $comparison=& $Node (Join-Path $PSScriptRoot 'compare-pcm.js') $ours $ref }
    if($LASTEXITCODE) { throw "Numerical mismatch $name $comparison" }
    $measure=$comparison | ConvertFrom-Json
    $results.Add([pscustomobject]@{test=$name;result='matched';frames=$frames;snr_db=$measure.snrDb;peak_error=$measure.peakError;stats="$stats"})
    Write-Output "$name $comparison"
}
foreach($rate in @(8000,16000,22050,32000,44100,48000,96000,192000)) {
    foreach($channels in @(1,2)) {
        foreach($quality in @(0,8)) {
            $file=Join-Path $scratch "vorbis-$rate-$channels-q$quality.ogg"
            FF @('-f','lavfi','-i',"aevalsrc=0.15*sin(2*PI*997*t)+0.03*sin(2*PI*71*t)|0.1*sin(2*PI*431*t):s=$($rate):d=0.37",'-ac',"$channels",'-c:a','libvorbis','-q:a',"$quality",$file)
            Compare-Vorbis $file ($channels -eq 1)
        }
    }
}
foreach($pattern in @(
    @('noise','anoisesrc=r=48000:d=1.3:a=0.2:seed=9812'),
    @('transient','aevalsrc=if(lt(mod(t\,0.073)\,0.001)\,0.7*sin(2*PI*9000*t)\,0.02*sin(2*PI*67*t))|0.1*sin(2*PI*433*t):s=48000:d=1.3'),
    @('silence','anullsrc=r=48000:cl=stereo:d=1.3')
)) {
    $file=Join-Path $scratch "vorbis-$($pattern[0]).ogg"
    FF @('-f','lavfi','-i',$pattern[1],'-ac','2','-c:a','libvorbis','-q:a','4',$file)
    Compare-Vorbis $file $false
}
$vectors=& $Node (Join-Path $PSScriptRoot 'ogg-vectors.js') $scratch
if($LASTEXITCODE) { throw 'Ogg vector generation failed' }
foreach($item in $vectors) {
    $entry=$item | ConvertFrom-Json
    if($entry.valid) { Compare-Vorbis $entry.path $entry.mono }
    else {
        $stats=& $exe --check $entry.path
        if($LASTEXITCODE -ne 2) { throw "Malformed Ogg/Vorbis accepted $($entry.path) $stats" }
        $results.Add([pscustomobject]@{test=[IO.Path]::GetFileName($entry.path);result='rejected';frames=0;snr_db=$null;peak_error=0;stats="$stats"})
    }
}
if(-not $SkipPlayback) {
    $stats=& $exe (Join-Path $scratch 'vorbis-silence.ogg')
    if($LASTEXITCODE -or "$stats" -notmatch 'underruns=0 ' -or "$stats" -notmatch 'endpoint_dry=0') { throw "Playback failed $stats" }
    $results.Add([pscustomobject]@{test='WASAPI Vorbis';result='played';stats="$stats"})
}
$results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $root 'bin\vorbis-verification.json') -Encoding utf8
Write-Output "Passed $($results.Count) Ogg/Vorbis checks."
