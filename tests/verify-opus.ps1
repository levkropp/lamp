param([string]$Ffmpeg='ffmpeg',[string]$Node='node',[string]$OutputDirectory)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$out=if($OutputDirectory){$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)}else{Join-Path $root 'bin'}
$exe=Join-Path $out 'lamp-cli.exe'
$scratch=Join-Path $PSScriptRoot 'generated'
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$report=[Collections.Generic.List[object]]::new()
function FF([string[]]$Arguments){
 & $Ffmpeg -hide_banner -loglevel error -y @Arguments
 if($LASTEXITCODE){throw 'Opus fixture/reference failed'}
}
function Check-Opus([string]$Path,[int]$Channels){
 $name=[IO.Path]::GetFileName($Path);$ours=Join-Path $scratch "$name.ours.f32";$reference=Join-Path $scratch "$name.reference.f32"
 if(Test-Path -LiteralPath $ours){Remove-Item -LiteralPath $ours}
 $stats=& $exe --decode $Path $ours
 if($LASTEXITCODE){throw "Opus decode failed $name $stats"}
 $argsRef=@('-c:a','libopus','-i',$Path,'-ar','48000')
 if($Channels -eq 1){$argsRef+=@('-af','pan=stereo|c0=c0|c1=c0')}
 FF ($argsRef+@('-c:a','pcm_f32le','-f','f32le',$reference))
 # 16-bit SILK output in the normative decoder can differ from modern
 # libopus float output by a fraction of one int16 LSB. Require bounded
 # absolute error and >=60dB SNR for these non-silent synthetic signals.
 $comparison=& $Node (Join-Path $PSScriptRoot 'compare-pcm.js') $ours $reference 60 0.00004
 if($LASTEXITCODE){throw "Opus reference mismatch $name $comparison"}
 $measure=$comparison | ConvertFrom-Json
 $report.Add([pscustomobject]@{test=$name;result='matched';frames=$measure.frames;snr_db=$measure.snrDb;peak_error=$measure.peakError;stats="$stats"})
 Write-Output "$name $comparison"
}
foreach($rate in @(8000,16000,48000)){foreach($channels in @(1,2)){foreach($duration in @(2.5,5,10,20,40,60,120)){
 $name="opus-$rate-$channels-$duration.opus";$file=Join-Path $scratch $name
 $source="aevalsrc=0.15*sin(2*PI*997*t)+0.05*sin(2*PI*71*t)|0.12*sin(2*PI*431*t):s=$($rate):d=0.37"
 $application=if($duration -lt 10){'lowdelay'}elseif($rate -lt 48000){'voip'}else{'audio'}
 $bitrate=if($rate -lt 48000 -and $duration -ge 10){'24k'}else{'64k'}
 FF @('-f','lavfi','-i',$source,'-ac',"$channels",'-c:a','libopus','-application',$application,'-frame_duration',"$duration",'-b:a',$bitrate,$file)
 Check-Opus $file $channels
}}}
$patterns=@(
 @('noise','anoisesrc=r=48000:d=0.63:seed=928:a=0.2'),
 @('transient','aevalsrc=if(lt(mod(t\,0.073)\,0.001)\,0.7*sin(2*PI*9000*t)\,0.02*sin(2*PI*67*t))|0.1*sin(2*PI*433*t):s=48000:d=0.63'),
 @('silence','anullsrc=r=48000:cl=stereo:d=0.63')
)
foreach($pattern in $patterns){foreach($vbr in @('off','on','constrained')){
 $file=Join-Path $scratch "opus-$($pattern[0])-$vbr.opus"
 FF @('-f','lavfi','-i',$pattern[1],'-ac','2','-c:a','libopus','-b:a','48k','-vbr',$vbr,'-fec','1','-packet_loss','20',$file)
 Check-Opus $file 2
}}
[pscustomobject]@{result='passed';scope='51 generated Ogg/Opus files; independent modern libopus PCM comparisons at 48kHz, mono/stereo, input rates,2.5..120ms packet durations, VBR/CBR/constrained VBR,noise/transients/silence/FEC; not official conformance';minimum_snr_db=60;maximum_absolute_error=0.00004;ffmpeg_version=(& $Ffmpeg -version | Select-Object -First 1);checks=@($report)} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'opus-verification.json') -Encoding utf8
